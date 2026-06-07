module transport

// Two buses on the same name exchange frames; a bus never receives its own
// sends; different names are isolated. Hermetic, no kernel/sockets.

fn test_inproc_cross_delivery() {
	mut a := open_inproc('T1') or { panic(err) }
	mut b := open_inproc('T1') or { panic(err) }
	defer { a.close() }
	defer { b.close() }

	a.send(CanFrame{ id: 0x123, data: [u8(0xDE), 0xAD] }) or { panic(err) }
	got := b.recv(500) or {
		assert false, 'b should have received a frame: ${err}'
		return
	}
	assert got.id == 0x123
	assert got.data == [u8(0xDE), 0xAD]
}

fn test_inproc_no_self_loopback() {
	mut a := open_inproc('T2') or { panic(err) }
	defer { a.close() }
	a.send(CanFrame{ id: 0x100, data: [u8(1)] }) or { panic(err) }
	// no other participant + no self-loopback → nothing to receive
	if _ := a.recv(100) {
		assert false, 'a must not receive its own frame'
	}
}

fn test_inproc_extended_and_rtr() {
	mut a := open_inproc('T3') or { panic(err) }
	mut b := open_inproc('T3') or { panic(err) }
	defer { a.close() }
	defer { b.close() }
	a.send(CanFrame{ id: 0x18FF0011, extended: true, rtr: true, data: [] }) or { panic(err) }
	got := b.recv(500) or {
		assert false, '${err}'
		return
	}
	assert got.id == 0x18FF0011
	assert got.extended
	assert got.rtr
}

fn test_inproc_names_isolated() {
	mut a := open_inproc('NETA') or { panic(err) }
	mut b := open_inproc('NETB') or { panic(err) }
	defer { a.close() }
	defer { b.close() }
	a.send(CanFrame{ id: 0x200, data: [u8(9)] }) or { panic(err) }
	if _ := b.recv(100) {
		assert false, 'NETB must not see NETA traffic'
	}
}

fn test_open_dispatch_inproc() {
	mut bus := open('inproc:DISP') or {
		assert false, 'open(inproc:DISP) failed: ${err}'
		return
	}
	bus.close()
}
