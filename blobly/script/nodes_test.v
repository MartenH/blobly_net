module script

import os
import blobly.isotp
import blobly.sysview
import blobly.uds

// uds.node opens a node in the width it declares: a node declared 29-bit on 0x123 / 0x124 is
// reached 29-bit, and its 11-bit twin on the same numbers 11-bit — each answering as itself, on one
// wire.
fn test_uds_node_opens_a_node_in_its_declared_width() {
	dir := os.join_path(os.temp_dir(), 'script_nodes_width_${os.getpid()}')
	os.rmdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	for n, ext in {
		'n29': '\next = true'
		'n11': ''
	} {
		os.mkdir_all(os.join_path(dir, 'nodes', n)) or { panic(err) }
		os.write_file(os.join_path(dir, 'nodes', n, 'ecu.toml'), '[uds]\n\n[isotp]\nrx_id = 0x123\ntx_id = 0x124${ext}\n') or {
			panic(err)
		}
	}
	os.write_file(os.join_path(dir, 'system.toml'), '[bus.body]\ninterface = "can0"\n\n[[node]]\nname = "n29"\necu = "nodes/n29/ecu.toml"\nbuses = ["body"]\ndiag = { req = 0x123, rsp = 0x124, ext = true }\n\n[[node]]\nname = "n11"\necu = "nodes/n11/ecu.toml"\nbuses = ["body"]\ndiag = { req = 0x123, rsp = 0x124 }\n') or {
		panic(err)
	}
	wire := 'inproc:LUA_NODE_WIDTH'
	mut stop := false
	t29 := spawn serve_vin(isotp.open_software(wire, 0x124, 0x123, true) or { panic(err) }, 'N29',
		&stop)
	t11 := spawn serve_vin(isotp.open_software(wire, 0x124, 0x123, false) or { panic(err) }, 'N11',
		&stop)
	defer {
		stop = true
		t29.wait()
		t11.wait()
	}
	mut env := new_env([ChanInfo{
		name:  'body'
		iface: wire
	}]) or { panic(err) }
	env.sys = sysview.load(os.join_path(dir, 'system.toml')) or { panic(err) }
	mut lines := []string{}
	env.on_output = fn [mut lines] (s string) {
		lines << s
	}
	defer { env.close() }
	env.run_source('
		test("n29", function()
			local d = uds.node("n29")
			check.equal(d:read_did(0xF190), "N29")
			d:close()
		end)
		test("n11", function()
			local d = uds.node("n11")
			check.equal(d:read_did(0xF190), "N11")
			d:close()
		end)
	') or { panic(err) }
	assert env.total() == 2 && env.passed() == 2, lines.str()
}

// serve_vin answers 0x22 F190 with `vin` on `ch` until stopped: two ECUs told apart by what they say
fn serve_vin(ch_ isotp.Channel, vin string, stop &bool) {
	mut ch := ch_
	mut srv := uds.default_server()
	srv.put_did(0xF190, vin.bytes())
	for !*stop {
		req := ch.recv(20) or { continue }
		resp := srv.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
}
