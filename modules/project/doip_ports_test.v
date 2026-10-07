module project

import transport

fn doip_row(name string, address string, nodes []string) Channel {
	return Channel{
		name:     name
		adapter:  'doip'
		address:  address
		iface:    compose_iface('doip', address)
		typ:      'doip'
		simulate: nodes
	}
}

// a machine where localhost is 127.0.0.1
fn v4_host(h string) string {
	return if h == 'localhost' { '127.0.0.1' } else { transport.unbracket(h) }
}

// a machine where localhost is ::1 (the CI runner)
fn v6_host(h string) string {
	return if h == 'localhost' { '::1' } else { transport.unbracket(h) }
}

fn test_hosting_lists_loopback_entities_only_by_port() {
	chs := [
		doip_row('A', '127.0.0.1:13400', ['SUT']),
		doip_row('B', '127.0.0.2:13400', ['SUT']),
		doip_row('C', '127.0.0.4:13555', ['SUT']),
		doip_row('Nic', '192.168.0.51:13400', ['SUT']), // reachable from the bench: not moved
		doip_row('Tester', '127.0.0.9:13400', []), // hosts nothing
		Channel{
			...doip_row('Off', '127.0.0.5:14000', ['SUT'])
			enabled: false
		},
	]
	hs := doip_hosting(chs, v4_host)
	assert hs.len == 2
	assert hs[0].port == 13400 && hs[0].hosts == ['127.0.0.1', '127.0.0.2']
	assert hs[1].port == 13555 && hs[1].hosts == ['127.0.0.4']
}

fn test_moved_rows_are_the_entities_and_their_testers() {
	chs := [
		doip_row('Entity', '127.0.0.1:13400', ['SUT']),
		doip_row('SameEntity', 'localhost:13400', []), // a tester dialing it by another spelling
		doip_row('Other', '127.0.0.9:13400', []), // a loopback entity this run does not host
		doip_row('Real', '192.168.0.51:13400', []), // somebody else's ECU
		doip_row('Alt', '127.0.0.4:13555', ['SUT']),
		Channel{
			name:  'CAN1'
			iface: 'inproc:CAN1'
		},
	]
	out, notes := with_doip_ports(chs, {
		13400: 30001
	}, v4_host)
	assert out[0].iface == 'doip:127.0.0.1:30001'
	assert out[0].doip_effective_address() == '127.0.0.1:30001'
	assert out[1].doip_effective_address() == 'localhost:30001'
	assert out[2].iface == 'doip:127.0.0.9:13400'
	assert out[3].iface == 'doip:192.168.0.51:13400'
	assert out[4].iface == 'doip:127.0.0.4:13555', 'a port the map does not name stays'
	assert out[5].iface == 'inproc:CAN1'
	assert notes.len == 2
	assert notes[0] == 'Entity: DoIP 127.0.0.1:13400 -> 127.0.0.1:30001 for this run'
	assert chs[0].iface == 'doip:127.0.0.1:13400', 'the input is not modified'
}

fn test_localhost_is_matched_as_the_address_it_resolves_to() {
	chs := [
		doip_row('Entity', '127.0.0.1:13400', ['SUT']),
		doip_row('Local', 'localhost:13400', []),
	]
	// where localhost is ::1 the tester reaches a separate IPv6 entity: it keeps its port
	out, _ := with_doip_ports(chs, {
		13400: 30001
	}, v6_host)
	assert out[0].iface == 'doip:127.0.0.1:30001'
	assert out[1].iface == 'doip:localhost:13400'
	// and an entity on localhost there is the IPv6 one
	hs := doip_hosting([doip_row('L', 'localhost:13400', ['SUT'])], v6_host)
	assert hs.len == 1 && hs[0].hosts == ['localhost']
}

fn test_an_ipv6_loopback_entity_keeps_its_brackets() {
	out, _ := with_doip_ports([doip_row('V6', '[::1]:13400', ['SUT'])], {
		13400: 30002
	}, v4_host)
	assert out[0].iface == 'doip:[::1]:30002'
	host, port := out[0].doip_endpoint()
	assert host == '::1' && port == 30002
}

