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
