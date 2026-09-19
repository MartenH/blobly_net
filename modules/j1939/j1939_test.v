module j1939

// The id split, and the transport protocol as a table of exchanges. Every session below is
// written as the frames a bus would carry, in the order it would carry them, because that is
// the only form in which a reader can check the claim.

// ---------------------------------------------------------------- the identifier
fn test_a_broadcast_group_keeps_its_group_extension_and_names_no_destination() {
	// 0x0CF00400 — EEC1, the engine controller's headline group, from address 0x00.
	id := decode_id(0x0CF00400)
	assert id.priority == 3
	assert id.pf == 0xF0
	assert id.ps == 0x04
	assert id.sa == 0x00
	assert !id.pdu1()
	assert id.pgn() == 0xF004
	assert id.da() == none // PDU2 has no field for one
	
	assert id.broadcast()
	assert id.encode() == 0x0CF00400
}

fn test_an_addressed_group_drops_the_destination_from_the_group_number() {
	// 0x18EC0300 — TP.CM from 0x00 to 0x03. The PGN is 0xEC00, NOT 0xEC03.
	id := decode_id(0x18EC0300)
	assert id.priority == 6
	assert id.pf == 0xEC
	assert id.ps == 0x03
	assert id.sa == 0x00
	assert id.pdu1()
	assert id.pgn() == tp_cm_pgn
	assert id.da()? == 0x03
	assert !id.broadcast()
	assert id.encode() == 0x18EC0300
}

fn test_a_message_to_the_global_address_is_addressed_and_still_a_broadcast() {
	id := decode_id(0x18ECFF00)
	assert id.pdu1()
	assert id.da()? == addr_global
	assert id.broadcast()
}

fn test_the_page_bits_belong_to_the_group_number() {
	// DP set: PGN 0x1F004 rather than 0xF004.
	id := decode_id(0x0DF00400)
	assert id.dp
	assert !id.edp
	assert id.pgn() == 0x1F004
	// Both pages: the top of the 18-bit group-number space.
	both := decode_id(0x0FF00400)
	assert both.edp && both.dp
	assert both.pgn() == 0x3F004
}

fn test_pgn_of_is_the_same_answer_without_the_struct() {
	for id in [u32(0x0CF00400), 0x18EC0300, 0x18ECFF00, 0x0DF00400, 0x0FF00400, 0x18EBFF21,
		0x1CFE9200, 0x00000000, 0x1FFFFFFF] {
		assert pgn_of(id) == decode_id(id).pgn(), '0x${id:08X}'
	}
}

fn test_an_identifier_is_rebuilt_from_its_parts() {
	for id in [u32(0x0CF00400), 0x18EC0300, 0x1CFE9221, 0x1FFFFFFF] {
		assert decode_id(id).encode() == id, '0x${id:08X}'
	}
}

fn test_id_for_builds_the_identifier_a_reassembled_group_would_have_had() {
	// A broadcast group takes its group extension back out of the PGN; the destination given
	// is not a field it has.
	assert id_for(0xF004, 0x21, addr_global, 3) == 0x0CF00421
	// An addressed group puts the destination in the PDU-specific byte.
	assert id_for(0xEF00, 0x21, 0x03, 6) == 0x18EF0321
	// The page bits survive the trip.
	assert id_for(0x1F004, 0x00, addr_global, 3) == 0x0DF00400
	// And what it builds decomposes back to what it was asked for.
	back := decode_id(id_for(0xEF00, 0x21, 0x03, 6))
	assert back.pgn() == 0xEF00
	assert back.sa == 0x21
	assert back.da()? == 0x03
}

fn test_a_standard_frame_is_never_a_transport_frame() {
	assert !is_tp(0x18EC0300, false) // the same number, 11 bits wide, is somebody else's id
	
	assert is_tp(0x18EC0300, true)
	assert is_tp(0x18EBFF00, true)
	assert !is_tp(0x0CF00400, true)
}

fn test_the_reserved_addresses_are_named() {
	assert addr_str(0x00) == '00'
	assert addr_str(0x21) == '21'
	assert addr_str(addr_global) == 'all'
	assert addr_str(addr_null) == 'none'
}

// ---------------------------------------------------------------- frames, as a bus carries them
const data_pgn = u32(0x00FEE5) // Engine Hours, a real broadcast group over 8 bytes


fn cm_id(sa u8, da u8) u32 {
	return id_for(tp_cm_pgn, sa, da, 7)
}

fn dt_id(sa u8, da u8) u32 {
	return id_for(tp_dt_pgn, sa, da, 7)
}

