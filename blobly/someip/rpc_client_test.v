module someip

// The client adapter's laws, proven against the oracle's own builders: one
// in flight, correlation exact, stale answers drained, deadline burns the
// session. (The emb target's server half is bench-verified on silicon —
// emb#171 h735-someip-hwtest; this is the host half of that pincer.)

fn client() RpcClient {
	return RpcClient{
		service:   0x0100
		method:    0x0001
		iface:     1
		client_id: 0x0E01
	}
}

fn test_roundtrip_response_and_error() {
	mut c := client()
	req := c.send('uptime'.bytes(), 1000) or {
		assert false, 'send refused while idle'
		return
	}
	h := parse_header(req)!
	assert h.session == 1 && h.client == 0x0E01 && h.msg_type == mt_request
	// one in flight: a second send while waiting is refused
	if _ := c.send('again'.bytes(), 2000) {
		assert false, 'second send accepted while waiting'
	}
	// the correlated response completes it
	assert c.on_datagram(response_for(h, 'up 1m'.bytes()))
	assert c.state == .done
	assert c.result.payload.bytestr() == 'up 1m'
	// an error reply on the NEXT request fails it, rc preserved
	req2 := c.send('poke'.bytes(), 3000) or {
		assert false, 'send refused after done'
		return
	}
	h2 := parse_header(req2)!
	assert h2.session == 2, 'sessions advance per request'
	assert c.on_datagram(error_for(h2, 0x20, []u8{}))
	assert c.state == .failed
	assert c.result.rc == 0x20
	assert !c.result.timed_out
}

fn test_stale_and_foreign_datagrams_drain() {
	mut c := client()
	req := c.send('x'.bytes(), 0) or {
		assert false, ''
		return
	}
	h := parse_header(req)!
	// events on the shared socket never complete a request
	assert !c.on_datagram(notification(0x0100, 0x8001, 1, [u8(1), 2, 3]))
	// a response to a DIFFERENT session (the late-reply hazard) drains
	stale := Header{
		service:           h.service
		method:            h.method
		client:            h.client
		session:           h.session + 1
		protocol_version:  protocol_version
		interface_version: h.interface_version
		msg_type:          mt_response
	}
	assert !c.on_datagram(encode(stale, 'late'.bytes()))
	// wrong client id drains
	other := Header{
		service:           h.service
		method:            h.method
		client:            h.client + 1
		session:           h.session
		protocol_version:  protocol_version
		interface_version: h.interface_version
		msg_type:          mt_response
	}
	assert !c.on_datagram(encode(other, 'notmine'.bytes()))
	assert c.state == .waiting
	// the real one still lands after all that noise
	assert c.on_datagram(response_for(h, 'ok'.bytes()))
	assert c.state == .done
}

fn test_deadline_burns_the_session() {
	mut c := client()
	req := c.send('slow'.bytes(), 0) or {
		assert false, ''
		return
	}
	h := parse_header(req)!
	c.poll(999_999)
	assert c.state == .waiting, 'not yet'
	c.poll(1_000_000)
	assert c.state == .failed
	assert c.result.timed_out
	// the LATE reply to the burned session drains instead of completing
	assert !c.on_datagram(response_for(h, 'too late'.bytes()))
	// and the next request uses a FRESH session the late reply cannot match
	req2 := c.send('next'.bytes(), 2_000_000) or {
		assert false, ''
		return
	}
	h2 := parse_header(req2)!
	assert h2.session == h.session + 1
	assert c.on_datagram(response_for(h2, 'fresh'.bytes()))
	assert c.result.payload.bytestr() == 'fresh'
}

fn test_session_wraps_live() {
	mut c := client()
	c.session = 0xFFFF
	req := c.send('w'.bytes(), 0) or {
		assert false, ''
		return
	}
	h := parse_header(req)!
	assert h.session == 1, 'wraps 1.. — 0 is the dead id the server refuses'
}

fn test_incompatible_envelope_drains() {
	mut c := client()
	req := c.send('x'.bytes(), 0) or {
		assert false, ''
		return
	}
	h := parse_header(req)!
	// right correlation, wrong interface version: an incompatible image must
	// not surface its payload as a valid result
	wrong_iface := Header{
		service:           h.service
		method:            h.method
		client:            h.client
		session:           h.session
		protocol_version:  protocol_version
		interface_version: h.interface_version + 1
		msg_type:          mt_response
	}
	assert !c.on_datagram(encode(wrong_iface, 'stale image'.bytes()))
	assert c.state == .waiting
	// wrong protocol version drains the same way
	wrong_proto := Header{
		service:           h.service
		method:            h.method
		client:            h.client
		session:           h.session
		protocol_version:  protocol_version + 1
		interface_version: h.interface_version
		msg_type:          mt_response
	}
	assert !c.on_datagram(encode(wrong_proto, 'alien'.bytes()))
	// the compatible answer still completes
	assert c.on_datagram(response_for(h, 'ok'.bytes()))
	assert c.state == .done
}
