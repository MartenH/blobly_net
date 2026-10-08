module project

import net
import testports
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
	hs := doip_hosting(chs, resolve_doip_hosts(chs, v4_host))
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
	out, notes := move(chs, v4_host, 13400, false, 30001)
	assert out[0].iface == 'doip:127.0.0.1:30001'
	assert out[0].doip_effective_address() == '127.0.0.1:30001'
	assert out[1].doip_effective_address() == '127.0.0.1:30001', 'written as the address it resolved to'
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
	out, _ := move(chs, v6_host, 13400, false, 30001)
	assert out[0].iface == 'doip:127.0.0.1:30001'
	assert out[1].iface == 'doip:localhost:13400'
	// and an entity on localhost there is the IPv6 one
	l := [doip_row('L', 'localhost:13400', ['SUT'])]
	hs := doip_hosting(l, resolve_doip_hosts(l, v6_host))
	assert hs.len == 1 && hs[0].hosts == ['localhost'] && hs[0].v6
}

fn test_an_ipv6_loopback_entity_keeps_its_brackets() {
	chs := [doip_row('V6', '[::1]:13400', ['SUT'])]
	out, _ := move(chs, v4_host, 13400, true, 30002)
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
	out, _ := move([row], v4_host, 13400, false, 30003)
	host, port := out[0].doip_endpoint()
	assert host == '127.0.0.1' && port == 30003
}

fn test_hosting_keeps_the_spelling_the_entity_binds() {
	chs := [doip_row('L', 'localhost:13400', ['SUT']),
		doip_row('Same', '127.0.0.1:13400', ['SUT'])]
	hs := doip_hosting(chs, resolve_doip_hosts(chs, v4_host))
	assert hs.len == 1 && hs[0].hosts == ['localhost'], 'one loopback address, bound as written'
}

fn test_an_explicit_announcement_port_moves_with_the_entity() {
	mut row := doip_row('A', '127.0.0.1:13400', ['SUT'])
	row.announce_to = '127.255.255.255:13400'
	out, _ := move([row], v4_host, 13400, false, 30004)
	assert out[0].announce_to == '127.255.255.255:30004'
	assert with_moved_port('127.255.255.255', 13400, 30004) == '127.255.255.255', 'host-only follows the bind'
	assert with_moved_port('[ff02::1]:13400', 13400, 30004) == '[ff02::1]:30004'
	assert with_moved_port('ff02::1:13400', 13400, 30004) == 'ff02::1:13400', 'an unbracketed v6 host'
	assert with_moved_port('10.0.0.255:13555', 13400, 30004) == '10.0.0.255:13555'
}

// move is `with_doip_ports` with the hosting entry for `from` in family `v6` moved to `to`.
fn move(chs []Channel, resolve Resolve, from int, v6 bool, to int) ([]Channel, []string) {
	hosts := resolve_doip_hosts(chs, resolve)
	moves := doip_hosting(chs, hosts).filter(it.port == from && it.v6 == v6).map(DoipMove{
		hosting: it
		to:      to
	})
	return with_doip_ports(chs, moves, hosts)
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
	moves := choose_doip_ports(doip_hosting(chs, resolve_doip_hosts(chs, v4_host)), reserved_ports(chs),
		[30000, 30001, 30002, 30003, 30004], mut p)!
	assert moves.map('${it.hosting.port}->${it.to}') == ['13400->30003', '13555->30004']
	assert p.held == [30003, 30004], 'a reserved port is never probed, a given one never twice'
}

fn test_choice_probes_the_family_the_host_resolves_to() {
	chs := [doip_row('L', 'localhost:13400', ['SUT'])]
	mut p := FakeProber{}
	_ := choose_doip_ports(doip_hosting(chs, resolve_doip_hosts(chs, v6_host)), [], [30010], mut p)!
	assert p.fam6 == [true]
	mut q := FakeProber{}
	_ := choose_doip_ports(doip_hosting(chs, resolve_doip_hosts(chs, v4_host)), [], [30010], mut q)!
	assert q.fam6 == [false]
}

fn test_choice_fails_when_every_candidate_is_refused() {
	mut p := FakeProber{
		busy: [30020]
	}
	chs := [doip_row('A', '127.0.0.1:13400', ['SUT'])]
	if _ := choose_doip_ports(doip_hosting(chs, resolve_doip_hosts(chs, v4_host)), [], [30020], mut p) {
		assert false, 'a refused candidate was given out'
	}
}