fn bam(size int, packets int, pgn u32) []u8 {
	return [cm_bam, u8(size & 0xFF), u8(size >> 8), u8(packets), 0xFF, u8(pgn & 0xFF),
		u8((pgn >> 8) & 0xFF), u8((pgn >> 16) & 0xFF)]
}

fn rts(size int, packets int, pgn u32) []u8 {
	return [cm_rts, u8(size & 0xFF), u8(size >> 8), u8(packets), u8(packets), u8(pgn & 0xFF),
		u8((pgn >> 8) & 0xFF), u8((pgn >> 16) & 0xFF)]
}

fn cts(n u8, next u8, pgn u32) []u8 {
	return [cm_cts, n, next, 0xFF, 0xFF, u8(pgn & 0xFF), u8((pgn >> 8) & 0xFF),
		u8((pgn >> 16) & 0xFF)]
}

fn eoma(size int, packets int, pgn u32) []u8 {
	return [cm_eoma, u8(size & 0xFF), u8(size >> 8), u8(packets), 0xFF, u8(pgn & 0xFF),
		u8((pgn >> 8) & 0xFF), u8((pgn >> 16) & 0xFF)]
}

fn abort_frame(code u8, pgn u32) []u8 {
	return [cm_abort, code, 0xFF, 0xFF, 0xFF, u8(pgn & 0xFF), u8((pgn >> 8) & 0xFF),
		u8((pgn >> 16) & 0xFF)]
}

// dt is packet `seq` of `payload`, padded the way the protocol pads: 0xFF to eight bytes.
fn dt(seq int, payload []u8) []u8 {
	off := (seq - 1) * tp_bytes_per_packet
	mut f := [u8(seq)]
	for i in 0 .. tp_bytes_per_packet {
		f << if off + i < payload.len { payload[off + i] } else { u8(0xFF) }
	}
	return f
}

fn payload(n int) []u8 {
	return []u8{len: n, init: u8(index + 1)} // 01 02 03 … so a misplaced packet is visible
}

// ---------------------------------------------------------------- broadcast
fn test_a_broadcast_transfer_is_rebuilt_from_its_packets() {
	p := payload(20)
	mut r := Reassembler{}
	assert r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0).done.len == 0
	assert r.pending() == 1
	assert r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, p), 50).done.len == 0
	assert r.observe(dt_id(0x00, addr_global), true, false, false, dt(2, p), 100).done.len == 0
	ev := r.observe(dt_id(0x00, addr_global), true, false, false, dt(3, p), 150)
	assert ev.aborted.len == 0
	assert ev.done.len == 1
	m := ev.done[0]
	assert m.pgn == data_pgn
	assert m.sa == 0x00
	assert m.da == addr_global
	assert m.kind == .bam
	assert m.packets == 3
	assert m.data == p // the padding of the last packet is not part of the message
	
	assert m.t_ms == 150 // when it FINISHED arriving
	// The SESSION's priority, which is all the wire ever said about this message's. It is what
	// a caller synthesising an identifier for the rebuilt message has to use, and a screenshot
	// of the trace is what caught it reading 0 when the transfer ran at 7.
	assert m.priority == 7
	
	assert r.pending() == 0
	assert r.counts().orphan_dt == 0
}

fn test_a_broadcast_that_stops_halfway_is_abandoned_and_said() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, p), 50)
	// Nothing for longer than a broadcast transfer is allowed to pause.
	assert r.tick(700).len == 0 // not yet
	
	ab := r.tick(801)
	assert ab.len == 1
	assert ab[0].got == 1
	assert ab[0].packets == 3
	assert ab[0].pgn == data_pgn
	assert ab[0].kind == .bam
	assert ab[0].reason.contains('750 ms')
	assert ab[0].priority == 7 // an abandoned transfer names its session the same way
	assert r.pending() == 0
}

fn test_a_second_announcement_from_one_sender_replaces_the_first() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, p), 50)
	ev := r.observe(cm_id(0x00, addr_global), true, false, false, bam(14, 2, 0x00FEF1), 100)
	assert ev.aborted.len == 1
	assert ev.aborted[0].pgn == data_pgn // the OLD one is what was abandoned
	
	assert ev.aborted[0].got == 1
	assert ev.aborted[0].reason.contains('replaced')
	assert r.pending() == 1 // and the new one is being followed
	
}

