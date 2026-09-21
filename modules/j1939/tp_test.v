module j1939

import transport

// Frame builders: what a J1939 node puts on the wire for the transport protocol.
fn cm(sa u8, da u8, ctrl u8, total int, packets int, pgn u32) transport.CanFrame {
	return transport.CanFrame{
		id: compose(7, pgn_tp_cm, da, sa)
		extended: true
		data: [ctrl, u8(total & 0xFF), u8(total >> 8), u8(packets), 0xFF, u8(pgn & 0xFF),
			u8((pgn >> 8) & 0xFF), u8((pgn >> 16) & 0xFF)]
	}
}

fn bam(sa u8, total int, pgn u32) transport.CanFrame {
	return cm(sa, addr_global, cm_bam, total, (total + 6) / 7, pgn)
}

fn rts(sa u8, da u8, total int, pgn u32) transport.CanFrame {
	return cm(sa, da, cm_rts, total, (total + 6) / 7, pgn)
}

// cts names the packet the receiver wants next, because that field MEANS something: a receiver
// that missed one sends the sender back to it. `next_pkt` was a hardcoded 1 while the listener
// ignored the byte, which read as "resume from the beginning" the moment it stopped ignoring it.
fn cts(sa u8, da u8, pgn u32, next_pkt u8) transport.CanFrame {
	return transport.CanFrame{
		id: compose(7, pgn_tp_cm, da, sa)
		extended: true
		data: [cm_cts, 0xFF, next_pkt, 0xFF, 0xFF, u8(pgn & 0xFF), u8((pgn >> 8) & 0xFF),
			u8((pgn >> 16) & 0xFF)]
	}
}

