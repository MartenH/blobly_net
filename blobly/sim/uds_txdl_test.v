module sim

import blobly.isotp
import blobly.project
import blobly.transport
import blobly.uds

// OneAnswer is a simulated ECU's channel answering one request on its own thread.
struct OneAnswer {
mut:
	srv uds.Server
	ch  &isotp.SoftChannel = unsafe { nil }
	err string
}

fn (mut o OneAnswer) run() {
	req := o.ch.recv(5000) or {
		o.err = err.msg()
		return
	}
	o.ch.send(o.srv.handle(req)) or { o.err = err.msg() }
}

const txdl_yaml = 'project:
  name: t
buses:
  - name: FD1
    interface: inproc:SIM-TXDL
    fd: true
    simulation:
      - name: ECU
        uds:
          rx: "0x7E0"
          tx: "0x7E8"
          tx_dl: 64
          dids:
            - { id: "0xF190", bytes: "01" }
'

// A node's `uds:` tx_dl is read, written back and needs schema v14; the node answers in it on an
// FD row, and in 8-byte frames with the reason on a classic one.
fn test_a_node_states_its_tx_dl() {
	pr := project.parse(txdl_yaml)!
	nodes := pr.channels[0].nodes
	cfg := nodes[0].uds or { panic('no uds') }
	assert cfg.tx_dl == 64
	assert project.version_for(pr) == 14
	again := project.parse(pr.to_yaml())!
	assert (again.channels[0].nodes[0].uds or { panic('lost') }).tx_dl == 64
	servers := uds_nodes(nodes)
	assert servers[0].tx_dl == 64
	s, why := servers[0].isotp_settings(pr.channels[0])
	assert s.tx_dl == 64 && why == ''
	classic, said := servers[0].isotp_settings(project.Channel{ ...pr.channels[0], fd: false })
	assert classic.is_default()
	assert said.contains('classic row') && said.contains('8-byte frames'), said
	// a value no channel sends in is said, and answered in 8-byte frames
	bad := [project.NodeCfg{
		name: 'B'
		uds:  project.UdsCfg{ rx: 0x7E1, tx: 0x7E9, tx_dl: 10 }
	}]
	assert validate_uds(bad).any(it.contains('tx_dl 10 is not one of'))
	assert uds_nodes(bad)[0].tx_dl == 8
	assert validate_uds_doip(bad).any(it.contains('tx_dl is ignored'))
}

// A simulated ECU on an FD row answers a long DID in 64-byte frames, and one past 4095 bytes with
// the 32-bit First Frame length, both read by a tester stating nothing.
fn test_a_simulated_ecu_answers_in_its_tx_dl() {
	pr := project.parse(txdl_yaml)!
	project.apply_listen_only(pr.channels)
	defer {
		project.apply_listen_only([]project.Channel{})
	}
	mut node := uds_nodes(pr.channels[0].nodes)[0]
	long := []u8{len: 5000, init: u8(index)}
	node.server.dids[0xF191] = long
	settings, _ := node.isotp_settings(pr.channels[0])
	mut tap := transport.open('inproc:SIM-TXDL')!
	mut tester := isotp.open_software('inproc:SIM-TXDL', 0x7E0, 0x7E8, false)!
	for did, want in {
		u16(0xF190): [u8(0x01)]
		0xF191:      long
	} {
		mut ecu := isotp.open_software_as('inproc:SIM-TXDL', 'FD1', node.tx, node.rx, node.ext)!
		ecu.settings = settings
		mut o := &OneAnswer{
			srv: node.server
			ch:  ecu
		}
		t := spawn o.run()
		tester.send([u8(0x22), u8(did >> 8), u8(did)])!
		got := tester.recv(5000)!
		t.wait()
		assert o.err == ''
		assert got[..3] == [u8(0x62), u8(did >> 8), u8(did)]
		assert got[3..] == want
		ecu.close()
	}
	// the long answer's First Frame: 64 bytes, FD, the escape and 5003 behind it
	mut ff := transport.CanFrame{}
	for {
		f := tap.recv(1000)!
		if f.id == 0x7E8 && f.data[0] & 0xF0 == 0x10 {
			ff = f
			break
		}
	}
	assert ff.fd && ff.data.len == 64
	assert ff.data[..6] == [u8(0x10), 0, 0, 0, 0x13, 0x8B]
	tester.close()
	tap.close()
}