// ---------------------------------------------------------------- connection mode
fn test_a_connection_mode_transfer_is_rebuilt_and_the_handshake_keeps_it_alive() {
	p := payload(16) // 3 packets
	mut r := Reassembler{}
	r.observe(cm_id(0x00, 0x03), true, false, false, rts(16, 3, data_pgn), 0)
	// The receiver answers. It is sent the OTHER way round -- from 0x03 to 0x00 -- and must
	// still be recognised as this session, or the transfer times out during its own handshake.
	assert r.observe(cm_id(0x03, 0x00), true, false, false, cts(3, 1, data_pgn), 1000).aborted.len == 0
	assert r.pending() == 1
	// Past the deadline the RTS alone would have set, but the CTS moved it.
	assert r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 2000).done.len == 0
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(2, p), 2050)
	ev := r.observe(dt_id(0x00, 0x03), true, false, false, dt(3, p), 2100)
	assert ev.done.len == 1
	assert ev.done[0].data == p
	assert ev.done[0].kind == .cm
	assert ev.done[0].da == 0x03
}

fn test_a_packet_sent_again_lands_where_it_belongs() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 10)
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(3, p), 20) // out of order, as a CTS may ask
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 30) // and again
	assert r.pending() == 1
	ev := r.observe(dt_id(0x00, 0x03), true, false, false, dt(2, p), 40)
	assert ev.done.len == 1
	assert ev.done[0].data == p
	assert ev.done[0].packets == 3
}

fn test_an_acknowledgement_for_a_transfer_this_tool_did_not_finish_says_so() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 10)
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(2, p), 20)
	// The receiver says it got the whole thing -- so the missing packet is one WE dropped.
	ev := r.observe(cm_id(0x03, 0x00), true, false, false, eoma(20, 3, data_pgn), 30)
	assert ev.done.len == 0
	assert ev.aborted.len == 1
	assert ev.aborted[0].got == 2
	assert ev.aborted[0].packets == 3
	assert ev.aborted[0].reason.contains('reached this tool')
	assert r.pending() == 0
}

fn test_an_acknowledgement_for_a_transfer_already_complete_settles_nothing() {
	p := payload(16)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, 0x03), true, false, false, rts(16, 3, data_pgn), 0)
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 10)
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(2, p), 20)
	assert r.observe(dt_id(0x00, 0x03), true, false, false, dt(3, p), 30).done.len == 1
	ev := r.observe(cm_id(0x03, 0x00), true, false, false, eoma(16, 3, data_pgn), 40)
	assert ev.done.len == 0 && ev.aborted.len == 0
}

fn test_either_end_may_abort_and_the_reason_is_carried() {
	p := payload(20)
	// The sender gives up.
	mut r := Reassembler{}
	r.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 10)
	ev := r.observe(cm_id(0x00, 0x03), true, false, false, abort_frame(3, data_pgn), 20)
	assert ev.aborted.len == 1
	assert ev.aborted[0].reason.contains('aborted by 00')
	assert ev.aborted[0].reason.contains('a timeout occurred')
	assert r.pending() == 0
	// The receiver gives up: the frame's own addresses are the other way round.
	mut r2 := Reassembler{}
	r2.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0)
	r2.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 10)
	ev2 := r2.observe(cm_id(0x03, 0x00), true, false, false, abort_frame(1, data_pgn), 20)
	assert ev2.aborted.len == 1
	assert ev2.aborted[0].reason.contains('aborted by 03')
	assert ev2.aborted[0].reason.contains('already in a connection-managed session')
	assert r2.pending() == 0
}

fn test_an_unnamed_abort_code_is_reported_as_its_number() {
	assert abort_reason(9) == 'total message size too big'
	assert abort_reason(250) == 'no reason given'
	assert abort_reason(77) == 'reason 77'
}

// ---------------------------------------------------------------- what it refuses
fn test_an_announcement_that_does_not_describe_a_transport_message_is_refused() {
	mut r := Reassembler{}
	// Eight bytes or fewer would simply have been sent as a frame.
	a := r.observe(cm_id(0x00, addr_global), true, false, false, bam(8, 2, data_pgn), 0).aborted
	assert a.len == 1 && a[0].reason.contains('not a transport message')
	// More than 255 packets can carry.
	b := r.observe(cm_id(0x00, addr_global), true, false, false, bam(2000, 255, data_pgn), 0).aborted
	assert b.len == 1 && b[0].reason.contains('past the 1785')
	// A packet count that does not follow from the size: 20 bytes is 3 packets, never 4.
	c := r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 4, data_pgn), 0).aborted
	assert c.len == 1 && c[0].reason.contains('do not agree')
	assert r.pending() == 0
	assert r.counts().refused == 3
}

fn test_a_packet_outside_the_announced_run_ends_the_transfer() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, p), 10)
	mut bad := dt(2, p)
	bad[0] = 9
	ev := r.observe(dt_id(0x00, addr_global), true, false, false, bad, 20)
	assert ev.aborted.len == 1
	assert ev.aborted[0].reason.contains('outside the announced 1..3')
	assert r.pending() == 0
	// Sequence 0 is not a packet number either.
	mut r2 := Reassembler{}
	r2.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	mut zero := dt(1, p)
	zero[0] = 0
	assert r2.observe(dt_id(0x00, addr_global), true, false, false, zero, 10).aborted.len == 1
}