fn test_each_family_on_one_port_gets_its_own_port() {
	// ::1 and 127.0.0.1 on one port are two entries: a probe is released at the first bind, and an
	// entity on ::1 does not keep a concurrent IPv4 run off 127.0.0.1 (#416)
	chs := [
		doip_row('V6', '[::1]:13400', ['SUT']),
		doip_row('V4', '127.0.0.1:13400', ['SUT']),
		doip_row('V4b', '127.0.0.2:13400', ['SUT']), // same family, same port: one entry
		doip_row('T6', '[::1]:13400', []),
		doip_row('T4', '127.0.0.2:13400', []),
	]
	hosts := resolve_doip_hosts(chs, v4_host)
	hs := doip_hosting(chs, hosts)
	assert hs.len == 2
	assert hs[0].port == 13400 && hs[0].v6 && hs[0].hosts == ['::1']
	assert hs[1].port == 13400 && !hs[1].v6 && hs[1].hosts == ['127.0.0.1', '127.0.0.2']
	mut p := FakeProber{}
	moves := choose_doip_ports(hs, reserved_ports(chs), [30030, 30031], mut p)!
	assert p.held == [30030, 30031] && p.fam6 == [true, false]
	out, _ := with_doip_ports(chs, moves, hosts)
	assert out.map(it.iface) == ['doip:[::1]:30030', 'doip:127.0.0.1:30031', 'doip:127.0.0.2:30031',
		'doip:[::1]:30030', 'doip:127.0.0.2:30031']
}

// FlipResolver answers `localhost` as 127.0.0.1 the first time and ::1 after, as a name with
// several answers may.
struct FlipResolver {
mut:
	calls map[string]int
}

fn (mut f FlipResolver) resolve(h string) string {
	f.calls[h]++
	if h == 'localhost' {
		return if f.calls[h] == 1 { '127.0.0.1' } else { '::1' }
	}
	return transport.unbracket(h)
}

fn test_each_host_is_resolved_once_and_carried_through() {
	chs := [
		doip_row('Entity', 'localhost:13400', ['SUT']),
		doip_row('Tester', 'localhost:13400', []),
		doip_row('V4', '127.0.0.1:13400', []),
	]
	mut f := &FlipResolver{}
	hosts := resolve_doip_hosts(chs, fn [mut f] (h string) string {
		return f.resolve(h)
	})
	assert f.calls == {
		'localhost': 1
		'127.0.0.1': 1
	}
	// a second resolution would say ::1: listed, probed, matched and bound as the first answer
	assert hosts.of('localhost') == '127.0.0.1'
	hs := doip_hosting(chs, hosts)
	assert hs.len == 1 && !hs[0].v6
	mut p := FakeProber{}
	moves := choose_doip_ports(hs, [], [30040], mut p)!
	assert p.fam6 == [false]
	out, _ := with_doip_ports(chs, moves, hosts)
	assert out.map(it.iface) == ['doip:127.0.0.1:30040', 'doip:127.0.0.1:30040', 'doip:127.0.0.1:30040']
	assert f.calls['localhost'] == 1, 'nothing resolved it again'
}

// squat_udp holds over UDP alone, as an unrelated service would, the first of `cands` that is
// free on TCP and is not the last (so a later one is left to give out), and says which.
fn squat_udp(cands []int) !(&net.UdpConn, int) {
	for i, c in cands[..cands.len - 1] {
		mut t := testports.hold_tcp(c, false) or { continue }
		t.close()
		s := net.listen_udp('127.0.0.1:${c}') or { continue }
		return s, i
	}
	return error('no candidate could be squatted')
}

fn test_a_port_held_only_over_udp_is_skipped() {
	// a reuse-address UDP listener on the first candidate and nothing on TCP: the TCP probe alone
	// passes, and the entity's own UDP bind would succeed beside it (#416)
	cands := testports.doip_moves.candidates()
	mut squat, from := squat_udp(cands)!
	taken := cands[from]
	defer {
		squat.close() or {}
	}
	chs := [doip_row('A', '127.0.0.1:13400', ['SUT'])]
	mut h := &testports.Holder{}
	defer {
		h.release_all()
	}
	moves := choose_doip_ports(doip_hosting(chs, resolve_doip_hosts(chs, v4_host)), [],
		cands[from..], mut h)!
	assert moves.len == 1 && moves[0].to != taken, 'the UDP-held candidate was given out'
	assert h.ports() == [moves[0].to]
}
