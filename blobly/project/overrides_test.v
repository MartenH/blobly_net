module project

const overrides_yaml = '
project:
  name: bench
  version: 4
buses:
  - name: BusA
    adapter: pcan
    address: PCAN_USBBUS1
    bitrate: 250000
    listen_only: true
    senders:
      - name: ping
        bus: pcan:PCAN_USBBUS3
        trigger: manual
  - name: BusB
    adapter: virtual
    address: BusB
    protocol: canfd
    bitrate: 500000
    data_bitrate: 2000000
  - name: Shared
    adapter: pcan
    address: PCAN_USBBUS3
  - name: DoIP1
    adapter: doip
    address: 127.0.0.1:13400
  - name: Lin1
    adapter: lin
    address: inproc:L1
'

fn bench() Project {
	return parse(overrides_yaml) or { panic(err) }
}

fn row(p Project, name string) Channel {
	for ch in p.channels {
		if ch.name == name {
			return ch
		}
	}
	panic('no row ${name}')
}

fn test_parse_one_override_a_line() {
	o := parse_iface_overrides('BusA=inproc:BusA\n\n  BusB = pcan:PCAN_USBBUS2  \r\n') or { panic(err) }
	assert o == [IfaceOverride{'BusA', 'inproc:BusA'}, IfaceOverride{'BusB', 'pcan:PCAN_USBBUS2'}]
	// the first `=` splits: an interface may not contain one, but the split does not care
	assert parse_iface_override('A=udp:x=y')!.iface == 'udp:x=y'
	for bad in ['BusA', '=inproc:x', 'BusA=', ' = '] {
		if _ := parse_iface_override(bad) {
			assert false, '${bad} was read'
		}
	}
	if _ := parse_iface_overrides('BusA=inproc:a\nnonsense') {
		assert false
	}
}

fn test_override_moves_the_row_and_keeps_its_rate_framing_and_listen_only() {
	mut p := bench()
	p.override_interfaces([IfaceOverride{'BusA', 'inproc:BusA'},
		IfaceOverride{'BusB', 'pcan:PCAN_USBBUS2'}])!
	a := row(p, 'BusA')
	assert a.adapter == 'virtual'
	assert a.address == 'BusA'
	assert a.iface == 'inproc:BusA'
	assert a.bitrate == 250000
	assert a.listen_only
	b := row(p, 'BusB')
	assert b.iface == 'pcan:PCAN_USBBUS2'
	assert b.fd && b.data_bitrate == 2000000
	assert b.iface_with_bitrate() == 'pcan:PCAN_USBBUS2@500000/2000000'
	// the rows not named are as the file states them
	assert row(p, 'Shared').iface == 'pcan:PCAN_USBBUS3'
}

fn test_override_doip_and_lin_rows_within_their_kind() {
	mut p := bench()
	p.override_interfaces([IfaceOverride{'DoIP1', 'doip:10.0.0.5:13400'},
		IfaceOverride{'Lin1', 'lin:pty:/tmp/x'}])!
	assert row(p, 'DoIP1').iface == 'doip:10.0.0.5:13400'
	assert row(p, 'DoIP1').kind() == .doip
	assert row(p, 'Lin1').address == 'pty:/tmp/x'
	assert row(p, 'Lin1').kind() == .lin
}

fn refusal(o []IfaceOverride) string {
	mut p := bench()
	before := p.channels.map(it.iface)
	p.override_interfaces(o) or {
		assert p.channels.map(it.iface) == before, 'a refused override changed the project'
		return err.msg()
	}
	return ''
}

fn test_a_name_no_row_has_is_refused_naming_the_rows() {
	msg := refusal([IfaceOverride{'BusA', 'inproc:a'}, IfaceOverride{'Busb', 'inproc:b'}])
	assert msg.contains('no row named "Busb"')
	assert msg.contains('"BusA", "BusB", "Shared", "DoIP1", "Lin1"')
}

fn test_an_interface_of_another_kind_is_refused() {
	assert refusal([IfaceOverride{'BusA', 'doip:1.2.3.4'}]).contains('is a CAN bus; "doip:1.2.3.4" is a DoIP interface')
	assert refusal([IfaceOverride{'DoIP1', 'inproc:x'}]).contains('is a DoIP bus')
	assert refusal([IfaceOverride{'Lin1', 'inproc:x'}]).contains('is a LIN bus')
	assert refusal([IfaceOverride{'BusA', 'lin:inproc:x'}]).contains('is a LIN interface')
	assert refusal([IfaceOverride{'Lin1', 'lin:'}]).contains('needs an address')
}

fn test_a_rate_or_a_mode_in_the_interface_is_refused() {
	assert refusal([IfaceOverride{'BusA', 'pcan:PCAN_USBBUS2@500000'}]).contains('the rate is the row')
	assert refusal([IfaceOverride{'BusA', 'vector:1@500000,silent'}]).contains('the rate is the row')
	assert refusal([IfaceOverride{'BusA', 'vector:1,silent'}]).contains('listen-only is the row')
}

fn test_a_name_given_twice_or_shared_by_two_rows_is_refused() {
	assert refusal([IfaceOverride{'BusA', 'inproc:a'}, IfaceOverride{'BusA', 'inproc:b'}]).contains('given twice')
	mut p := bench()
	p.channels << Channel{
		name:  'BusA'
		iface: 'inproc:other'
	}
	p.override_interfaces([IfaceOverride{'BusA', 'inproc:a'}]) or {
		assert err.msg().contains('2 rows are named "BusA"')
		return
	}
	assert false
}

fn test_a_generator_naming_a_moved_row_by_its_interface_follows_it() {
	mut p := bench()
	assert resolve_sender_bus('pcan:PCAN_USBBUS3', row(p, 'BusA'), p.channels).chan == 'Shared'
	p.override_interfaces([IfaceOverride{'Shared', 'inproc:Shared'}])!
	s := row(p, 'BusA').senders[0]
	assert s.bus == 'Shared'
	r := resolve_sender_bus(s.bus, row(p, 'BusA'), p.channels)
	assert r.chan == 'Shared'
	assert r.iface == 'inproc:Shared'
}

fn test_no_overrides_change_nothing() {
	mut p := bench()
	before := p.channels.map(it.iface)
	p.override_interfaces([])!
	assert p.channels.map(it.iface) == before
}