fn test_packets_for_a_transfer_that_was_never_announced_are_counted_not_reported() {
	p := payload(20)
	mut r := Reassembler{}
	// A measurement started in the middle of somebody's transfer.
	for seq in 1 .. 4 {
		ev := r.observe(dt_id(0x00, addr_global), true, false, false, dt(seq, p), f64(seq * 10))
		assert ev.done.len == 0 && ev.aborted.len == 0
	}
	assert r.counts().orphan_dt == 3
	assert r.pending() == 0
}

fn test_a_transport_frame_this_cannot_read_is_counted() {
	mut r := Reassembler{}
	// Short: the protocol pads to eight, so a shorter one has a field cut off.
	assert r.observe(cm_id(0x00, addr_global), true, false, false, [u8(0x20), 20, 0], 0).done.len == 0
	// A control byte with no meaning here.
	r.observe(cm_id(0x00, addr_global), true, false, false, [u8(0x42), 0, 0, 0, 0, 0, 0, 0], 0)
	assert r.counts().malformed == 2
	assert r.counts().refused == 0 // a frame it could not read is not an announcement it refused
	
}

fn test_one_wire_follows_only_so_many_transfers_at_once() {
	mut r := Reassembler{}
	for sa in 0 .. max_sessions {
		r.observe(cm_id(u8(sa), addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	}
	assert r.pending() == max_sessions
	ev := r.observe(cm_id(u8(max_sessions), addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	assert ev.aborted.len == 1
	assert ev.aborted[0].reason.contains('already open')
	assert r.pending() == max_sessions
	// But a sender whose session is already open may still replace its own.
	ev2 := r.observe(cm_id(0, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	assert ev2.aborted.len == 1 && ev2.aborted[0].reason.contains('replaced')
	assert r.pending() == max_sessions
}

// ---------------------------------------------------------------- several at once
fn test_two_senders_interleaved_do_not_mix() {
	a := payload(20)
	mut b := payload(20)
	for i in 0 .. b.len {
		b[i] = u8(0x80 + i)
	}
	mut r := Reassembler{}
	r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	r.observe(cm_id(0x21, addr_global), true, false, false, bam(20, 3, 0x00FEF1), 1)
	assert r.pending() == 2
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, a), 10)
	r.observe(dt_id(0x21, addr_global), true, false, false, dt(1, b), 11)
	r.observe(dt_id(0x21, addr_global), true, false, false, dt(2, b), 12)
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(2, a), 13)
	first := r.observe(dt_id(0x21, addr_global), true, false, false, dt(3, b), 14)
	assert first.done.len == 1
	assert first.done[0].sa == 0x21
	assert first.done[0].data == b
	second := r.observe(dt_id(0x00, addr_global), true, false, false, dt(3, a), 15)
	assert second.done.len == 1
	assert second.done[0].sa == 0x00
	assert second.done[0].data == a
	assert r.pending() == 0
}

fn test_one_sender_may_broadcast_and_address_at_the_same_time() {
	// The pair is the key, so a BAM (to everybody) and a connection to 0x03 from one sender
	// are two transfers, not one replacing the other.
	p := payload(16)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, addr_global), true, false, false, bam(16, 3, data_pgn), 0)
	r.observe(cm_id(0x00, 0x03), true, false, false, rts(16, 3, 0x00FEF1), 1)
	assert r.pending() == 2
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 2)
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(2, p), 3)
	ev := r.observe(dt_id(0x00, 0x03), true, false, false, dt(3, p), 4)
	assert ev.done.len == 1
	assert ev.done[0].da == 0x03
	assert r.pending() == 1 // the broadcast is still going
	
}

fn test_the_end_of_a_measurement_names_what_was_still_in_flight() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, p), 10)
	r.observe(cm_id(0x21, 0x03), true, false, false, rts(20, 3, data_pgn), 11)
	left := r.close(20)
	assert left.len == 2
	assert r.pending() == 0
	assert left.all(it.reason.contains('measurement ended'))
	assert r.close(30).len == 0
}

fn test_a_sweep_reports_every_transfer_that_stopped() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	r.observe(cm_id(0x21, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, p), 10)
	// The sweep rides the next transport frame, not only the idle path: a third sender
	// announcing at t=1000 is where the first two are noticed to have stopped.
	ev := r.observe(cm_id(0x42, addr_global), true, false, false, bam(20, 3, data_pgn), 1000)
	assert ev.aborted.len == 2
	assert r.pending() == 1
}

