module j1939

import transport

// Frame builders: what a J1939 node puts on the wire for the transport protocol.

fn cm(sa u8, da u8, ctrl u8, total int, packets int, pgn u32) transport.CanFrame {
	return transport.CanFrame{
		id:       compose(7, pgn_tp_cm, da, sa)
		extended: true
		data:     [ctrl, u8(total & 0xFF), u8(total >> 8), u8(packets), 0xFF, u8(pgn & 0xFF),
			u8((pgn >> 8) & 0xFF), u8((pgn >> 16) & 0xFF)]
	}
}

fn bam(sa u8, total int, pgn u32) transport.CanFrame {
	return cm(sa, addr_global, cm_bam, total, (total + 6) / 7, pgn)
}

fn rts(sa u8, da u8, total int, pgn u32) transport.CanFrame {
	return cm(sa, da, cm_rts, total, (total + 6) / 7, pgn)
}

fn cts(sa u8, da u8, pgn u32) transport.CanFrame {
	return transport.CanFrame{
		id:       compose(7, pgn_tp_cm, da, sa)
		extended: true
		data:     [cm_cts, 0xFF, 1, 0xFF, 0xFF, u8(pgn & 0xFF), u8((pgn >> 8) & 0xFF),
			u8((pgn >> 16) & 0xFF)]
	}
}

fn abort(sa u8, da u8, reason u8, pgn u32) transport.CanFrame {
	return transport.CanFrame{
		id:       compose(7, pgn_tp_cm, da, sa)
		extended: true
		data:     [cm_abort, reason, 0xFF, 0xFF, 0xFF, u8(pgn & 0xFF), u8((pgn >> 8) & 0xFF),
			u8((pgn >> 16) & 0xFF)]
	}
}

// dt is one data frame: seven payload bytes, the last frame padded with 0xFF.
fn dt(sa u8, da u8, seq u8, payload []u8) transport.CanFrame {
	mut d := [seq]
	d << payload
	for d.len < 8 {
		d << 0xFF
	}
	return transport.CanFrame{
		id:       compose(7, pgn_tp_dt, da, sa)
		extended: true
		data:     d
	}
}

// packets splits a message the way a sender does.
fn packets(sa u8, da u8, msg []u8) []transport.CanFrame {
	mut out := []transport.CanFrame{}
	mut seq := u8(1)
	for i := 0; i < msg.len; i += 7 {
		end := if i + 7 < msg.len { i + 7 } else { msg.len }
		out << dt(sa, da, seq, msg[i..end])
		seq++
	}
	return out
}

fn message(n int) []u8 {
	mut m := []u8{cap: n}
	for i in 0 .. n {
		m << u8(i + 1)
	}
	return m
}

const dm1 = u32(0xFECA)

fn test_bam_rejoins_a_broadcast_message() {
	mut r := Reassembler{}
	msg := message(20) // three packets: 7 + 7 + 6
	mut t := 0.0
	ev0 := r.feed(bam(0x00, msg.len, dm1), t)
	assert ev0.done.len == 0 && ev0.faults.len == 0
	assert r.open() == 1
	mut done := []Assembled{}
	for p in packets(0x00, addr_global, msg) {
		t += 50
		ev := r.feed(p, t)
		assert ev.faults.len == 0
		done << ev.done
	}
	assert done.len == 1
	a := done[0]
	assert a.pgn == dm1
	assert a.sa == 0x00
	assert a.da == addr_global
	assert a.bam
	assert a.packets() == 3
	assert a.data == msg // the last frame's padding is not part of the message
	assert a.id() == 0x1CFECA00 // priority 7 (the BAM's), DM1, from 0x00 — what a DBC lookup matches
	assert a.t_start_ms == 0.0
	assert a.t_end_ms == 150.0
	assert r.open() == 0
}

