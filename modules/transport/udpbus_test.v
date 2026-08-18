module transport

import time

// Two buses on the same group must see each other's frames, but not their own.
fn test_udp_bus_send_recv_and_self_filter() {
	group := '239.63.42.7'
	port := 24117
	mut a := open_udp(group, port) or { panic('open a: ${err}') }
	mut b := open_udp(group, port) or { panic('open b: ${err}') }
	defer {
		a.close()
		b.close()
	}
	time.sleep(50 * time.millisecond) // let multicast membership settle

	a.send(CanFrame{ id: 0x123, data: [u8(0xDE), 0xAD, 0xBE, 0xEF] }) or { panic('send: ${err}') }
	got := b.recv(1000) or { panic('b.recv: ${err}') }
	assert got.id == 0x123
	assert got.extended == false
	assert got.data == [u8(0xDE), 0xAD, 0xBE, 0xEF]

	// a must NOT receive its own frame (multicast loopback is filtered by src).
	if own := a.recv(200) {
		assert false, 'a received its own frame: 0x${own.id:X}'
	}
}

fn test_udp_bus_extended_and_rtr() {
	group := '239.63.42.8'
	port := 24118
	mut a := open_udp(group, port) or { panic('open a: ${err}') }
	mut b := open_udp(group, port) or { panic('open b: ${err}') }
	defer {
		a.close()
		b.close()
	}
	time.sleep(50 * time.millisecond)

	a.send(CanFrame{ id: 0x18FEF100, extended: true, data: [u8(1), 2, 3, 4, 5, 6, 7, 8] }) or {
		panic('send ext: ${err}')
	}
	ext := b.recv(1000) or { panic('recv ext: ${err}') }
	assert ext.id == 0x18FEF100
	assert ext.extended == true
	assert ext.data.len == 8

	a.send(CanFrame{ id: 0x200, rtr: true }) or { panic('send rtr: ${err}') }
	rtr := b.recv(1000) or { panic('recv rtr: ${err}') }
	assert rtr.rtr == true
	assert rtr.data.len == 0
}

// The software bus has to carry an FD frame intact — flags AND a payload longer than the old
// 64-byte receive buffer, which used to truncate at read() before any decoding could see it.
fn test_udpbus_carries_a_full_size_fd_frame() {
	mut a := open_udp('239.13.13.44', 31344) or {
		eprintln('skip: no multicast here: ${err}')
		return
	}
	mut b := open_udp('239.13.13.44', 31344) or {
		a.close()
		eprintln('skip: no multicast here: ${err}')
		return
	}
	defer {
		a.close()
		b.close()
	}
	mut payload := []u8{len: 64}
	for i in 0 .. 64 {
		payload[i] = u8(i + 1)
	}
	a.send(CanFrame{
		id:       0x1ABCDEF
		extended: true
		fd:       true
		brs:      true
		data:     payload
	}) or {
		assert false, 'send: ${err}'
		return
	}
	got := b.recv(2000) or {
		assert false, 'recv: ${err}'
		return
	}
	assert got.id == 0x1ABCDEF
	assert got.extended
	assert got.fd, 'the FD flag did not survive the wire'
	assert got.brs, 'the BRS flag did not survive the wire'
	assert got.data.len == 64, 'payload truncated to ${got.data.len}'
	assert got.data == payload
}
