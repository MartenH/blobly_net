module transport

import time

// THE RECEIVE TIME a script's frame carries: the trace's placement, on the host monotonic clock.

fn test_a_frame_without_a_stamp_is_placed_at_its_receipt() {
	mut rx := open('inproc:rxtime') or { panic(err) }
	defer {
		rx.close()
	}
	mut tx := open('inproc:rxtime') or { panic(err) }
	defer {
		tx.close()
	}
	tx.send(CanFrame{ id: 0x149, data: [u8(1)] }) or { panic(err) }
	f := rx.recv(1000) or { panic(err) }
	before := i64(time.sys_mono_now())
	t := received_now(f)
	assert t >= before && t <= i64(time.sys_mono_now())
	assert received_at(f, 42) == 42
}

fn test_a_host_clock_stamp_is_the_time_itself() {
	f := CanFrame{
		id:        0x149
		hw_ns:     1_000_000
		hw_domain: socketcan_domain
	}
	assert received_at(f, 5_000_000) == 1_000_000
}

fn test_a_foreign_clock_is_mapped_onto_the_host_clock() {
	reset_receive_clock()
	// a device clock 1 s behind the host's, frames delivered 100 us and 3 ms after the wire saw them
	f1 := CanFrame{
		hw_ns:     10_000_000
		hw_domain: 'rxtime-device'
	}
	assert received_at(f1, 1_010_100_000) == 1_010_100_000
	f2 := CanFrame{
		hw_ns:     20_000_000
		hw_domain: 'rxtime-device'
	}
	// late by 3 ms: placed at its wire time on the estimate the first frame set
	assert received_at(f2, 1_023_000_000) == 1_020_100_000
}

fn test_frames_from_two_wires_order_by_when_the_wire_saw_them() {
	// One kernel clock stamps every SocketCAN interface, so a frame read LATER off another wire
	// is still placed before one it preceded on the wire.
	a := CanFrame{
		id:        1
		hw_ns:     2_000_000
		hw_domain: socketcan_domain
	}
	b := CanFrame{
		id:        2
		hw_ns:     1_000_000
		hw_domain: socketcan_domain
	}
	ta := received_at(a, 3_000_000)
	tb := received_at(b, 4_000_000)
	assert tb < ta
}

fn test_two_socketcan_wires_carry_one_ordered_timeline() {
	// LIVE on vcan0 and vcan1 (setup_vcan.sh); without them there is nothing to check (CI).
	$if !linux {
		return
	}
	mut rx0 := open('vcan0') or { return }
	defer {
		rx0.close()
	}
	mut rx1 := open('vcan1') or { return }
	defer {
		rx1.close()
	}
	mut tx0 := open('vcan0') or { return }
	defer {
		tx0.close()
	}
	mut tx1 := open('vcan1') or { return }
	defer {
		tx1.close()
	}
	first := [u8(0x5e), 0x07, 0x11, 0xa1]
	second := [u8(0x5e), 0x07, 0x11, 0xa2]
	before := i64(time.sys_mono_now())
	tx0.send(CanFrame{ id: 0x150, data: first }) or { return }
	tx1.send(CanFrame{ id: 0x150, data: second }) or { return }
	// read the LATER wire first: its frame must still be placed after the earlier one
	mut t1 := i64(0)
	mut t0 := i64(0)
	for i64(time.sys_mono_now()) - before < 1_000_000_000 && t1 == 0 {
		f := rx1.recv(200) or { continue }
		if f.id == 0x150 && f.data == second {
			assert f.hw_domain == socketcan_domain
			t1 = received_now(f)
		}
	}
	time.sleep(2 * time.millisecond)
	for i64(time.sys_mono_now()) - before < 2_000_000_000 && t0 == 0 {
		f := rx0.recv(200) or { continue }
		if f.id == 0x150 && f.data == first {
			assert f.hw_domain == socketcan_domain
			t0 = received_now(f)
		}
	}
	assert t0 != 0 && t1 != 0, 'a frame never arrived'
	assert before <= t0 && t0 < t1
}

fn test_a_frame_placed_at_ingress_has_that_place_for_every_reader() {
	reset_receive_clock()
	// the backend receives it 20 ms after the wire did; a prompt frame then lowers the estimate,
	// and a reader takes the first one 11 s later, after Start reset the clock: its place is the
	// one ingress gave it
	late := placed_at_ingress(CanFrame{ hw_ns: 50_000_000, hw_domain: 'rxtime-ingress' },
		2_070_000_000)
	prompt := placed_at_ingress(CanFrame{ hw_ns: 60_000_000, hw_domain: 'rxtime-ingress' },
		2_060_100_000)
	assert prompt.placed_ns == 2_060_100_000
	reset_receive_clock()
	assert received_at(late, 2_070_000_000) == 2_070_000_000
	assert received_at(late, 13_070_000_000) == 2_070_000_000
}

fn test_a_reader_fed_clock_keeps_learning() {
	reset_receive_clock()
	// no backend places these at ingress: each read feeds the estimate, so a first frame read
	// late does not fix the offset for good
	first := CanFrame{
		hw_ns:     10_000_000
		hw_domain: 'rxtime-reader'
	}
	assert received_at(first, 1_030_000_000) == 1_030_000_000
	prompt := CanFrame{
		hw_ns:     20_000_000
		hw_domain: 'rxtime-reader'
	}
	assert received_at(prompt, 1_020_100_000) == 1_020_100_000
}

fn test_the_in_process_bus_clears_a_placement_with_the_stamp() {
	mut rx := open('inproc:rxtime_placed') or { panic(err) }
	defer {
		rx.close()
	}
	mut tx := open('inproc:rxtime_placed') or { panic(err) }
	defer {
		tx.close()
	}
	tx.send(CanFrame{ id: 1, hw_ns: 5, hw_domain: 'x', placed_ns: 7 }) or { panic(err) }
	f := rx.recv(1000) or { panic(err) }
	assert f.placed_ns == 0
}
