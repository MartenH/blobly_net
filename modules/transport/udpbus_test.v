module transport

import testports
import time

// A multicast group and port NOBODY ELSE IS USING, derived from this process.
//
// A constant is two collisions waiting. Two tests in one suite can share it, and two suite runs
// — or a suite running beside a live UDP replay on this machine — share it across processes.
// Both are silent, intermittent and unreproducible afterwards, which is exactly the failure
// #112 was filed for and could not identify: one test failed once, five immediate re-runs
// passed, and the run's output had been filtered down to its summary line so even the name was
// lost.
//
// The pid varies the group's low bytes AND the port, so concurrent runs cannot meet; the slot
// keeps two tests in ONE run apart, since a file's tests share a process. 239.x is the
// administratively-scoped block — the right place for something this local.
//
// This is the one place that CANNOT verify by binding, and `testports.group_of` says why: two
// processes may both bind one multicast group and port, and then each sees the other's frames —
// which is exactly what the self-filter assertion below reads as a failure. No bind fails to warn
// them. So here the GROUP does the separating and is predicted from the pid; the port varies with
// the pid as a second lock, and the slot keeps this file's three tests apart, since they share a
// process and each needs a pair of buses that hear only each other.
fn uniq_group(slot int) (string, int) {
	return testports.group(), testports.udp_bus.slot(4, slot)
}

// Two buses on the same group must see each other's frames, but not their own.
fn test_udp_bus_send_recv_and_self_filter() {
	group, port := uniq_group(0)
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

fn test_udp_bus_extended() {
	group, port := uniq_group(1)
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

	// A remote frame is no longer something this app transmits — see frame_rules.v. The refusal
	// is asserted in frame_rules_test; here it is simply absent.
}

// The software bus has to carry an FD frame intact — flags AND a payload longer than the old
// 64-byte receive buffer, which used to truncate at read() before any decoding could see it.
fn test_udpbus_carries_a_full_size_fd_frame() {
	group, port := uniq_group(2)
	mut a := open_udp(group, port) or {
		eprintln('skip: no multicast here: ${err}')
		return
	}
	mut b := open_udp(group, port) or {
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