fn test_a_frame_that_is_not_transport_settles_nothing_and_opens_nothing() {
	mut r := Reassembler{}
	ev := r.observe(0x0CF00400, true, false, false, [u8(1), 2, 3, 4, 5, 6, 7, 8], 0)
	assert ev.done.len == 0 && ev.aborted.len == 0
	assert r.pending() == 0
	assert r.counts() == Counts{}
}

// ---------------------------------------------------------------- a recording answering for itself

fn test_a_well_formed_announcement_is_evidence_of_a_j1939_recording() {
	// A live wire has an owner to ask; a file somebody sends you has nobody, so the bytes
	// answer. Both spellings of an announcement count.
	assert announces_session(0x1CECFF00, true, false, false, bam(20, 3, data_pgn))
	assert announces_session(0x18EC0300, true, false, false, rts(20, 3, data_pgn))
}

fn test_nothing_else_in_a_recording_is_taken_as_evidence() {
	// Not a session frame at all, and not a standard-id frame that happens to share the number.
	assert !announces_session(0x0CF00400, true, false, false, [u8(1), 2, 3, 4, 5, 6, 7, 8])
	assert !announces_session(0x1CECFF00, false, false, false, bam(20, 3, data_pgn))
	// A data packet is not an announcement: it says nothing about how long the message is.
	assert !announces_session(0x1CEBFF00, true, false, false, dt(1, payload(20)))
	// The handshake frames are not announcements either — only the two that open a transfer.
	assert !announces_session(0x18EC0003, true, false, false, cts(3, 1, data_pgn))
	assert !announces_session(0x18EC0003, true, false, false, eoma(20, 3, data_pgn))
	assert !announces_session(0x18EC0300, true, false, false, abort_frame(3, data_pgn))
	// Short, so the numbers cannot be read at all.
	assert !announces_session(0x1CECFF00, true, false, false, [u8(0x20), 20, 0])
}

// The evidence test and the acceptance test are ONE rule: a looser evidence test would claim a
// bus this reassembler then refuses to read.
fn test_evidence_is_exactly_what_the_reassembler_would_accept() {
	for spec in [[8, 2], [2000, 255], [20, 4], [9, 2], [0, 0]] {
		size, packets := spec[0], spec[1]
		f := bam(size, packets, data_pgn)
		mut r := Reassembler{}
		accepted := r.observe(0x1CECFF00, true, false, false, f, 0).aborted.len == 0
		assert announces_session(0x1CECFF00, true, false, false, f) == accepted, '${size} bytes in ${packets}'
	}
	assert announcement_refusal(cm_bam, addr_global, 0xFF, data_pgn, 20, 3) == ''
	assert announcement_refusal(cm_bam, addr_global, 0xFF, data_pgn, 8, 2) != ''
}

fn test_the_page_bits_are_part_of_the_group_so_another_page_is_another_group() {
	// 0x1EC00 and 0x1EB00 are not this protocol's groups; reading the format byte alone let
	// one be taken apart as an announcement (codex).
	assert !is_tp(0x19ECFF00, true) // DP set
	assert !is_tp(0x1BEBFF00, true) // EDP set
	assert !announces_session(0x19ECFF00, true, false, false, bam(20, 3, data_pgn))
	mut r := Reassembler{}
	assert r.observe(0x19ECFF00, true, false, false, bam(20, 3, data_pgn), 0).aborted.len == 0
	assert r.pending() == 0
}

// A node may be sending one transfer and receiving another to the same peer at once. The PGN in
// the abort's own bytes is what says which one it means; without it, a node abandoning the
// transfer it was RECEIVING tore down its outgoing one instead (codex).
fn test_an_abort_ends_the_transfer_its_pgn_names_not_the_nearest_one() {
	other_pgn := u32(0x00FEF1)
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0) // 00 -> 03, sending
	r.observe(cm_id(0x03, 0x00), true, false, false, rts(20, 3, other_pgn), 1) // 03 -> 00, the other way
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 2)
	assert r.pending() == 2
	// 03 abandons the transfer IT is sending, naming that transfer's group.
	ev := r.observe(cm_id(0x03, 0x00), true, false, false, abort_frame(3, other_pgn), 3)
	assert ev.aborted.len == 1
	assert ev.aborted[0].pgn == other_pgn
	assert ev.aborted[0].sa == 0x03
	assert r.pending() == 1
	// and the one 00 is sending is untouched, so its last packets still complete it
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(2, p), 4)
	done := r.observe(dt_id(0x00, 0x03), true, false, false, dt(3, p), 5).done
	assert done.len == 1 && done[0].pgn == data_pgn
}