fn test_a_default_endpoint_row_is_moved_too() {
	// `type: doip` with no address dials the default, 127.0.0.1:13400
	row := Channel{
		name:     'Bare'
		typ:      'doip'
		iface:    'doip'
		adapter:  'doip'
		address:  ''
		simulate: ['SUT']
	}
	out, _ := with_doip_ports([row], {
		13400: 30003
	}, v4_host)
	host, port := out[0].doip_endpoint()
	assert host == '127.0.0.1' && port == 30003
}

fn test_hosting_keeps_the_spelling_the_entity_binds() {
	hs := doip_hosting([doip_row('L', 'localhost:13400', ['SUT']),
		doip_row('Same', '127.0.0.1:13400', ['SUT'])], v4_host)
	assert hs.len == 1 && hs[0].hosts == ['localhost'], 'one loopback address, bound as written'
}

fn test_an_explicit_announcement_port_moves_with_the_entity() {
	mut row := doip_row('A', '127.0.0.1:13400', ['SUT'])
	row.announce_to = '127.255.255.255:13400'
	out, _ := with_doip_ports([row], {
		13400: 30004
	}, v4_host)
	assert out[0].announce_to == '127.255.255.255:30004'
	assert with_moved_port('127.255.255.255', 13400, 30004) == '127.255.255.255', 'host-only follows the bind'
	assert with_moved_port('[ff02::1]:13400', 13400, 30004) == '[ff02::1]:30004'
	assert with_moved_port('ff02::1:13400', 13400, 30004) == 'ff02::1:13400', 'an unbracketed v6 host'
	assert with_moved_port('10.0.0.255:13555', 13400, 30004) == '10.0.0.255:13555'
}

struct FakeProber {
mut:
	busy []int // ports another run holds
	held []int
	fam6 []bool
}

fn (mut f FakeProber) hold(port int, v6 bool) bool {
	if port in f.busy {
		return false
	}
	f.held << port
	f.fam6 << v6
	return true
}

fn test_every_configured_endpoint_port_is_reserved() {
	chs := [
		doip_row('A', '127.0.0.1:13400', ['SUT']),
		doip_row('Wild', '0.0.0.0:30000', ['SUT']), // kept, and covers 30000 on every address
		doip_row('Tester', '127.0.0.1:30001', []), // dials something on 30001
		Channel{
			...doip_row('Off', '127.0.0.1:30002', [])
			enabled: false
		},
		Channel{
			name:  'Svc'
			typ:   'someip'
			iface: 'someip:127.0.0.1:30003'
		},
	]
	assert reserved_ports(chs) == [13400, 30000, 30001, 30002, 30003]
}

fn test_choice_skips_reserved_given_and_busy_ports() {
	chs := [
		doip_row('A', '127.0.0.1:13400', ['SUT']),
		doip_row('B', '127.0.0.4:13555', ['SUT']),
		doip_row('Wild', '0.0.0.0:30000', ['SUT']),
		doip_row('Tester', '127.0.0.1:30001', []),
	]
	mut p := FakeProber{
		busy: [30002]
	}
	moved := choose_doip_ports(doip_hosting(chs, v4_host), reserved_ports(chs), [30000, 30001,
		30002, 30003, 30004], v4_host, mut p)!
	assert moved == {
		13400: 30003
		13555: 30004
	}
	assert p.held == [30003, 30004], 'a reserved port is never probed, a given one never twice'
}

fn test_choice_probes_the_family_the_host_resolves_to() {
	chs := [doip_row('L', 'localhost:13400', ['SUT'])]
	mut p := FakeProber{}
	_ := choose_doip_ports(doip_hosting(chs, v6_host), [], [30010], v6_host, mut p)!
	assert p.fam6 == [true]
	mut q := FakeProber{}
	_ := choose_doip_ports(doip_hosting(chs, v4_host), [], [30010], v4_host, mut q)!
	assert q.fam6 == [false]
}

fn test_choice_fails_when_every_candidate_is_refused() {
	mut p := FakeProber{
		busy: [30020]
	}
	chs := [doip_row('A', '127.0.0.1:13400', ['SUT'])]
	if _ := choose_doip_ports(doip_hosting(chs, v4_host), [], [30020], v4_host, mut p) {
		assert false, 'a refused candidate was given out'
	}
}
