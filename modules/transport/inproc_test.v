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

fn test_inproc_extended() {
	mut a := open_inproc('T3') or { panic(err) }
	mut b := open_inproc('T3') or { panic(err) }
	defer { a.close() }
	defer { b.close() }
	a.send(CanFrame{ id: 0x18FF0011, extended: true, data: [] }) or { panic(err) }
	got := b.recv(500) or {
		assert false, '${err}'
		return
	}
	assert got.id == 0x18FF0011
	assert got.extended
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

// Every backend must put the same bytes on the wire. An in-process bus that carried a 9-byte FD
// payload verbatim would make a headless test pass where hardware pads to 12 — the default
// transport being the one that lies is the worst version of this.
fn test_inproc_pads_an_fd_payload() {
	mut a := open_inproc('fdpad') or {
		assert false, '${err}'
		return
	}
	mut b := open_inproc('fdpad') or {
		assert false, '${err}'
		return
	}
	defer {
		a.close()
		b.close()
	}
	a.send(CanFrame{
		id:   0x321
		fd:   true
		data: [u8(1), 2, 3, 4, 5, 6, 7, 8, 9]
	}) or {
		assert false, 'send: ${err}'
		return
	}
	got := b.recv(1000) or {
		assert false, 'recv: ${err}'
		return
	}
	assert got.data.len == 12, 'in-process bus did not pad: ${got.data.len}'
	assert got.fd
	assert got.data[9..] == [u8(0), 0, 0]
}

// A SIMULATION MUST NOT MODEL WHAT CANNOT HAPPEN. This bus is what every headless test and the
// whole simulation run on, so a frame no controller could transmit had to be refused here too —
// otherwise a test passes on `inproc:` and the same frame is refused on a bench, which makes the
// software bus a worse model of the hardware the tests exist to stand in for (codex round 2 on
// #204).
fn test_the_in_process_bus_refuses_a_frame_no_controller_could_send() {
	mut a := open_inproc('shape0') or { panic(err) }
	defer {
		a.close()
	}
	bad := [
		transport_frame_rtr_fd(),
		transport_frame_brs_classic(),
		transport_frame_wide_std(),
	]
	for f in bad {
		if _ := a.send(f) {
			assert false, 'id 0x${f.id:X} is not a frame any controller could put on a bus'
		}
	}
}

fn transport_frame_rtr_fd() CanFrame {
	return CanFrame{
		id:  0x123
		rtr: true
		fd:  true
	}
}

fn transport_frame_brs_classic() CanFrame {
	return CanFrame{
		id:  0x123
		brs: true
	}
}

fn transport_frame_wide_std() CanFrame {
	return CanFrame{
		id: 0x800
	}
}

// LENGTHS ARE STILL PADDED, not refused: this bus is in the tier that pads, and an FD payload of
// nine bytes is what a controller would put on the wire as twelve. Refusing it here would be a
// different change and is deliberately not one (see frame_rules.v).
fn test_the_in_process_bus_still_pads_an_fd_payload() {
	mut a := open_inproc('shape1') or { panic(err) }
	mut b := open_inproc('shape1') or { panic(err) }
	defer {
		a.close()
		b.close()
	}
	a.send(CanFrame{ id: 0x321, fd: true, data: []u8{len: 9} }) or {
		assert false, 'nine FD bytes are padded, not refused: ${err}'
		return
	}
	got := b.recv(1000) or {
		assert false, 'padded frame did not arrive: ${err}'
		return
	}
	assert got.data.len == 12, 'a DLC cannot express nine, so twelve is what reaches the wire'
}

// ESI ON A CLASSIC FRAME reached the shared rules late, so for a while `inproc:`, `udp:`, PCAN and
// CANsub refused it while SocketCAN, Kvaser and Vector accepted it and dropped the flag — the same
// input behaving differently depending on which wire it went out on, which is what having one rule
// in one place is supposed to make impossible (codex round 12 on #204).
fn test_the_in_process_bus_refuses_esi_on_a_classic_frame() {
	mut a := open_inproc('shape2') or { panic(err) }
	defer {
		a.close()
	}
	if _ := a.send(CanFrame{ id: 0x123, esi: true }) {
		assert false, 'a classic frame has no ESI bit to set'
	}
	// And an FD frame carrying it is ordinary: the transmitter was error-passive.
	a.send(CanFrame{ id: 0x123, fd: true, esi: true, data: []u8{len: 8} }) or {
		assert false, 'ESI on an FD frame is a received status, not a contradiction: ${err}'
	}
}