fn test_rts_cts_session_with_flow_control_interleaved() {
	mut r := Reassembler{}
	msg := message(1785) // the maximum: 255 packets
	mut ev := r.feed(rts(0x17, 0x00, msg.len, 0xFED8), 0)
	assert ev.faults.len == 0
	// the receiver's CTS and, at the end, its acknowledgement change nothing
	assert r.feed(cts(0x00, 0x17, 0xFED8), 1).done.len == 0
	assert r.open() == 1
	mut done := []Assembled{}
	mut t := 2.0
	for i, p in packets(0x17, 0x00, msg) {
		if i % 16 == 0 {
			r.feed(cts(0x00, 0x17, 0xFED8), t)
		}
		t += 1
		ev = r.feed(p, t)
		assert ev.faults.len == 0, ev.faults.str()
		done << ev.done
	}
	assert done.len == 1
	assert done[0].data == msg
	assert !done[0].bam
	assert done[0].da == 0x00
	assert done[0].packets() == 255
	assert done[0].id() == compose(7, 0xFED8, 0x00, 0x17)
	// EndOfMsgACK after completion is nothing this listener tracks
	eom := transport.CanFrame{
		id:       compose(7, pgn_tp_cm, 0x17, 0x00)
		extended: true
		data:     [cm_eom_ack, 0xF9, 0x06, 0xFF, 0xFF, 0xD8, 0xFE, 0x00]
	}
	assert r.feed(eom, t + 1).faults.len == 0
}

fn test_two_senders_interleaved_are_two_sessions() {
	mut r := Reassembler{}
	a := message(10)
	mut b := message(15)
	for i in 0 .. b.len {
		b[i] = u8(0xA0 + i)
	}
	r.feed(bam(0x00, a.len, dm1), 0)
	r.feed(bam(0x0B, b.len, dm1), 1)
	assert r.open() == 2
	pa := packets(0x00, addr_global, a)
	pb := packets(0x0B, addr_global, b)
	mut done := []Assembled{}
	done << r.feed(pa[0], 10).done
	done << r.feed(pb[0], 11).done
	done << r.feed(pb[1], 12).done
	done << r.feed(pa[1], 13).done
	done << r.feed(pb[2], 14).done
	assert done.len == 2
	assert done[0].sa == 0x00 && done[0].data == a
	assert done[1].sa == 0x0B && done[1].data == b
}

fn test_sequence_gap_drops_the_session_and_the_tail_is_orphaned() {
	mut r := Reassembler{}
	msg := message(20)
	r.feed(bam(0x00, msg.len, dm1), 0)
	p := packets(0x00, addr_global, msg)
	assert r.feed(p[0], 1).faults.len == 0
	ev := r.feed(p[2], 2) // packet 2 was lost
	assert ev.done.len == 0
	assert ev.faults.len == 1
	assert ev.faults[0].kind == .sequence
	assert ev.faults[0].pgn == dm1
	assert ev.faults[0].str().contains('got packet 3, expected 2')
	assert r.open() == 0
	// nothing to attach the rest to
	tail := r.feed(p[1], 3)
	assert tail.faults.len == 1
	assert tail.faults[0].kind == .orphan
}

fn test_duplicate_packet_is_a_sequence_fault_too() {
	mut r := Reassembler{}
	msg := message(20)
	r.feed(bam(0x00, msg.len, dm1), 0)
	p := packets(0x00, addr_global, msg)
	r.feed(p[0], 1)
	ev := r.feed(p[0], 2)
	assert ev.faults.len == 1
	assert ev.faults[0].kind == .sequence
	assert ev.faults[0].detail.contains('duplicate')
}

fn test_abort_from_either_side_ends_the_session() {
	// by the receiver
	mut r := Reassembler{}
	r.feed(rts(0x17, 0x00, 20, 0xFED8), 0)
	ev := r.feed(abort(0x00, 0x17, 3, 0xFED8), 1)
	assert ev.faults.len == 1
	assert ev.faults[0].kind == .aborted
	assert ev.faults[0].sa == 0x17 && ev.faults[0].da == 0x00
	assert ev.faults[0].detail.contains('reason 3, a timeout occurred')
	assert r.open() == 0
	// by the originator
	r.feed(rts(0x17, 0x00, 20, 0xFED8), 2)
	ev2 := r.feed(abort(0x17, 0x00, 2, 0xFED8), 3)
	assert ev2.faults.len == 1 && ev2.faults[0].kind == .aborted
	assert r.open() == 0
	// about nothing tracked: silent
	assert r.feed(abort(0x17, 0x00, 2, 0xFED8), 4).faults.len == 0
}