fn test_an_abort_naming_no_open_transfer_settles_nothing() {
	mut r := Reassembler{}
	r.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0)
	// An abort for a peer this side is not following at all.
	assert r.observe(cm_id(0x11, 0x12), true, false, false, abort_frame(3, data_pgn), 1).aborted.len == 0
	assert r.pending() == 1
	// One naming a group nobody here is carrying still ends the session it is addressed to,
	// since the peers agree the connection is over whatever this side made of the numbers.
	ev := r.observe(cm_id(0x03, 0x00), true, false, false, abort_frame(3, 0x00FFFF), 2)
	assert ev.aborted.len == 1 && ev.aborted[0].pgn == data_pgn
	assert r.pending() == 0
}

// A BAM is announced to everybody and an RTS opens a connection to one node: the mode and the
// destination are one statement. Left unchecked, an addressed BAM was proof enough to read a
// whole recording as J1939 and to complete a session that cannot exist (codex).
fn test_an_announcement_must_agree_with_its_own_destination() {
	mut r := Reassembler{}
	addressed_bam := r.observe(cm_id(0x00, 0x03), true, false, false, bam(20, 3, data_pgn), 0).aborted
	assert addressed_bam.len == 1 && addressed_bam[0].reason.contains('addressed to 03')
	global_rts := r.observe(cm_id(0x00, addr_global), true, false, false, rts(20, 3, data_pgn), 0).aborted
	assert global_rts.len == 1 && global_rts[0].reason.contains('addressed to everybody')
	assert r.pending() == 0
	assert !announces_session(cm_id(0x00, 0x03), true, false, false, bam(20, 3, data_pgn))
	assert !announces_session(cm_id(0x00, addr_global), true, false, false, rts(20, 3, data_pgn))
	// and the two well-formed pairings are still accepted, by both questions
	assert announces_session(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn))
	assert announces_session(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn))
}

// A remote frame ASKS for a payload and carries none; a backend that hands back a buffer of the
// requested length anyway delivered one here as sequence 0, which tore down a live transfer.
fn test_a_remote_frame_is_never_part_of_a_session() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, p), 10)
	// a remote frame at a TP.DT identifier, with a driver's zero-filled placeholder payload
	ev := r.observe(dt_id(0x00, addr_global), true, true, false, []u8{len: 8}, 20)
	assert ev.aborted.len == 0 && ev.done.len == 0
	assert r.pending() == 1 // the transfer is untouched
	assert r.counts().malformed == 1
	// and it completes as if the remote frame had never happened
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(2, p), 30)
	done := r.observe(dt_id(0x00, addr_global), true, false, false, dt(3, p), 40).done
	assert done.len == 1 && done[0].data == p
	// a remote frame is not evidence of a J1939 recording either
	assert !announces_session(cm_id(0x00, addr_global), true, true, false, bam(20, 3, data_pgn))
}

// Counting something nothing reads is not reporting it (#213's lesson, one layer over), so the
// counters have to be reachable: `orphan_seen` is the moment, `counts` the total.
fn test_what_is_counted_can_be_read_back() {
	p := payload(20)
	mut r := Reassembler{}
	assert !r.orphan_seen()
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(2, p), 0) // joined mid-transfer
	assert r.orphan_seen()
	assert r.counts().orphan_dt == 1
	// and it is the LAST frame's answer, not a latch of its own: the caller latches.
	r.observe(0x0CF00400, true, false, false, [u8(1), 2, 3, 4, 5, 6, 7, 8], 1)
	assert !r.orphan_seen()
	assert r.counts().orphan_dt == 1
	r.observe(cm_id(0x00, addr_global), true, false, false, [u8(0x42), 0, 0, 0, 0, 0, 0, 0], 2)
	assert r.counts() == Counts{
		orphan_dt: 1
		malformed: 1
	}
}

// THE CLASS, not the instance. Two rounds found this one half at a time — a value past the
// 18-bit field, then a PDU1 value whose destination byte was not zero — and both mattered for
// the same reason: the session carries the announced bytes, `id_for` rebuilds the identifier by
// the encoding rules, and any bit the encoding does not keep is a bit on which the rebuilt row
// names a different group from the one announced.
fn test_only_a_canonical_group_number_is_announced() {
	for good in [u32(0xF004), 0xFEE5, 0xEF00, 0xEC00, 0x1F004, 0x3FFFF, 0x0000, 0x3FF00] {
		assert canonical_pgn(good), '0x${good:06X}'
		// and the identifier built from it decomposes back to it, which is the whole point
		assert decode_id(id_for(good, 0x21, 0x03, 6)).pgn() == good, '0x${good:06X}'
	}
	// past the field, or a PDU1 group carrying a destination byte
	for bad in [u32(0x40000), 0xFFFEE5, 0xEF12, 0xEC03, 0x1EF01, 0x00FF] {
		assert !canonical_pgn(bad), '0x${bad:06X}'
	}
	// and every one of them is refused as an announcement, and is not evidence of a J1939 bus
	for bad in [u32(0x40000), 0xFFFEE5, 0xEF12, 0xEC03, 0x00FF] {
		mut r := Reassembler{}
		ev := r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, bad), 0)
		assert ev.aborted.len == 1, '0x${bad:06X}'
		assert ev.aborted[0].reason.contains('parameter group'), '0x${bad:06X}'
		assert r.pending() == 0
		assert !announces_session(cm_id(0x00, addr_global), true, false, false, bam(20, 3, bad))
	}
}

