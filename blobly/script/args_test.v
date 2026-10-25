module script

import blobly.candb
import blobly.isotp
import blobly.transport
import blobly.uds

// args_db is one message, Powertrain 0x100, with a 16-bit EngineSpeed.
fn args_db() candb.Database {
	return candb.Database{
		messages: [
			candb.Message{
				name:    'Powertrain'
				id:      0x100
				dlc:     8
				signals: [candb.Signal{
					name:   'EngineSpeed'
					length: 16
					factor: 0.25
				}]
			},
		]
	}
}

fn args_serve(mut s uds.Server, mut ch isotp.Channel, stop chan bool) {
	s.serve(mut ch, stop)
}

// An id that is not an integer is refused by bus.send and decode, naming the argument and what
// was given, and nothing goes out; a whole-number float is its integer.
fn test_an_id_that_is_not_an_integer_is_refused_by_name() {
	mut env := new_env([ChanInfo{
		name:  'CAN1'
		iface: 'inproc:UT_args'
		db:    args_db()
	}]) or { panic(err) }
	env.on_output = fn (s string) {}
	mut rx := transport.open('inproc:UT_args') or { panic(err) }
	defer {
		rx.close()
		env.close()
	}
	env.run_source('
		local function refused(want, f, ...)
			local ok, e = pcall(f, ...)
			check.truthy(not ok and tostring(e):find(want, 1, true), tostring(e))
		end
		test("bus.send refuses an id that is not one", function()
			refused("bus.send: the id is 123.5, not an integer", bus.send, "CAN1", 123.5, "")
			refused("bus.send: the id is nil, not an integer", bus.send, "CAN1", nil, "")
			refused([[bus.send: the id is "abc", not an integer]], bus.send, "CAN1", "abc", "")
			refused("bus.send: the id is a table, not an integer", bus.send, "CAN1", {}, "")
			refused("bus.send: the id 536870912 is outside 0x0..0x1FFFFFFF", bus.send, "CAN1", 0x20000000, "")
			bus.send("CAN1", 256.0, "\\1")
		end)
		test("decode refuses an id that is not one", function()
			refused("decode: the id is 1.5, not an integer", decode, "CAN1", 1.5, "")
			refused("decode: the id is nil, not an integer", decode, "CAN1", nil, "")
			check.equal(decode("CAN1", 256.0, string.rep("\\0", 8)).EngineSpeed, 0)
		end)
	')!
	assert env.failed() == 0, env.results.filter(!it.ok).map(it.msg).str()
	assert env.passed() == 2
	f := rx.recv(500) or { panic(err) }
	assert f.id == 256 && f.data == [u8(1)], 'the whole-number float went out as its integer'
	if g := rx.recv(50) {
		assert false, 'a refused send went out as id 0x${g.id:X}'
	}
}

// A UDS handle and a DID that are not integers are refused by name, before anything is sent.
fn test_a_handle_or_did_that_is_not_an_integer_is_refused_by_name() {
	wire := 'inproc:UT_args_uds'
	plain := uds.default_server()
	mut srv := &uds.Server{
		dids: plain.dids
		dtcs: plain.dtcs
	}
	mut ch := isotp.open_software(wire, 0x7E8, 0x7E0, false) or { panic(err) }
	stop := chan bool{cap: 1}
	t := spawn args_serve(mut srv, mut ch, stop)
	mut env := new_env([ChanInfo{
		name:  'DIAG'
		iface: wire
	}]) or { panic(err) }
	env.on_output = fn (s string) {}
	env.run_source('
		local function refused(want, f, ...)
			local ok, e = pcall(f, ...)
			check.truthy(not ok and tostring(e):find(want, 1, true), tostring(e))
		end
		local diag = uds.open("DIAG")
		test("a handle that is not an integer names no connection", function()
			refused("diag:read_did: the uds handle is 1.5, not an integer", __uds_read_did, 1.5, 0xF190)
			refused("diag:read_did: the uds handle is nil, not an integer", __uds_read_did, nil, 0xF190)
			refused("diag:tester_present: the uds handle 99 is not an open connection", __uds_tester_present, 99)
			refused("diag:close: the uds handle is 0.5, not an integer", __uds_close, 0.5)
		end)
		test("a DID that is not an integer is refused", function()
			refused("diag:read_did: the DID is 61840.5, not an integer", diag.read_did, diag, 61840.5)
			refused("diag:read_did: the DID is nil, not an integer", diag.read_did, diag, nil)
			refused("diag:read_did: the DID 65536 is outside 0x0..0xFFFF", diag.read_did, diag, 0x10000)
			refused("diag:write_did: the DID is 1.5, not an integer", diag.write_did, diag, 1.5, "x")
			check.equal(diag:read_did(61840.0), "BLOBLYNETV0SUT001")
		end)
		test("a closed connection is not open", function()
			diag:close()
			refused("diag:read_did: the uds handle 0 is not an open connection", diag.read_did, diag, 0xF190)
		end)
	') or { panic(err) }
	passed, failed := env.passed(), env.failed()
	msgs := env.results.filter(!it.ok).map(it.msg)
	env.close()
	stop <- true
	t.wait()
	assert failed == 0, msgs.str()
	assert passed == 3
}