// Two nodes mid-transfer in both directions: an abort names its PGN, and ends that transfer only.
fn test_abort_ends_only_the_transfer_it_names() {
	mut r := Reassembler{}
	r.feed(rts(0x17, 0x00, 20, 0xFED8), 0) // 0x17 -> 0x00, Commanded Address
	r.feed(rts(0x00, 0x17, 30, dm1), 1) // 0x00 -> 0x17, DM1
	assert r.open() == 2
	// 0x00 aborts the DM1 it is sending; the transfer it is RECEIVING carries on
	ev := r.feed(abort(0x00, 0x17, 2, dm1), 2)
	assert ev.faults.len == 1
	assert ev.faults[0].pgn == dm1
	assert ev.faults[0].sa == 0x00 && ev.faults[0].da == 0x17
	assert r.open() == 1
	done := r.feed(dt(0x17, 0x00, 1, message(7)), 3)
	assert done.faults.len == 0
	// an abort naming a PGN neither session carries touches nothing
	assert r.feed(abort(0x00, 0x17, 2, 0xFEE5), 4).faults.len == 0
	assert r.open() == 1
}

fn test_timeout_expires_a_stalled_session() {
	mut r := Reassembler{}
	msg := message(20)
	r.feed(bam(0x00, msg.len, dm1), 0)
	p := packets(0x00, addr_global, msg)
	r.feed(p[0], 100)
	// nothing for a second; the next frame of anything reports it
	ev := r.feed(bam(0x0B, 9, dm1), 1000)
	assert ev.faults.len == 1
	assert ev.faults[0].kind == .timeout
	assert ev.faults[0].sa == 0x00
	assert ev.faults[0].detail.contains('after packet 1 of 3')
	assert r.open() == 1 // the new one
	// and expire() on its own, for a caller with a clock and no frame
	assert r.expire(1001).len == 0
	assert r.expire(2000).len == 1
	assert r.open() == 0
}

// The packet that arrives just past the limit is the one the timeout is about, not an orphan.
fn test_a_late_packet_is_the_timeout_not_an_orphan_too() {
	mut r := Reassembler{}
	msg := message(20)
	r.feed(bam(0x00, msg.len, dm1), 0)
	p := packets(0x00, addr_global, msg)
	r.feed(p[0], 100)
	ev := r.feed(p[1], 900) // 800 ms after the first: past T1
	assert ev.faults.len == 1
	assert ev.faults[0].kind == .timeout
	assert r.open() == 0
	// the NEXT one, with nothing expiring on it, is a genuine orphan
	ev2 := r.feed(p[2], 950)
	assert ev2.faults.len == 1 && ev2.faults[0].kind == .orphan
}

// A connection is timed from its last frame in either direction, and given the receiver's wait:
// a receiver that holds the sender with CTS is a session both peers consider healthy.
fn test_cts_keeps_a_connection_alive_and_it_gets_the_longer_wait() {
	mut r := Reassembler{}
	msg := message(20)
	r.feed(rts(0x17, 0x00, msg.len, 0xFED8), 0)
	// the receiver takes a second to answer: within T3, and nothing else times it out
	assert r.feed(cts(0x00, 0x17, 0xFED8), 1000).faults.len == 0
	assert r.open() == 1
	// a hold: CTS again, well past T1 since the last data frame there never was
	assert r.feed(cts(0x00, 0x17, 0xFED8), 2000).faults.len == 0
	assert r.open() == 1
	p := packets(0x17, 0x00, msg)
	assert r.feed(p[0], 2100).faults.len == 0
	// silence past T3 from the last frame of either side is a timeout
	ev := r.feed(cts(0x00, 0x17, 0xFED8), 3400)
	assert ev.faults.len == 1 && ev.faults[0].kind == .timeout
	assert r.open() == 0
	// a BAM has no receiver to wait for: T1 applies
	r.feed(bam(0x00, msg.len, dm1), 5000)
	assert r.expire(5700).len == 0
	assert r.expire(5800).len == 1
}

