module wiretap

import transport

fn frame(id u32, data []u8) transport.CanFrame {
	return transport.CanFrame{
		id:   id
		data: data
	}
}

fn test_a_frame_we_sent_is_recognised_as_ours() {
	mut r := Ring{}
	f := frame(0x120, [u8(1), 2, 3])
	r.note(7, 'vcan0', f, 0)
	seq := r.claim(0, 'vcan0', f, 1) or {
		assert false, 'our own frame came back and we did not recognise it'
		return
	}
	assert seq == 7
	// still held — a second monitor on this interface gets its own copy of the frame and would
	// otherwise see our own emission as foreign. Expiry retires it, silently, having been seen.
	assert r.outstanding() == 1
	assert r.expire(default_window_ms + 1) == []u64{}
	assert r.outstanding() == 0
}

// The reason the whole mechanism exists: a simulated ECU left running while the real one it
// stands in for is on the bench. Both send 0x120; today they are one indistinguishable stream.
fn test_a_second_identical_frame_is_the_other_transmitter() {
	mut r := Ring{}
	f := frame(0x120, [u8(1), 2, 3])
	r.note(1, 'vcan0', f, 0)
	r.claim(0, 'vcan0', f, 1) or {
		assert false, 'ours was not claimed'
		return
	}
	// Nothing of ours is left, so this one belongs to somebody else — which is exactly the
	// duplicate transmitter we want on screen. Matching without consuming would swallow it.
	if _ := r.claim(0, 'vcan0', f, 2) {
		assert false, 'a second identical frame was attributed to us — the collision is hidden'
	}
}

fn test_claims_oldest_first() {
	mut r := Ring{}
	f := frame(0x120, [u8(9)])
	r.note(1, 'vcan0', f, 0)
	r.note(2, 'vcan0', f, 5)
	a := r.claim(0, 'vcan0', f, 6) or {
		assert false, '${err}'
		return
	}
	b := r.claim(0, 'vcan0', f, 7) or {
		assert false, '${err}'
		return
	}
	assert a == 1 && b == 2, 'frames leave in order, so their echoes must be claimed in order'
}

fn test_another_bus_is_not_our_echo() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0)
	if _ := r.claim(0, 'vcan1', f, 1) {
		assert false, 'a frame on a DIFFERENT bus was attributed to what we sent on this one'
	}
}

fn test_a_different_payload_is_not_our_echo() {
	mut r := Ring{}
	r.note(1, 'vcan0', frame(0x120, [u8(1), 2, 3]), 0)
	if _ := r.claim(0, 'vcan0', frame(0x120, [u8(1), 2, 4]), 1) {
		assert false, 'same id, different bytes — that is another sender, not our echo'
	}
}

// The width-exact invariant this repo has been bitten by before: an extended frame must never
// pass as a standard one sharing the low 11 bits.
fn test_extended_is_not_the_echo_of_standard() {
	mut r := Ring{}
	std := transport.CanFrame{
		id:   0x120
		data: [u8(1)]
	}
	ext := transport.CanFrame{
		id:       0x120
		extended: true
		data:     [u8(1)]
	}
	r.note(1, 'vcan0', std, 0)
	if _ := r.claim(0, 'vcan0', ext, 1) {
		assert false, 'an extended frame masqueraded as our standard one'
	}
}

fn test_rtr_is_not_the_echo_of_a_data_frame() {
	mut r := Ring{}
	data := transport.CanFrame{
		id:   0x120
		data: []
	}
	rtr := transport.CanFrame{
		id:  0x120
		rtr: true
	}
	r.note(1, 'vcan0', data, 0)
	if _ := r.claim(0, 'vcan0', rtr, 1) {
		assert false, 'a remote request was taken for the echo of a data frame'
	}
}

// A frame we sent that never reached the wire is the finding, not a gap: CAN needs an ACK from
// at least one other node, so a lone node's frames never make it at all.
fn test_an_echo_that_never_comes_is_reported_once() {
	mut r := Ring{}
	r.note(42, 'vcan0', frame(0x120, [u8(1)]), 0)
	assert r.expire(500) == []u64{}, 'still inside the window — nothing to report yet'
	assert r.expire(default_window_ms + 1) == [u64(42)]
	assert r.expire(default_window_ms + 2) == []u64{}, 'a missed frame must not be reported twice'
	assert r.outstanding() == 0
}

fn test_an_expired_emission_cannot_be_claimed() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0)
	if _ := r.claim(0, 'vcan0', f, default_window_ms + 1) {
		assert false, 'a frame arriving long after ours was attributed to us'
	}
}

// Two channel entries may watch one interface; each monitor gets its own copy of every frame.
fn test_each_monitor_accounts_for_the_frame_once() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(5, 'vcan0', f, 0)
	a := r.claim(0, 'vcan0', f, 1) or {
		assert false, 'monitor 0 did not recognise our frame'
		return
	}
	b := r.claim(1, 'vcan0', f, 1) or {
		assert false, 'the SECOND monitor saw our own frame as foreign'
		return
	}
	assert a == 5 && b == 5
	// but a repeat at a monitor that already accounted for it is somebody else transmitting
	if _ := r.claim(0, 'vcan0', f, 2) {
		assert false, 'a duplicate transmitter was hidden by the per-monitor rule'
	}
}

// An emission already accounted for by one monitor must not be reported as missing just because
// it lingers for a second monitor that never came.
fn test_a_claimed_emission_is_not_reported_missing() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(9, 'vcan0', f, 0)
	r.claim(0, 'vcan0', f, 1) or {
		assert false, '${err}'
		return
	}
	assert r.expire(default_window_ms + 1) == []u64{}
}

fn test_a_failed_send_is_forgotten_without_a_verdict() {
	mut r := Ring{}
	r.note(3, 'vcan0', frame(0x120, [u8(1)]), 0)
	r.forget(3)
	assert r.expire(default_window_ms + 1) == []u64{}, 'a send that never left reported as missed'
	assert r.outstanding() == 0
}

fn test_eviction_reports_what_it_drops() {
	mut r := Ring{
		cap: 2
	}
	assert r.note(1, 'vcan0', frame(0x101, [u8(1)]), 0) == []u64{}
	assert r.note(2, 'vcan0', frame(0x102, [u8(2)]), 0) == []u64{}
	// the third pushes the first out: reported, never silently dropped — going quiet here would
	// go quiet in exactly the busy-bus case where a dead link matters
	assert r.note(3, 'vcan0', frame(0x103, [u8(3)]), 0) == [u64(1)]
}

fn test_the_ring_is_bounded() {
	mut r := Ring{
		cap: 4
	}
	for i in 0 .. 10 {
		r.note(u64(i), 'vcan0', frame(u32(0x100 + i), [u8(i)]), 0)
	}
	assert r.outstanding() == 4
	// the oldest were dropped, so they read as somebody else's rather than pinning memory
	if _ := r.claim(0, 'vcan0', frame(0x100, [u8(0)]), 1) {
		assert false, 'a dropped record still claimed a frame'
	}
	seq := r.claim(0, 'vcan0', frame(0x109, [u8(9)]), 1) or {
		assert false, 'the newest record should still be there'
		return
	}
	assert seq == 9
}

// A row identity the trace has already discarded must still suppress its echo: the frame is
// ours whether or not a row is left to mark.
fn test_a_record_outlives_its_row() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0)
	seq := r.claim(0, 'vcan0', f, 1) or {
		assert false, 'our own frame became foreign once its row was gone'
		return
	}
	assert seq == 1
}
