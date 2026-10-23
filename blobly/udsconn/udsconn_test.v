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

// A DoIP listener on a row: its port, and its address's family as well as the one asked for.
fn test_doip_listener_takes_the_rows_port_and_family() {
	p, v6 := doip_listener(0, false, '', none)!
	assert p == 13400 && !v6
	p2, v62 := doip_listener(13555, true, '', none)!
	assert p2 == 13555 && v62
	alt := Carrier{
		doip: true
		host: '127.0.0.4'
		port: 13555
	}
	p3, v63 := doip_listener(0, false, 'Alt', alt)!
	assert p3 == 13555 && !v63
	six := Carrier{
		doip: true
		host: '::1'
		port: 13401
	}
	_, v64 := doip_listener(0, false, 'Six', six)!
	assert v64, 'an IPv6 row listens over IPv6'
	// a row is a row whatever it is called: an unnamed one is not "no row"
	unnamed := Carrier{
		doip: true
		host: '127.0.0.1'
		port: 13600
	}
	p5, _ := doip_listener(0, false, '', unnamed)!
	assert p5 == 13600
	doip_listener(13400, false, '', unnamed) or {
		assert err.msg().contains('contradicts')
		doip_listener(0, false, 'CAN1', Carrier{}) or {
			assert err.msg() == '"CAN1" is not a DoIP channel'
			return
		}
		assert false, 'a CAN row gave a DoIP listener'
	}
	assert false, 'a port contradicting an unnamed row was accepted'
}

fn test_a_someip_listener_takes_its_row_or_refuses_a_contradiction() {
	h, p, g := someip_listener(0, '', '', none)!
	assert h == '' && p == 30490 && g == ''
	_, p2, g2 := someip_listener(4000, '239.1.1.1', '', none)!
	assert p2 == 4000 && g2 == '239.1.1.1'
	row := Carrier{
		someip: true
		host:   '127.0.0.1'
		port:   30509
		group:  ''
	}
	h3, p3, g3 := someip_listener(0, '', 'ETH1', row)!
	assert h3 == '127.0.0.1' && p3 == 30509 && g3 == ''
	if _, _, _ := someip_listener(0, '239.1.1.1', 'ETH1', row) {
		assert false, 'a group on a unicast row'
	}
	if _, _, _ := someip_listener(4000, '', 'ETH1', row) {
		assert false, 'another port than the row'
	}
	if _, _, _ := someip_listener(0, '', 'DoIP1', Carrier{ doip: true }) {
		assert false, 'a DoIP row'
	}
}

// a raw ISO-TP channel: a CAN row only, both ids given, 29-bit as a UDS connection's
fn test_a_raw_isotp_channel_needs_both_ids_on_a_can_row() {
	for car in [Carrier{
		doip: true
	}, Carrier{
		someip: true
	}] {
		resolve_isotp(ask(true, 0x700, true, 0x708), 'E', car) or {
			assert err.msg().contains('carries no ISO-TP; a raw ISO-TP channel opens on a CAN row'), err.msg()
			continue
		}
		assert false, 'a raw ISO-TP channel resolved on ${car}'
	}
	for a in [ask(false, 0, true, 0x708), ask(true, 0x700, false, 0)] {
		resolve_isotp(a, 'CAN1', Carrier{}) or {
			assert err.msg() == 'uds.open("CAN1"): give both tx and rx; a raw ISO-TP channel has no default pair'
			continue
		}
		assert false, 'an omitted id resolved'
	}
	resolve_isotp(ask(true, -1, true, 0x708), 'CAN1', Carrier{}) or {
		assert err.msg().contains('is not a CAN identifier')
		t := resolve_isotp(ask(true, 0, true, 0x18DAF110), 'CAN1', Carrier{})!
		assert t == Target{
			tx:  0
			rx:  0x18DAF110
			ext: true
		}
		return
	}
	assert false, 'tx -1 resolved'
}

// what a UDS client rides is the raw channel: a request's whole answer comes back reassembled
fn test_a_raw_isotp_channel_carries_whole_messages() {
	mut ecu := isotp.open_software('inproc:UDSCONN-RAW', 0x7E8, 0x7E0, false)!
	done := chan bool{cap: 1}
	spawn serve(mut ecu, done)
	t := resolve_isotp(ask(true, 0x7E0, true, 0x7E8), 'CAN1', Carrier{})!
	mut c := open_isotp(t, 'CAN1', 'inproc:UDSCONN-RAW', opener)!
	c.send([u8(0x22), 0xF1, 0x90])!
	mut want := [u8(0x62), 0xF1, 0x90]
	want << 'BLOBLYNETV0SUT001'.bytes()
	assert c.recv(2000)! == want
	assert <-done
	c.close()
	open_isotp(t, 'CAN9', 'vcan99', fn (iface string, name string) !transport.Bus {
		return error('no such device')
	}) or {
		assert err.msg() == 'isotp open failed on CAN9: no such device'
		return
	}
	assert false, 'opened over a failing opener'
}