fn test_new_announcement_restarts_an_unfinished_session() {
	mut r := Reassembler{}
	r.feed(bam(0x00, 20, dm1), 0)
	r.feed(dt(0x00, addr_global, 1, message(7)), 1)
	ev := r.feed(bam(0x00, 9, 0xFEE5), 2)
	assert ev.faults.len == 1
	assert ev.faults[0].kind == .restarted
	assert ev.faults[0].pgn == dm1 // the one that was dropped
	assert r.open() == 1
	done := r.feed(dt(0x00, addr_global, 1, message(7)), 3).done
	assert done.len == 0
	done2 := r.feed(dt(0x00, addr_global, 2, message(2)), 4).done
	assert done2.len == 1 && done2[0].pgn == 0xFEE5 && done2[0].data.len == 9
}

fn test_malformed_announcements_are_refused_and_said() {
	mut r := Reassembler{}
	// size and packet count disagree
	ev := r.feed(cm(0x00, addr_global, cm_bam, 20, 2, dm1), 0)
	assert ev.faults.len == 1 && ev.faults[0].kind == .malformed
	assert ev.faults[0].detail.contains('20 bytes take 3')
	// too small for TP
	assert r.feed(cm(0x00, addr_global, cm_bam, 8, 2, dm1), 0).faults[0].kind == .malformed
	// too large
	assert r.feed(cm(0x00, addr_global, cm_bam, 1786, 256, dm1), 0).faults[0].kind == .malformed
	// a BAM to one node, an RTS to everyone
	assert r.feed(cm(0x00, 0x17, cm_bam, 20, 3, dm1), 0).faults[0].detail.contains('BAM addressed to 0x17')
	assert r.feed(cm(0x00, addr_global, cm_rts, 20, 3, dm1), 0).faults[0].detail.contains('RTS to the global address')
	// a control frame too short to read
	short := transport.CanFrame{
		id:       compose(7, pgn_tp_cm, addr_global, 0x00)
		extended: true
		data:     [cm_bam, 20, 0]
	}
	assert r.feed(short, 0).faults[0].kind == .malformed
	// an unknown control byte
	assert r.feed(cm(0x00, addr_global, 99, 20, 3, dm1), 0).faults[0].detail.contains('control byte 99')
	assert r.open() == 0
}

fn test_short_data_frame_with_more_due_is_refused() {
	mut r := Reassembler{}
	r.feed(bam(0x00, 20, dm1), 0)
	f := transport.CanFrame{
		id:       compose(7, pgn_tp_dt, addr_global, 0x00)
		extended: true
		data:     [u8(1), 1, 2, 3] // three bytes where seven are due
	}
	ev := r.feed(f, 1)
	assert ev.faults.len == 1 && ev.faults[0].kind == .malformed
	assert ev.faults[0].detail.contains('carries 3 bytes where 7 were due')
	assert r.open() == 0
}

fn test_frames_that_are_not_tp_produce_nothing() {
	mut r := Reassembler{}
	std := transport.CanFrame{
		id:   0x7E0
		data: [u8(0x10), 0x14, 1, 2, 3, 4, 5, 6] // an ISO-TP First Frame is not J1939
	}
	assert r.feed(std, 0) == Events{}
	eec1 := transport.CanFrame{
		id:       0x0CF00400
		extended: true
		data:     [u8(0), 0, 0, 0, 0, 0, 0, 0]
	}
	assert r.feed(eec1, 0) == Events{}
	rtr := transport.CanFrame{
		id:       compose(7, pgn_tp_dt, addr_global, 0x00)
		extended: true
		rtr:      true
	}
	assert r.feed(rtr, 0) == Events{}
}

fn test_overflow_drops_the_stalest_session() {
	mut r := Reassembler{
		max_sessions: 2
	}
	r.feed(bam(0x01, 20, dm1), 0)
	r.feed(bam(0x02, 20, dm1), 1)
	ev := r.feed(bam(0x03, 20, dm1), 2)
	assert ev.faults.len == 1
	assert ev.faults[0].kind == .overflow
	assert ev.faults[0].sa == 0x01
	assert r.open() == 2
}

fn test_fault_wording() {
	f := Fault{
		kind:   .sequence
		sa:     0x00
		da:     addr_global
		pgn:    dm1
		detail: 'x'
	}
	assert f.str() == 'TP SA 0x00 broadcast PGN 0xFECA: x'
	g := Fault{
		kind:   .orphan
		sa:     0x17
		da:     0x00
		detail: 'y'
	}
	assert g.str() == 'TP SA 0x17 to 0x00: y'
}