// THE OTHER CLASS. Three rounds found this one control frame at a time — the abort, then the
// acknowledgement, then the clear-to-send — each matched by address alone, so a stale or
// malformed frame reached whatever transfer happened to be open between those two nodes. One
// table over all three, so a fourth control frame cannot repeat it.
fn test_a_control_frame_only_ever_reaches_the_transfer_it_names() {
	other := u32(0x00FEF1)
	p := payload(20)
	for kind in ['cts', 'eoma', 'abort'] {
		mut r := Reassembler{}
		r.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0)
		r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 10)
		assert r.pending() == 1, kind
		// the frame, naming ANOTHER group, travelling between the same two addresses
		stale := match kind {
			'cts' { cts(3, 1, other) }
			'eoma' { eoma(20, 3, other) }
			else { abort_frame(3, other) }
		}
		ev := r.observe(cm_id(0x03, 0x00), true, false, false, stale, 20)
		if kind == 'abort' {
			// the one exception, deliberate: an abort ENDS the transfer it is addressed to
			// even when it names no group this side is following, because the peers have
			// agreed the connection is over.
			assert ev.aborted.len == 1, kind
			assert r.pending() == 0, kind
			continue
		}
		assert ev.aborted.len == 0, kind
		assert r.pending() == 1, kind
		// and the transfer is untouched: its own packets still complete it
		r.observe(dt_id(0x00, 0x03), true, false, false, dt(2, p), 30)
		done := r.observe(dt_id(0x00, 0x03), true, false, false, dt(3, p), 40).done
		assert done.len == 1 && done[0].data == p, kind
	}
}

// The deadline is the other half of "reaches": a stream of stale clear-to-sends held an
// unrelated transfer open instead of letting it be abandoned.
fn test_a_stale_clear_to_send_does_not_hold_another_transfer_open() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 10)
	for t in [f64(500), 1000, 1200] {
		assert r.observe(cm_id(0x03, 0x00), true, false, false, cts(3, 2, 0x00FEF1), t).aborted.len == 0
	}
	// past the deadline the last real frame set, which no stale one has moved
	ev := r.observe(cm_id(0x03, 0x00), true, false, false, cts(3, 2, 0x00FEF1), 1300)
	assert ev.aborted.len == 1 && ev.aborted[0].pgn == data_pgn
	assert r.pending() == 0
	// while the RIGHT one does move it
	mut r2 := Reassembler{}
	r2.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0)
	r2.observe(cm_id(0x03, 0x00), true, false, false, cts(3, 1, data_pgn), 1000)
	assert r2.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 2000).aborted.len == 0
	assert r2.pending() == 1
}

// A stream of frames this cannot read is still a stream of transport frames: skipping the sweep
// on them held an expired session open for as long as they kept coming (codex).
fn test_unreadable_frames_do_not_hold_an_expired_transfer_open() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, p), 10)
	// short, then remote, both past the deadline
	ev := r.observe(cm_id(0x00, addr_global), true, false, false, [u8(0x20), 1, 2], 900)
	assert ev.aborted.len == 1 && ev.aborted[0].reason.contains('750 ms')
	assert r.pending() == 0
	mut r2 := Reassembler{}
	r2.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	ev2 := r2.observe(dt_id(0x00, addr_global), true, true, false, []u8{len: 8}, 900)
	assert ev2.aborted.len == 1
	assert r2.counts().malformed == 1
}