fn abort(sa u8, da u8, reason u8, pgn u32) transport.CanFrame {
	return transport.CanFrame{
		id: compose(7, pgn_tp_cm, da, sa)
		extended: true
		data: [cm_abort, reason, 0xFF, 0xFF, 0xFF, u8(pgn & 0xFF), u8((pgn >> 8) & 0xFF),
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
		id: compose(7, pgn_tp_dt, da, sa)
		extended: true
		data: d
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
	assert r.feed(cts(0x00, 0x17, 0xFED8, 1), 1).done.len == 0
	assert r.open() == 1
	mut done := []Assembled{}
	mut t := 2.0
	for i, p in packets(0x17, 0x00, msg) {
		if i % 16 == 0 {
			// the packet the receiver is actually waiting for, which is this one
			r.feed(cts(0x00, 0x17, 0xFED8, u8(i + 1)), t)
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
		id: compose(7, pgn_tp_cm, 0x17, 0x00)
		extended: true
		data: [cm_eom_ack, 0xF9, 0x06, 0xFF, 0xFF, 0xD8, 0xFE, 0x00]
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
	// both directions carrying the SAME PGN: an abort ends the aborting node's own transfer only
	mut r2 := Reassembler{}
	r2.feed(rts(0x17, 0x00, 20, dm1), 0)
	r2.feed(rts(0x00, 0x17, 30, dm1), 1)
	ev2 := r2.feed(abort(0x00, 0x17, 2, dm1), 2)
	assert ev2.faults.len == 1 && ev2.faults[0].sa == 0x00
	assert r2.open() == 1
	assert r2.feed(dt(0x17, 0x00, 1, message(7)), 3).faults.len == 0
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

// A CTS names the transfer it is about; one for another PGN does not keep a stalled one alive.
fn test_cts_for_another_pgn_does_not_refresh_the_session() {
	mut r := Reassembler{}
	r.feed(rts(0x17, 0x00, 20, 0xFED8), 0)
	assert r.feed(cts(0x00, 0x17, dm1, 1), 1000).faults.len == 0 // another PGN: not this session's
	
	ev := r.feed(cts(0x00, 0x17, dm1, 1), 1300) // 1300 ms after the RTS with nothing of its own
	assert ev.faults.len == 1 && ev.faults[0].kind == .timeout
	assert r.open() == 0
}

// The tracker the subtraction walks with: roles, admission shared with the reassembler,
// completion by sequence number, aborts by PGN.
fn test_transfers_follow_roles_and_complete_on_the_last_sequence_number() {
	mut t := Transfers{}
	msg := message(20)
	a := t.step(bam(0x00, msg.len, dm1))
	assert a.role == .announce && a.pgn == dm1 && a.sa == 0x00 && a.da == addr_global && !a.done
	assert t.open() == 1
	p := packets(0x00, addr_global, msg)
	assert t.step(p[0]).role == .packet
	dup := t.step(p[0]) // retransmitted: still the sender's, and the transfer is not over
	assert dup.role == .packet && !dup.done
	assert t.step(p[1]).role == .packet
	last := t.step(p[2])
	assert last.role == .packet && last.done && last.pgn == dm1
	assert t.open() == 0
	// a packet with nothing open, and a frame that is not TP
	assert t.step(p[1]).role == .stray
	eec1 := transport.CanFrame{
		id: 0x0CF00400
		extended: true
		data: [u8(0), 0, 0, 0, 0, 0, 0, 0]
	}
	assert t.step(eec1).role == .not_tp
	// a gap: the frame is the sender's and the transfer resyncs to it
	t.step(bam(0x0B, msg.len, dm1))
	q := packets(0x0B, addr_global, msg)
	assert t.step(q[2]).done // packet 3 of 3, whatever came before
	
	assert t.open() == 0
	// a sequence number past the count is the sender's frame and not the end
	t.step(bam(0x0B, msg.len, dm1))
	bad := t.step(dt(0x0B, addr_global, 9, message(7)))
	assert bad.role == .packet && !bad.done
	assert t.open() == 1
	assert t.step(q[2]).done
	assert t.open() == 0
}

// With a clock, a transfer whose last packet the capture lost is gone after its wait, and a
// packet on the pair long after belongs to nobody — the reassembler's T1/T3, in seconds.
fn test_transfers_expire_on_the_callers_clock() {
	mut t := Transfers{}
	msg := message(20)
	t.step_at(bam(0x00, msg.len, dm1), 0.0)
	p := packets(0x00, addr_global, msg)
	assert t.step_at(p[0], 0.05).role == .packet
	assert t.step_at(p[1], 0.10).role == .packet
	// the last packet is lost from the capture; two seconds later the same pair sends again
	stray := t.step_at(p[0], 2.10)
	assert stray.role == .stray
	assert t.open() == 0
	// a connection lives on its receiver's CTS, and gets T3
	t.step_at(rts(0x17, 0x00, msg.len, 0xFED8), 10.0)
	assert t.step_at(cts(0x00, 0x17, 0xFED8, 1), 11.0).role == .receiver
	assert t.step_at(dt(0x17, 0x00, 1, message(7)), 12.0).role == .packet // 1.0 s after the CTS: alive
	
	assert t.step_at(dt(0x17, 0x00, 2, message(7)), 13.5).role == .stray // 1.5 s: expired
	
	// the clockless step expires nothing
	mut u := Transfers{}
	u.step(bam(0x00, msg.len, dm1))
	assert u.step(p[0]).role == .packet
	assert u.open() == 1
}

// A refused announcement ends whatever the pair had in progress, in both trackers.
fn test_a_refused_announcement_drops_the_pairs_transfer() {
	mut t := Transfers{}
	t.step(bam(0x00, 20, dm1))
	bad := t.step(cm(0x00, addr_global, cm_bam, 20, 2, dm1)) // count disagrees
	assert bad.role == .stray && bad.done && bad.sa == 0x00
	assert t.open() == 0
	assert t.step(dt(0x00, addr_global, 1, message(7))).role == .stray
	mut r := Reassembler{}
	r.feed(bam(0x00, 20, dm1), 0)
	ev := r.feed(cm(0x00, addr_global, cm_bam, 20, 2, dm1), 1)
	assert ev.faults.len == 2
	assert ev.faults[0].kind == .restarted
	assert ev.faults[1].kind == .malformed
	assert r.open() == 0
	// and one too short (or too long) to parse, whose control byte still says BAM
	short_bam := transport.CanFrame{
		id: compose(7, pgn_tp_cm, addr_global, 0x00)
		extended: true
		data: [u8(cm_bam), 20, 0]
	}
	r.feed(bam(0x00, 20, dm1), 2)
	ev2 := r.feed(short_bam, 3)
	assert ev2.faults.len == 2 && ev2.faults[0].kind == .restarted
	assert r.open() == 0
	mut t2 := Transfers{}
	t2.step(bam(0x00, 20, dm1))
	st := t2.step(short_bam)
	assert st.role == .stray && st.done
	assert t2.open() == 0
	// a mis-sized frame with some other control byte ends nothing
	t2.step(bam(0x00, 20, dm1))
	short_cts := transport.CanFrame{
		id: compose(7, pgn_tp_cm, addr_global, 0x00)
		extended: true
		data: [u8(cm_cts), 1, 1]
	}
	assert !t2.step(short_cts).done
	assert t2.open() == 1
}

fn test_transfers_refuse_what_the_reassembler_refuses() {
	mut t := Transfers{}
	assert t.step(cm(0x00, addr_global, cm_bam, 20, 2, dm1)).role == .stray // count disagrees
	
	assert t.step(cm(0x00, 0x17, cm_bam, 20, 3, dm1)).role == .stray // a BAM to one node
	
	assert t.step(cm(0x00, addr_global, cm_rts, 20, 3, dm1)).role == .stray // an RTS to everyone
	
	assert t.step(cm(0x00, addr_global, cm_bam, 8, 2, dm1)).role == .stray // too small
	
	assert t.step(cm(0x00, addr_global, 99, 20, 3, dm1)).role == .stray // unknown control byte
	
	assert t.step(cm(0x00, addr_global, cm_bam, 20, 3, 0x4FECA)).role == .stray // 19-bit "PGN"
	
	assert t.step(cm(0x00, addr_global, cm_bam, 20, 3, 0xEA12)).role == .stray // PDU1 with a low byte
	
	assert t.step(cm(addr_null, addr_global, cm_bam, 20, 3, dm1)).role == .stray // from the null address
	
	assert t.step(cm(addr_global, 0x17, cm_rts, 20, 3, dm1)).role == .stray // from the global address
	
	assert t.step(cm(0x00, addr_null, cm_rts, 20, 3, dm1)).role == .stray // to the null address
	
	assert t.open() == 0
	assert t.step(cm(0x00, addr_global, cm_bam, 20, 3, 0xEA00)).role == .announce // PDU1, well formed
	
	assert t.open() == 1
	// and the rule is one: the reassembler's reasons come from the same function
	c := parse_cm(cm(0x00, 0x17, cm_bam, 20, 3, dm1).data)?
	assert c.admission(decompose(compose(7, pgn_tp_cm, 0x17, 0x00)))? == 'BAM addressed to 0x17; a BAM is broadcast'
	ok := parse_cm(bam(0x00, 20, dm1).data)?
	assert ok.admission(decompose(compose(7, pgn_tp_cm, addr_global, 0x00))) == none
}

fn test_transfers_abort_by_pgn_and_the_receiver_side() {
	mut t := Transfers{}
	t.step(rts(0x17, 0x00, 20, 0xFED8)) // 0x17 -> 0x00
	t.step(rts(0x00, 0x17, 30, dm1)) // 0x00 -> 0x17
	assert t.step(cts(0x00, 0x17, 0xFED8, 1)).role == .receiver
	// 0x00 aborts the DM1 it is SENDING: its own transfer, by PGN
	ab := t.step(abort(0x00, 0x17, 2, dm1))
	assert ab.role == .sender_abort && ab.pgn == dm1 && ab.sa == 0x00 && ab.done
	assert t.open() == 1
	// 0x00 aborts the transfer it is RECEIVING: the receiver's frame, and that transfer ends
	rc := t.step(abort(0x00, 0x17, 3, 0xFED8))
	assert rc.role == .receiver && rc.done && rc.sa == 0x17
	assert t.open() == 0
	// an abort naming nothing open
	assert t.step(abort(0x00, 0x17, 3, 0xFEE5)).role == .stray
	// the receiver's end-of-message ack closes the transfer it names — a capture that lost the
	// last packet still carries the ack
	t.step(rts(0x17, 0x00, 20, 0xFED8))
	eom_other := transport.CanFrame{
		id: compose(7, pgn_tp_cm, 0x17, 0x00)
		extended: true
		data: [cm_eom_ack, 20, 0, 3, 0xFF, 0xCA, 0xFE, 0x00] // for DM1: not this transfer
	}
	assert !t.step(eom_other).done
	assert t.open() == 1
	eom := transport.CanFrame{
		id: compose(7, pgn_tp_cm, 0x17, 0x00)
		extended: true
		data: [cm_eom_ack, 20, 0, 3, 0xFF, 0xD8, 0xFE, 0x00]
	}
	ack := t.step(eom)
	assert ack.role == .receiver && ack.done
	assert t.open() == 0
}

// An end-of-message ack for a session this listener still has open means a packet went past
// unseen: said as a lost packet, not left to time out.
fn test_eom_ack_for_an_open_session_is_a_lost_packet() {
	mut r := Reassembler{}
	msg := message(20)
	r.feed(rts(0x17, 0x00, msg.len, 0xFED8), 0)
	p := packets(0x17, 0x00, msg)
	r.feed(p[0], 1)
	r.feed(p[1], 2)
	// packet 3 never reaches us; the receiver acknowledges anyway
	eom := transport.CanFrame{
		id: compose(7, pgn_tp_cm, 0x17, 0x00)
		extended: true
		data: [cm_eom_ack, 20, 0, 3, 0xFF, 0xD8, 0xFE, 0x00]
	}
	ev := r.feed(eom, 3)
	assert ev.faults.len == 1
	assert ev.faults[0].kind == .sequence
	assert ev.faults[0].detail.contains('acknowledged complete by SA 0x00 after packet 2 of 3')
	assert r.open() == 0
}

fn test_parse_cm() {
	c := parse_cm([u8(cm_bam), 20, 0, 3, 0xFF, 0xCA, 0xFE, 0x00])?
	assert c.ctrl == cm_bam && c.total == 20 && c.packets == 3 && c.pgn == dm1
	assert parse_cm([u8(cm_bam), 20, 0]) == none
	assert parse_cm([u8(cm_bam), 20, 0, 3, 0xFF, 0xCA, 0xFE, 0x00, 0, 0, 0, 0]) == none // an FD frame
	
}

// A transport-protocol frame is exactly eight bytes: a twelve-byte FD frame on TP.CM's or TP.DT's
// id is some other protocol's, in both trackers.
fn test_fd_sized_frames_are_not_tp_frames() {
	mut r := Reassembler{}
	fd_cm := transport.CanFrame{
		id: compose(7, pgn_tp_cm, addr_global, 0x00)
		extended: true
		fd: true
		data: [u8(cm_bam), 20, 0, 3, 0xFF, 0xCA, 0xFE, 0x00, 1, 2, 3, 4]
	}
	ev := r.feed(fd_cm, 0)
	assert ev.faults.len == 1 && ev.faults[0].kind == .malformed
	assert r.open() == 0
	r.feed(bam(0x00, 20, dm1), 1)
	fd_dt := transport.CanFrame{
		id: compose(7, pgn_tp_dt, addr_global, 0x00)
		extended: true
		fd: true
		data: [u8(1), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
	}
	ev2 := r.feed(fd_dt, 2)
	assert ev2.faults.len == 1 && ev2.faults[0].detail.contains('CAN-FD frame at TP.DT')
	// AND THE TRANSFER SURVIVES IT, as the walker below already required: a frame that is not
	// this transfer's neither advances nor ends it. The two sides disagreed here — the
	// reassembler dropped the session, so the classic transfer's own later packets became
	// orphans — and the walker's assertion was the one that was right (codex).
	assert r.open() == 1
	assert r.feed(packets(0x00, addr_global, message(20))[0], 3).faults.len == 0
	mut t := Transfers{}
	assert t.step(fd_cm).role == .stray
	t.step(bam(0x00, 20, dm1))
	assert t.step(fd_dt).role == .stray
	assert t.open() == 1 // the transfer is neither advanced nor ended by a frame that is not its
	
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
	assert r.feed(cts(0x00, 0x17, 0xFED8, 1), 1000).faults.len == 0
	assert r.open() == 1
	// a hold: CTS again, well past T1 since the last data frame there never was
	assert r.feed(cts(0x00, 0x17, 0xFED8, 1), 2000).faults.len == 0
	assert r.open() == 1
	p := packets(0x17, 0x00, msg)
	assert r.feed(p[0], 2100).faults.len == 0
	// silence past T3 from the last frame of either side is a timeout
	ev := r.feed(cts(0x00, 0x17, 0xFED8, 1), 3400)
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
		id: compose(7, pgn_tp_cm, addr_global, 0x00)
		extended: true
		data: [cm_bam, 20, 0]
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
		id: compose(7, pgn_tp_dt, addr_global, 0x00)
		extended: true
		data: [u8(1), 1, 2, 3] // three bytes where seven are due
	}
	ev := r.feed(f, 1)
	assert ev.faults.len == 1 && ev.faults[0].kind == .malformed
	assert ev.faults[0].detail.contains('data frame of 4 bytes')
	assert r.open() == 0
}

fn test_frames_that_are_not_tp_produce_nothing() {
	mut r := Reassembler{}
	std := transport.CanFrame{
		id: 0x7E0
		data: [u8(0x10), 0x14, 1, 2, 3, 4, 5, 6] // an ISO-TP First Frame is not J1939
	}
	assert r.feed(std, 0) == Events{}
	eec1 := transport.CanFrame{
		id: 0x0CF00400
		extended: true
		data: [u8(0), 0, 0, 0, 0, 0, 0, 0]
	}
	assert r.feed(eec1, 0) == Events{}
	rtr := transport.CanFrame{
		id: compose(7, pgn_tp_dt, addr_global, 0x00)
		extended: true
		rtr: true
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
		announced: true
		kind: .sequence
		sa: 0x00
		da: addr_global
		pgn: dm1
		detail: 'x'
	}
	assert f.str() == 'TP SA 0x00 broadcast PGN 0xFECA: x'
	g := Fault{
		kind: .orphan
		sa: 0x17
		da: 0x00
		detail: 'y'
	}
	assert g.str() == 'TP SA 0x17 to 0x00: y'
}

// Byte 4 is reserved in a BAM at 0xFF. Admitted without judging it, a malformed frame becomes a
// synthetic message — and something the rest-bus walker attributes and may withhold.
fn test_a_bam_carries_its_reserved_byte() {
	mut bad := bam(0x00, 20, dm1)
	bad.data[4] = 0x03
	mut r := Reassembler{}
	ev := r.feed(bad, 0)
	assert ev.faults.len == 1 && ev.faults[0].kind == .malformed
	assert ev.faults[0].detail.contains('reserved byte')
	assert r.open() == 0
	// an RTS carries a real field there — packets per clear-to-send — and is admitted
	mut ok := Reassembler{}
	assert ok.feed(rts(0x00, 0x03, 20, dm1), 0).faults.len == 0
	assert ok.open() == 1
}

// The unused bytes of a final data frame are J1939-21's 0xFF. Anything else is a sender not
// following the standard — said, but NOT abandoned: those bytes lie past the announced length,
// so the message is whole and only the wire was wrong.
fn test_odd_padding_is_reported_and_the_message_still_arrives() {
	mut r := Reassembler{}
	r.feed(bam(0x00, 9, dm1), 0)
	r.feed(dt(0x00, addr_global, 1, [u8(1), 2, 3, 4, 5, 6, 7]), 10)
	mut last := dt(0x00, addr_global, 2, [u8(8), 9])
	last.data[4] = 0x00 // a pad byte that is not 0xFF
	ev := r.feed(last, 20)
	assert ev.done.len == 1, 'the message is whole'
	assert ev.done[0].data == [u8(1), 2, 3, 4, 5, 6, 7, 8, 9]
	assert ev.faults.len == 1 && ev.faults[0].kind == .padding
	// and a properly padded final packet says nothing
	mut q := Reassembler{}
	q.feed(bam(0x00, 9, dm1), 0)
	q.feed(dt(0x00, addr_global, 1, [u8(1), 2, 3, 4, 5, 6, 7]), 10)
	good := q.feed(dt(0x00, addr_global, 2, [u8(8), 9]), 20)
	assert good.done.len == 1 && good.faults.len == 0
}

// A receiver that missed a packet sends the sender BACK to it, and the retransmission that
// follows is not a duplicate. Ignored, the listener read it as one and abandoned a transfer
// that was recovering perfectly well (codex).
fn test_a_clear_to_send_may_ask_for_an_earlier_packet() {
	msg := message(20) // three packets
	ps := packets(0x17, 0x00, msg)
	mut r := Reassembler{}
	r.feed(rts(0x17, 0x00, msg.len, dm1), 0)
	r.feed(ps[0], 1)
	r.feed(ps[1], 2)
	// the receiver missed packet 2 and asks for it again
	assert r.feed(cts(0x00, 0x17, dm1, 2), 3).faults.len == 0
	ev := r.feed(ps[1], 4)
	assert ev.faults.len == 0, ev.faults.str()
	done := r.feed(ps[2], 5)
	assert done.done.len == 1
	assert done.done[0].data == msg, 'the rewound packet is in its place'
	// a CTS asking for a packet the listener has NOT reached would skip bytes it never saw
	mut f := Reassembler{}
	f.feed(rts(0x17, 0x00, msg.len, dm1), 0)
	f.feed(ps[0], 1)
	f.feed(cts(0x00, 0x17, dm1, 3), 2)
	assert f.feed(ps[1], 3).faults.len == 0, 'still expecting packet 2'
}

// A BAM has no receiver, and the global and null addresses originate nothing — so a control
// frame reaching a broadcast session by the reversed key must settle nothing. Without that, a
// CTS "from" 0xFF refreshed, rewound or truncated an open BAM, and an acknowledgement closed it.
fn test_a_broadcast_takes_no_receiver_control() {
	msg := message(20)
	ps := packets(0x00, addr_global, msg)
	for ctrl in ['cts', 'eom'] {
		mut r := Reassembler{}
		r.feed(bam(0x00, msg.len, dm1), 0)
		r.feed(ps[0], 1)
		r.feed(ps[1], 2)
		// addressed to the BAM's originator, sourced from the address a broadcast goes to
		f := if ctrl == 'cts' {
			cts(addr_global, 0x00, dm1, 1)
		} else {
			cm(addr_global, 0x00, cm_eom_ack, msg.len, 3, dm1)
		}
		ev := r.feed(f, 3)
		assert ev.faults.len == 0, '${ctrl}: ${ev.faults.str()}'
		assert r.open() == 1, '${ctrl}: the broadcast is untouched'
		// and it still completes with everything it had
		done := r.feed(ps[2], 4)
		assert done.done.len == 1, ctrl
		assert done.done[0].data == msg, '${ctrl}: nothing was rewound or truncated'
	}
}

// A real connection still answers to its real receiver.
fn test_a_connection_still_takes_its_receivers_control() {
	msg := message(20)
	mut r := Reassembler{}
	r.feed(rts(0x17, 0x00, msg.len, dm1), 0)
	assert r.feed(cts(0x00, 0x17, dm1, 1), 1).faults.len == 0
	assert r.open() == 1
}

// An abort reaches a session the RECEIVER's way round only if there could be a receiver: a
// broadcast has none, so an abort "from" the global address must not delete an open BAM — nor
// clear its rest-bus attribution.
fn test_a_broadcast_takes_no_receiver_abort() {
	msg := message(20)
	ps := packets(0x17, addr_global, msg)
	mut r := Reassembler{}
	r.feed(bam(0x17, msg.len, dm1), 0)
	r.feed(ps[0], 1)
	assert r.feed(abort(addr_global, 0x17, 1, dm1), 2).faults.len == 0
	assert r.open() == 1, 'the broadcast survives'
	// the originator's own abort still ends it
	ev := r.feed(abort(0x17, addr_global, 1, dm1), 3)
	assert ev.faults.len == 1 && ev.faults[0].kind == .aborted
	assert r.open() == 0
	// and the walker agrees, or it attributes frames the trace no longer rejoins
	// Transfers runs on the CALLER's clock in SECONDS, where the Reassembler above takes
	// milliseconds — a second between a BAM's packets is past T1 and expires it.
	mut t := Transfers{}
	t.step_at(bam(0x17, msg.len, dm1), 0.0)
	assert t.step_at(ps[0], 0.05).role == .packet
	t.step_at(abort(addr_global, 0x17, 1, dm1), 0.10)
	assert t.step_at(ps[1], 0.15).role == .packet, 'still attributed to the transfer'
	assert t.open() == 1
}

// A clear-to-send names packets the transfer HAS. One asking for packet 0, or for one past the
// announced count, is not a frame this transfer's receiver sends — and repeating it kept a
// stalled transfer alive past the timeout it had earned.
fn test_a_clear_to_send_naming_no_real_packet_keeps_nothing_alive() {
	msg := message(20) // three packets
	for bad in [u8(0), 4, 255] {
		mut r := Reassembler{}
		r.feed(rts(0x17, 0x00, msg.len, dm1), 0)
		// repeated well past T3, and none of them may refresh it
		r.feed(cts(0x00, 0x17, dm1, bad), 600)
		r.feed(cts(0x00, 0x17, dm1, bad), 1200)
		ev := r.feed(cts(0x00, 0x17, dm1, bad), 1400)
		assert ev.faults.len == 1, 'packet ${bad}: ${ev.faults.str()}'
		assert ev.faults[0].kind == .timeout, '${bad}'
		assert r.open() == 0, '${bad}'
	}
	// and one naming a real packet does keep it alive
	mut ok := Reassembler{}
	ok.feed(rts(0x17, 0x00, msg.len, dm1), 0)
	ok.feed(cts(0x00, 0x17, dm1, 1), 600)
	assert ok.feed(cts(0x00, 0x17, dm1, 1), 1200).faults.len == 0
	assert ok.open() == 1
}

// An EIGHT-byte FD frame at a transport identifier is the hole a length test cannot see: the
// protocol exists because a classic frame carries eight, so such a frame is J1939-22's or a
// proprietary one whose id happens to compute to TP.CM or TP.DT.
fn test_an_eight_byte_fd_frame_is_not_a_tp_frame() {
	mut fd_bam := bam(0x00, 20, dm1)
	fd_bam.fd = true
	assert fd_bam.data.len == 8, 'the length alone cannot refuse it'
	assert !tp_shaped(fd_bam)
	mut r := Reassembler{}
	ev := r.feed(fd_bam, 0)
	assert ev.faults.len == 1 && ev.faults[0].kind == .malformed
	assert r.open() == 0, 'it opened no session'
	// and the walker refuses it too, or the two disagree about which frames belong to whom
	mut t := Transfers{}
	assert t.step_at(fd_bam, 0.0).role != .announce
	assert t.open() == 0
	// an FD data frame inside a real transfer is refused the same way
	mut q := Reassembler{}
	q.feed(bam(0x00, 20, dm1), 0)
	mut fd_dt := packets(0x00, addr_global, message(20))[0]
	fd_dt.fd = true
	dv := q.feed(fd_dt, 1)
	assert dv.faults.len == 1 && dv.faults[0].kind == .malformed
	assert dv.faults[0].detail.contains('CAN-FD')
	// while the classic frames of that transfer are read as ever
	mut ok := Reassembler{}
	ok.feed(bam(0x00, 20, dm1), 0)
	assert ok.feed(packets(0x00, addr_global, message(20))[0], 1).faults.len == 0
}

// 0x0000 is a legitimate parameter group, so "no group was announced" needs its own answer:
// read off `pgn != 0`, a transfer carrying it had its group left out of every line about it.
fn test_group_zero_is_a_group() {
	msg := message(20)
	mut r := Reassembler{}
	r.feed(bam(0x00, msg.len, 0), 0)
	r.feed(packets(0x00, addr_global, msg)[0], 10)
	ev := r.feed(bam(0x00, msg.len, 0), 2000) // a restart, so the first is reported
	assert ev.faults.len >= 1
	assert ev.faults[0].announced
	assert ev.faults[0].str().contains('PGN 0x0000'), ev.faults[0].str()
	// while a data frame with no announcement behind it still says nothing about a group
	mut o := Reassembler{}
	orphan := o.feed(packets(0x21, addr_global, msg)[0], 0)
	assert orphan.faults.len == 1
	assert !orphan.faults[0].announced
	assert !orphan.faults[0].str().contains('PGN')
}

// A REFUSED announcement names the group it carried: the flag is the caller's, because 0x0000
// is a legitimate group and no number can say whether one was announced.
fn test_a_refused_announcement_still_names_its_group() {
	mut r := Reassembler{}
	ev := r.feed(bam(0x00, 20, dm1), 0) // well-formed: nothing to report
	assert ev.faults.len == 0
	bad := cm(0x00, addr_global, cm_bam, 20, 4, dm1) // 20 bytes are 3 packets, never 4
	ev2 := r.feed(bad, 1)
	assert ev2.faults.len >= 1
	refused := ev2.faults.filter(it.kind == .malformed)
	assert refused.len == 1
	assert refused[0].announced
	assert refused[0].str().contains('PGN 0x${dm1:04X}'), refused[0].str()
}
