module testports

import net

// a free port in the cmd/script band, found by holding it
fn held_port() !(UdpHold, int) {
	for c in doip_entities.candidates() {
		h := hold_udp(c, false) or { continue }
		return h, c
	}
	return error('no candidate free')
}

fn test_an_exclusive_hold_refuses_and_is_refused() {
	mut h, port := held_port()!
	if _ := hold_udp(port, false) {
		assert false, 'two exclusive holds on one port'
	}
	if _ := hold_udp(port, true) {
		assert false, 'a dual-stack hold beside an IPv4 one'
	}
	if _ := net.listen_udp('127.0.0.1:${port}') {
		assert false, 'a reuse-address listener beside the hold'
	}
	h.close()
	h.close()
	// a reuse-address listener on one address refuses the wildcard hold of either family
	mut squat := net.listen_udp('127.0.0.1:${port}')!
	if _ := hold_udp(port, false) {
		assert false, 'held beside a UDP squatter'
	}
	if _ := hold_udp(port, true) {
		assert false, 'dual-stack hold beside a UDP squatter'
	}
	squat.close()!
	mut again := hold_udp(port, true)!
	again.close()
}

fn test_holder_takes_both_protocols_or_neither() {
	mut u, port := held_port()!
	mut p := Holder{}
	assert !p.hold(port, false), 'held while UDP is taken'
	// and the TCP half it bound was let go
	mut l := net.listen_tcp(.ip, '0.0.0.0:${port}')!
	l.close()!
	u.close()
	assert p.hold(port, false)
	assert !p.hold(port, false), 'held twice'
	assert p.held() == [port]
	p.release(port)
	assert p.held() == []
	mut again := hold_udp(port, false)!
	again.close()
}
