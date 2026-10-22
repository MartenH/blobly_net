module udsconn

import blobly.isotp
import blobly.project
import blobly.transport
import blobly.uds

fn ask(has_tx bool, tx i64, has_rx bool, rx i64) Ask {
	return Ask{
		what:   'uds.open'
		has_tx: has_tx
		tx:     tx
		has_rx: has_rx
		rx:     rx
	}
}

fn test_omitted_ids_take_the_defaults_and_given_ones_are_kept() {
	t := resolve(ask(false, 0, false, 0), 'CAN1', Carrier{})!
	assert t == Target{
		tx: 0x7E0
		rx: 0x7E8
	}
	// 0 is an id, not "omitted"
	z := resolve(ask(true, 0, true, 0), 'CAN1', Carrier{})!
	assert z.tx == 0 && z.rx == 0 && !z.ext
	// the caller's own defaults (flash.program's pair)
	f := resolve(Ask{
		what: 'flash.program'
		dtx:  0x7B0
		drx:  0x7B8
	}, 'CAN1', Carrier{})!
	assert f.tx == 0x7B0 && f.rx == 0x7B8
	// a caller's default is held to the rule an id given is
	resolve(Ask{
		what: 'x'
		drx:  0x2000_0000
	}, 'CAN1', Carrier{}) or { return }
	assert false, 'a default past 29 bits resolved'
}

fn test_29_bit_ids_are_inferred_from_either_id() {
	assert resolve(ask(true, 0x18DA10F1, true, 0x18DAF110), 'CAN1', Carrier{})!.ext
	assert resolve(ask(true, 0x7E0, true, 0x800), 'CAN1', Carrier{})!.ext
	assert !resolve(ask(true, 0x7FF, true, 0x7FF), 'CAN1', Carrier{})!.ext
}

fn test_an_id_that_is_not_a_can_identifier_is_refused_before_the_row() {
	check_ids(ask(true, -2, false, 0), 'X') or {
		assert err.msg() == 'uds.open("X"): tx = -2 is not a CAN identifier (0..0x1FFFFFFF)'
		resolve(ask(false, 0, true, 0x2000_0000), 'X', Carrier{}) or {
			assert err.msg() == 'uds.open("X"): rx = 536870912 is not a CAN identifier (0..0x1FFFFFFF)'
			return
		}
		assert false, 'rx past 29 bits resolved'
	}
	assert false, 'tx = -2 passed'
}

fn test_a_someip_row_is_no_carrier_and_a_doip_row_takes_no_ids() {
	resolve(ask(false, 0, false, 0), 'S', Carrier{ someip: true }) or {
		assert err.msg() == '"S" is a SOME/IP channel — not a diagnostics carrier'
		resolve(ask(true, 0x7E0, false, 0), 'D', Carrier{ doip: true }) or {
			assert err.msg().contains('DoIP addressing comes from the channel')
			t := resolve(ask(false, 0, false, 0), 'D', Carrier{ doip: true })!
			assert t.doip
			return
		}
		assert false, 'ids on a DoIP row resolved'
	}
	assert false, 'a SOME/IP row resolved'
}

fn test_carrier_of_reads_the_row() {
	assert carrier_of(project.Channel{
		name:  'CAN1'
		iface: 'inproc:CAN1'
	}) == Carrier{}
	d := carrier_of(project.Channel{
		name:        'D'
		typ:         'doip'
		iface:       'doip:127.0.0.1:13401'
		tester_addr: 0x0E80
		ecu_addr:    0x1000
	})
	assert d.doip && d.host == '127.0.0.1' && d.port == 13401 && d.tester == 0x0E80 && d.ecu == 0x1000
	assert d.eth_kind()? == 'DoIP'
	s := carrier_of(project.Channel{
		name:  'S'
		iface: 'someip:0.0.0.0:30490'
	})
	assert s.someip && s.eth_kind()? == 'SOME/IP'
}

fn opener(iface string, _ string) !transport.Bus {
	return transport.open(iface)
}

// serve answers one request on the server side of the pair, as the simulated ECUs do
fn serve(mut ch isotp.Channel, done chan bool) {
	mut srv := uds.default_server()
	req := ch.recv(2000) or {
		done <- false
		return
	}
	ch.send(srv.handle(req)) or {}
	ch.close()
	done <- true
}

fn test_open_reaches_the_ecu_on_the_rows_bus() {
	mut ecu := isotp.open_software('inproc:UDSCONN', 0x7E8, 0x7E0, false)!
	done := chan bool{cap: 1}
	spawn serve(mut ecu, done)
	t := resolve(ask(false, 0, false, 0), 'CAN1', Carrier{})!
	mut c := open(t, 'CAN1', 'inproc:UDSCONN', Carrier{}, opener)!
	assert c.ch.tx_id == 0x7E0 && c.ch.rx_id == 0x7E8
	assert c.cli.read_data_by_identifier(0xF190)!.bytestr() == 'BLOBLYNETV0SUT001' // multi-frame
	assert <-done
	c.ch.close()
}

fn test_an_open_that_fails_names_the_row() {
	failing := fn (iface string, name string) !transport.Bus {
		return error('no such device')
	}
	open(Target{ tx: 1, rx: 2 }, 'CAN9', 'vcan99', Carrier{}, failing) or {
		assert err.msg() == 'isotp open failed on CAN9: no such device'
		return
	}
	assert false, 'opened over a failing opener'
}