// A transport session is CLASSIC CAN, eight bytes, always — the protocol exists because a
// classic frame carries eight. One predicate for the shape, so the reader, the importer and
// the reassembler cannot answer it differently.
fn test_only_a_classic_eight_byte_frame_is_part_of_a_session() {
	good := bam(20, 3, data_pgn)
	id := cm_id(0x00, addr_global)
	assert tp_frame(id, true, false, false, 8)
	for bad in [
		[1, 0, 0, 8], // standard id
		[0, 1, 0, 8], // remote
		[0, 0, 1, 8], // CAN-FD
		[0, 0, 0, 7], // short
		[0, 0, 0, 12], // an FD-sized payload on a classic flag
	] {
		assert !tp_frame(id, bad[0] == 0, bad[1] == 1, bad[2] == 1, bad[3]), '${bad}'
	}
	// and each of those is refused by both questions, and counted rather than read
	mut r := Reassembler{}
	assert r.observe(id, true, false, true, good, 0).done.len == 0 // FD
	assert !announces_session(id, true, false, true, good)
	assert r.pending() == 0 && r.counts().malformed == 1
	// a 12-byte payload at a transport identifier is not a longer announcement
	long := good.clone()
	assert r.observe(id, true, false, false, long, 0).aborted.len == 0
	assert r.pending() == 1 // the well-formed one still opens
}

// The acknowledgement carries its transfer's SIZE and PACKET COUNT as well as its group, and a
// delayed one from an earlier transfer between the same nodes closed the live one.
fn test_an_acknowledgement_names_its_transfer_by_size_too() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, 0x03), true, false, false, dt(1, p), 10)
	// same addresses, same group, another transfer's dimensions
	assert r.observe(cm_id(0x03, 0x00), true, false, false, eoma(16, 3, data_pgn), 20).aborted.len == 0
	assert r.observe(cm_id(0x03, 0x00), true, false, false, eoma(20, 2, data_pgn), 21).aborted.len == 0
	assert r.pending() == 1
	// and the one that matches closes it
	ev := r.observe(cm_id(0x03, 0x00), true, false, false, eoma(20, 3, data_pgn), 22)
	assert ev.aborted.len == 1 && ev.aborted[0].reason.contains('reached this tool')
	assert r.pending() == 0
}

// A second announcement between one pair means the sender has moved on, so the transfer it
// replaces is over EVEN IF the new one cannot be read. Left open, the rejected transfer's data
// packets were applied to it and fabricated a message under the old group with the new payload.
fn test_an_unreadable_announcement_still_retires_the_one_it_replaces() {
	p := payload(20)
	mut r := Reassembler{}
	r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0)
	r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, p), 10)
	assert r.pending() == 1
	// a second announcement from the same sender, with a size and count that disagree
	ev := r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 4, 0x00FEF1), 20)
	assert ev.aborted.len == 2 // the old transfer, and the refusal of the new one
	assert ev.aborted.any(it.pgn == data_pgn && it.reason.contains('replaced by an announcement'))
	assert ev.aborted.any(it.pgn == 0x00FEF1 && it.reason.contains('do not agree'))
	assert r.pending() == 0
	// and the rejected transfer's packets now belong to nothing rather than to the old session
	assert r.observe(dt_id(0x00, addr_global), true, false, false, dt(2, p), 30).done.len == 0
	assert r.counts().orphan_dt == 1
}

// Byte 4 is reserved IN A BAM at 0xFF. In an RTS the same byte is a real field — how many
// packets the sender may send per CTS — which a passive observer does not act on.
fn test_a_broadcast_announcement_has_its_reserved_byte() {
	mut bad := bam(20, 3, data_pgn)
	bad[4] = 0x03
	mut r := Reassembler{}
	ev := r.observe(cm_id(0x00, addr_global), true, false, false, bad, 0)
	assert ev.aborted.len == 1 && ev.aborted[0].reason.contains('reserved byte')
	assert r.pending() == 0
	assert !announces_session(cm_id(0x00, addr_global), true, false, false, bad)
	// an RTS carries its own number there and is accepted
	assert announces_session(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn))
	assert r.observe(cm_id(0x00, 0x03), true, false, false, rts(20, 3, data_pgn), 0).aborted.len == 0
	assert r.pending() == 1
}

// The module says whether a frame WAS a session frame, so a caller cannot answer it differently
// — which is how the frames it exists to refuse stopped reaching it at all.
fn test_the_module_says_what_the_frame_was() {
	mut r := Reassembler{}
	assert !r.observe(0x0CF00400, true, false, false, [u8(1), 2, 3, 4, 5, 6, 7, 8], 0).part
	assert r.observe(cm_id(0x00, addr_global), true, false, false, bam(20, 3, data_pgn), 0).part
	assert r.observe(dt_id(0x00, addr_global), true, false, false, dt(1, payload(20)), 1).part
	// a shape it refuses is NOT a session frame, and is counted
	assert !r.observe(cm_id(0x00, addr_global), true, false, true, bam(20, 3, data_pgn), 2).part
	assert !r.observe(dt_id(0x00, addr_global), true, true, false, []u8{len: 8}, 3).part
	assert !r.observe(cm_id(0x00, addr_global), true, false, false, [u8(0x20), 1], 4).part
	assert r.counts().malformed == 3
}
