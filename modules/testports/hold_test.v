module testports

import net

// a port of this file's band free on both protocols, held over UDP
fn held_port() !(PortHold, int) {
	for c in holds.candidates() {
		mut t := hold_tcp(c, false) or { continue }
		t.close()
		h := hold_udp(c, false) or { continue }
		return h, c
	}
	return error('no candidate free')
}

// has_v6 reports whether this machine can bind IPv6 at all; a kernel without it skips those halves.
fn has_v6() bool {
	mut s := net.listen_udp('[::1]:0') or { return false }
	s.close() or {}
	return true
}

fn test_an_exclusive_udp_hold_refuses_and_is_refused() {
	mut h, port := held_port()!
	if _ := hold_udp(port, false) {
		assert false, 'two exclusive holds on one port'
	}
	if _ := net.listen_udp('127.0.0.1:${port}') {
		assert false, 'a reuse-address listener beside the hold'
	}
	if has_v6() {
		if _ := hold_udp(port, true) {
			assert false, 'a dual-stack hold beside an IPv4 one'
		}
	}
	h.close()
	h.close()
	// a reuse-address listener on one address refuses the wildcard hold of either family
	mut squat := net.listen_udp('127.0.0.1:${port}')!
	if _ := hold_udp(port, false) {
		assert false, 'held beside a UDP squatter'
	}
	if has_v6() {
		if _ := hold_udp(port, true) {
			assert false, 'dual-stack hold beside a UDP squatter'
		}
	}
	squat.close()!
	mut again := hold_udp(port, false)! // the family held_port probed
	again.close()
}

fn test_an_exclusive_tcp_hold_refuses_a_listener_and_is_refused() {
	mut u, port := held_port()!
	u.close()
	mut t := hold_tcp(port, false)!
	if _ := net.listen_tcp(.ip, '127.0.0.1:${port}') {
		assert false, 'a listener beside the hold'
	}
	t.close()
	mut l := net.listen_tcp(.ip, '127.0.0.1:${port}')!
	if _ := hold_tcp(port, false) {
		assert false, 'held beside a listener'
	}
	l.close()!
}

fn test_holder_takes_both_protocols_or_neither() {
	mut u, port := held_port()!
	mut p := Holder{}
	assert !p.hold(port, false), 'held while UDP is taken'
	// and the TCP half it bound was let go
	mut t := hold_tcp(port, false)!
	t.close()
	u.close()
	assert p.hold(port, false)
	assert !p.hold(port, false), 'held twice'
	assert p.ports() == [port]
	p.release(port)
	assert p.ports() == []
	mut again := hold_udp(port, false)!
	again.close()
}
