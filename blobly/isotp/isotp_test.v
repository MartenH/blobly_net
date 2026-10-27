module isotp

import blobly.transport
import time

// SnRecv runs recv() in a spawned thread (spawn forbids mut non-reference args, so the channel
// is held by reference) and records whether it returned data or an error.
struct SnRecv {
mut:
	ch      &SoftChannel = unsafe { nil }
	err_msg string
	ok      bool
}

fn (mut r SnRecv) run() {
	if _ := r.ch.recv(800) {
		r.ok = true
	} else {
		r.err_msg = err.msg()
	}
}

// A Consecutive-Frame sequence gap (a dropped frame) must surface as a clean error rather than
// silently misassembling the transfer. The old receiver `continue`d past any non-CF and never
// checked SNs, so a lost frame corrupted the block AND swallowed the next message's First Frame,
// which then surfaced as a spurious "unexpected PCI" on the following recv() — the multi-block
// trace-dump desync. This asserts both halves of the fix: recv() errors cleanly on the gap, AND
// the aborted transfer's stale tail is flushed so the SAME channel resyncs for the next message.
fn test_cf_sequence_gap_errors_then_channel_resyncs() {
	mut rx := open_software('inproc:ISOTPSN', 0x100, 0x200, false) or { panic(err) }
	mut raw := transport.open('inproc:ISOTPSN') or { panic(err) }
	mut r := &SnRecv{
		ch: rx
	}

	// First Frame: total 14 bytes, first 6 of payload. The receiver replies with Flow Control
	// (on 0x100) and then waits for CF sequence number 1.
	raw.send(transport.CanFrame{ id: 0x200, data: [u8(0x10), 14, 1, 2, 3, 4, 5, 6] }) or { panic(err) }
	spawn r.run()
	time.sleep(40 * time.millisecond) // let recv() read the FF, send FC, and wait for a CF

	// A CF with the WRONG sequence number (SN 2, expected 1) — a dropped-frame gap — followed by
	// the aborted transfer's stale tail (SN 3, 4). Without the flush those would poison the next
	// recv() with an "unexpected PCI"; the fix drains them.
	raw.send(transport.CanFrame{ id: 0x200, data: [u8(0x22), 7, 8, 9, 10, 11, 12, 13] }) or { panic(err) }
	raw.send(transport.CanFrame{ id: 0x200, data: [u8(0x23), 0, 0, 0, 0, 0, 0, 0] }) or { panic(err) }
	raw.send(transport.CanFrame{ id: 0x200, data: [u8(0x24), 0, 0, 0, 0, 0, 0, 0] }) or { panic(err) }
	time.sleep(120 * time.millisecond) // recv() errors on the gap, then flush_rx drains the tail

	assert !r.ok, 'recv() should have failed on the sequence gap, not returned data'
	assert r.err_msg.contains('sequence') || r.err_msg.contains('CF'), 'unexpected error: ${r.err_msg}'

	// The channel must now be reusable: a fresh Single Frame is received cleanly (the stale CFs
	// were flushed, so recv() starts on the new message, not a leftover 0x2x).
	raw.send(transport.CanFrame{ id: 0x200, data: [u8(0x03), 0xAA, 0xBB, 0xCC, 0, 0, 0, 0] }) or { panic(err) }
	got := rx.recv(500) or { panic('resync recv failed: ${err}') }
	assert got == [u8(0xAA), 0xBB, 0xCC], 'channel did not resync: got ${got}'
	rx.close()
	raw.close()
}

// ISOTP.OPEN EXISTS ON EVERY PLATFORM, and off Linux it is the software channel over whatever bus
// the address names — here the in-process bus, so the test needs no hardware and no kernel. On
// Linux `open` is the kernel socket, which has no such bus, so the answer there is a different
// test's (#220: the two smoke tools calling `open` did not compile on Windows for months, because
// it lived in the Linux file and nothing in CI compiled them).
fn test_open_reaches_the_software_channel_off_linux() {
	$if !linux {
		mut ch := open('inproc:isotp-open', 0x7E0, 0x7E8, false) or {
			assert false, 'isotp.open must open a software channel on the in-process bus: ${err}'
			return
		}
		assert ch.tx_id == 0x7E0 && ch.rx_id == 0x7E8
		ch.close()
	}
}

// AN EMPTY PDU IS REFUSED BY THE SOFTWARE CHANNEL, as the kernel channel refuses it: the two
// backends behind one open() must answer alike (codex round 2 on #225).
fn test_the_software_channel_refuses_an_empty_pdu() {
	mut ch := open_software('inproc:isotp-empty', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel on the in-process bus: ${err}'
		return
	}
	if _ := ch.send([]u8{}) {
		assert false, 'an empty PDU must not be transmitted'
	} else {
		assert err.msg() == 'isotp send: empty pdu'
	}
	ch.close()
}

// AN EMPTY FRAME WHERE FLOW CONTROL WAS EXPECTED IS AN ERROR, NOT A PANIC (codex round 3 on #225).
fn test_an_empty_frame_in_place_of_flow_control_is_an_error() {
	mut peer := transport.open('inproc:isotp-empty-fc') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-empty-fc', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	// the empty frame follows a sleep, on the test's schedule
	ch.fc_window_ms = test_fc_window_ms
	mut s := start_send(mut ch, 20)
	time.sleep(50 * time.millisecond)
	peer.send(transport.CanFrame{ id: 0x7E8 }) or { assert false, err.msg() }
	msg := s.wait()
	assert msg.contains('empty frame'), msg
	ch.close()
	peer.close()
}

// THE RECEIVE TIMEOUT BOUNDS THE WHOLE PDU: a peer that stalls just under it between Consecutive
// Frames cannot stretch a 300 ms receive into seconds (codex round 3 on #225).
fn test_the_receive_deadline_covers_the_whole_pdu() {
	mut peer := transport.open('inproc:isotp-slow-cf') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-slow-cf', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	spawn fn [mut peer] () {
		// FF announcing 20 bytes, then one CF every 200 ms — each inside a 300 ms budget on its own.
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 20, 1, 2, 3, 4, 5, 6] }) or {}
		for sn in 1 .. 4 {
			time.sleep(200 * time.millisecond)
			peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x20 | sn), 0, 0, 0, 0, 0, 0, 0] }) or {}
		}
	}()
	t0 := time.ticks()
	if _ := ch.recv(300) {
		assert false, 'a stalled peer must not complete within the budget'
	} else {
		// a message BEGAN: said as the stall it is, never as silence
		assert err.msg() == stall_note, err.msg()
	}
	took := time.ticks() - t0
	// THE MARGIN HERE IS ~300 ms AND IT IS A DELIBERATE TIMING ASSERTION, unlike the read
	// budgets above: correct is ~300 (the recv budget), renewed-per-frame is ~800 (four CFs
	// at 200 ms), and 600 splits them. That means a runner stall over ~300 ms fails this on a
	// CORRECT implementation -- the same class as the read deadlines, but it cannot simply be
	// made generous, because the number IS the property. Widening it wants a slower peer (a
	// longer CF interval moves 'broken' further out), not a bigger constant. Left as it is,
	// and written down so the next failure here is recognised rather than re-diagnosed.
	assert took < 600, 'recv(300) took ${took} ms: the deadline was renewed per frame'
	time.sleep(700 * time.millisecond) // the peer finishes the transfer meanwhile
	// THE TRANSFER IS NOT LOST: its late CFs, each within N_Cr of the last, complete it on the
	// next recv, as the kernel channel completes one behind a read that timed out (#467). AND THE
	// CHANNEL IS REUSABLE: the reply after it is the next message, not taken for its tail (codex
	// round 4 on #225).
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x01), 0xAA] }) or { assert false, err.msg() }
	done := ch.recv(500) or {
		assert false, 'the transfer the deadline cut short was not completed: ${err}'
		return
	}
	assert done.len == 20
	assert done[..6] == [u8(1), 2, 3, 4, 5, 6]
	next := ch.recv(500) or {
		assert false, 'the next reply was lost behind the completed transfer: ${err}'
		return
	}
	assert next == [u8(0xAA)]
	ch.close()
	peer.close()
}

// A SERVER POLLING recv(50) RECEIVES A MULTI-FRAME REQUEST whose Consecutive Frames arrive after
// the poll that saw its First Frame ended (#467): the transfer is kept for the next poll.
fn test_a_transfer_survives_the_poll_that_saw_its_first_frame() {
	mut peer := transport.open('inproc:isotp-poll') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-poll', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 14, 1, 2, 3, 4, 5, 6] }) or {}
	if _ := ch.recv(50) {
		assert false, 'only the First Frame has arrived'
	} else {
		assert err.msg() == stall_note, err.msg()
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x21), 7, 8, 9, 10, 11, 12, 13] }) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x22), 14] }) or {}
	pdu := ch.recv(500) or {
		assert false, 'the next poll did not complete the request: ${err}'
		return
	}
	assert pdu == []u8{len: 14, init: u8(index + 1)}
	ch.close()
	peer.close()
}

// A TRANSFER THE CHANNEL WAITED N_Cr FOR IS GIVEN UP: a Consecutive Frame arriving after that
// is a stale tail, dropped, and the next message is read as itself.
fn test_a_kept_transfer_is_dropped_after_n_cr_of_waiting() {
	mut peer := transport.open('inproc:isotp-ncr') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-ncr', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	ch.cr_window_ms = 100
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 14, 1, 2, 3, 4, 5, 6] }) or {}
	if _ := ch.recv(400) {
		assert false, 'only the First Frame has arrived'
	} else {
		// given up after N_Cr of waiting: a reception that began and failed, never silence
		assert err.msg() == ncr_note, err.msg()
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x21), 7, 8, 9, 10, 11, 12, 13] }) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x01), 0xBB] }) or {}
	next := ch.recv(500) or {
		assert false, 'the message after a given-up transfer was lost: ${err}'
		return
	}
	assert next == [u8(0xBB)]
	ch.close()
	peer.close()
}

// N_Cr IS PER CONSECUTIVE FRAME: each gap is under it, so a transfer whose gaps together exceed
// it is still received.
fn test_n_cr_restarts_at_every_consecutive_frame() {
	mut peer := transport.open('inproc:isotp-ncr-gaps') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-ncr-gaps', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	ch.cr_window_ms = 200
	spawn fn [mut peer] () {
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 27, 1, 2, 3, 4, 5, 6] }) or {}
		for sn in 1 .. 4 {
			time.sleep(150 * time.millisecond) // under N_Cr each, 450 ms in all
			peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x20 | sn), 0, 0, 0, 0, 0, 0, 0] }) or {}
		}
	}()
	// polled as a server polls, so each gap is spent in receives that time out
	mut pdu := []u8{}
	for _ in 0 .. 40 {
		pdu = ch.recv(50) or { continue }
		break
	}
	assert pdu.len == 27, 'gaps each under N_Cr ended the transfer'
	ch.close()
	peer.close()
}

// FRAMES THAT ARRIVED WHILE NOBODY WAS READING ARE ON TIME: only time a recv spends blocked
// counts towards N_Cr, so a caller that reads again later than N_Cr still completes a transfer
// whose frames came promptly.
fn test_frames_queued_between_receives_complete_the_transfer() {
	mut peer := transport.open('inproc:isotp-queued') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-queued', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	ch.cr_window_ms = 100
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 14, 1, 2, 3, 4, 5, 6] }) or {}
	ch.recv(20) or { assert err.msg() == stall_note, err.msg() }
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x21), 7, 8, 9, 10, 11, 12, 13] }) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x22), 14] }) or {}
	time.sleep(300 * time.millisecond) // three N_Cr windows, nobody reading
	pdu := ch.recv(500) or {
		assert false, 'frames queued while nobody read were dropped: ${err}'
		return
	}
	assert pdu == []u8{len: 14, init: u8(index + 1)}
	ch.close()
	peer.close()
}

// A SINGLE FRAME IN PLACE OF THE NEXT CONSECUTIVE FRAME, WITHIN ONE RECEIVE, is the next message
// too (ISO 15765-2): the same rule wherever the deadline fell.
fn test_a_single_frame_mid_transfer_is_the_next_message() {
	mut peer := transport.open('inproc:isotp-sf-mid') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-sf-mid', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 14, 1, 2, 3, 4, 5, 6] }) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x02), 0xCC, 0xDD] }) or {}
	next := ch.recv(500) or {
		assert false, 'a Single Frame mid-transfer was refused: ${err}'
		return
	}
	assert next == [u8(0xCC), 0xDD]
	ch.close()
	peer.close()
}

// A DRAIN READS A KEPT TRANSFER'S FRAMES AWAY, so it drops the transfer: what arrives after is
// judged with none in progress.
fn test_a_drain_drops_a_kept_transfer() {
	mut peer := transport.open('inproc:isotp-drain-kept') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-drain-kept', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 20, 1, 2, 3, 4, 5, 6] }) or {}
	ch.recv(20) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x21), 7, 8, 9, 10, 11, 12, 13] }) or {}
	ch.drain_quiet(30)
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x22), 14, 15, 16, 17, 18, 19, 20] }) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x01), 0xEE] }) or {}
	next := ch.recv(500) or {
		assert false, 'the reply after a drain was lost: ${err}'
		return
	}
	assert next == [u8(0xEE)]
	ch.close()
	peer.close()
}

// ORPHAN FLOW CONTROLS DO NOT KEEP A TRANSFER ALIVE: the time a wait spent before one counts
// towards N_Cr, so a transfer whose Consecutive Frames stopped is given up even though frames
// keep arriving.
fn test_orphan_flow_controls_do_not_extend_n_cr() {
	mut peer := transport.open('inproc:isotp-fc-ncr') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-fc-ncr', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	ch.cr_window_ms = 100
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 14, 1, 2, 3, 4, 5, 6] }) or {}
	spawn fn [mut peer] () {
		for _ in 0 .. 20 {
			time.sleep(20 * time.millisecond)
			peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or {}
		}
	}()
	t0 := time.ticks()
	if _ := ch.recv(1000) {
		assert false, 'no Consecutive Frame was sent'
	} else {
		assert err.msg() == ncr_note, err.msg()
	}
	assert time.ticks() - t0 < 600, 'orphan Flow Controls kept the transfer alive'
	ch.close()
	peer.close()
}

// A SEND REFUSED BEFORE ANYTHING WENT OUT keeps a transfer in progress: it moved on from nothing.
fn test_a_refused_send_keeps_a_kept_transfer() {
	mut peer := transport.open('inproc:isotp-refused-send') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-refused-send', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 8, 1, 2, 3, 4, 5, 6] }) or {}
	ch.recv(20) or {}
	ch.send([]u8{}) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x21), 7, 8] }) or {}
	pdu := ch.recv(500) or {
		assert false, 'a refused send dropped the transfer: ${err}'
		return
	}
	assert pdu == []u8{len: 8, init: u8(index + 1)}
	ch.close()
	peer.close()
}

// abandon_reception DROPS A KEPT TRANSFER: a caller that discards what is queued (the uds drain
// before a request) must not have its next answer completed from an older transfer's frames.
fn test_abandon_reception_drops_a_kept_transfer() {
	mut peer := transport.open('inproc:isotp-abandon') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-abandon', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 8, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA] }) or {}
	ch.recv(0) or {}
	ch.abandon_reception()
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x21), 0xAA, 0xAA] }) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x02), 0x62, 0xBB] }) or {}
	next := ch.recv(500) or {
		assert false, 'the fresh answer was lost: ${err}'
		return
	}
	assert next == [u8(0x62), 0xBB]
	ch.close()
	peer.close()
}

// AN ORPHAN FLOW CONTROL is left over from one of our own sends: it says nothing about the
// peer's transfer, so the kept transfer goes on past it.
fn test_an_orphan_flow_control_keeps_a_kept_transfer() {
	mut peer := transport.open('inproc:isotp-orphan-keep') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-orphan-keep', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 8, 1, 2, 3, 4, 5, 6] }) or {}
	ch.recv(50) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x21), 7, 8] }) or {}
	pdu := ch.recv(500) or {
		assert false, 'an orphan Flow Control ended the kept transfer: ${err}'
		return
	}
	assert pdu == []u8{len: 8, init: u8(index + 1)}
	ch.close()
	peer.close()
}

// A SINGLE FRAME IN PLACE OF THE NEXT CONSECUTIVE FRAME means the peer moved on: the kept
// transfer is dropped and the Single Frame is the message.
fn test_a_new_message_replaces_a_kept_transfer() {
	mut peer := transport.open('inproc:isotp-moved-on') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-moved-on', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 14, 1, 2, 3, 4, 5, 6] }) or {}
	ch.recv(50) or {}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x02), 0xCC, 0xDD] }) or {}
	next := ch.recv(500) or {
		assert false, 'a new message after an abandoned one was refused: ${err}'
		return
	}
	assert next == [u8(0xCC), 0xDD]
	ch.close()
	peer.close()
}

// recv(-1) BLOCKS UNTIL A FRAME, on the software channel as on the kernel one (codex round 5 on
// #225: computed as a deadline, -1 was a deadline in the past).
fn test_a_negative_timeout_blocks_until_a_frame_arrives() {
	mut peer := transport.open('inproc:isotp-forever') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-forever', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	spawn fn [mut peer] () {
		time.sleep(150 * time.millisecond)
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x01), 0x5A] }) or {}
	}()
	t0 := time.ticks()
	got := ch.recv(-1) or {
		assert false, 'recv(-1) must wait for the frame, not time out: ${err}'
		return
	}
	assert got == [u8(0x5A)]
	assert time.ticks() - t0 >= 100, 'recv(-1) returned before the frame was sent'
	ch.close()
	peer.close()
}

// recv(0) IS ONE LOOK: a reply already queued is returned, nothing waits (codex round 7 on #225).
fn test_a_zero_timeout_returns_a_queued_reply() {
	mut peer := transport.open('inproc:isotp-poll') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-poll', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	if _ := ch.recv(0) {
		assert false, 'nothing was sent'
	} else {
		assert err.msg() == 'timeout'
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x01), 0x33] }) or { assert false, err.msg() }
	time.sleep(20 * time.millisecond)
	got := ch.recv(0) or {
		assert false, 'a queued reply must be returned by a zero-timeout poll: ${err}'
		return
	}
	assert got == [u8(0x33)]
	ch.close()
	peer.close()
}

// A FIRST FRAME DECLARING A SINGLE-FRAME LENGTH IS MALFORMED (codex round 7 on #225).
fn test_a_first_frame_with_a_single_frame_length_is_refused() {
	mut peer := transport.open('inproc:isotp-short-ff') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-short-ff', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 3, 1, 2, 3, 0, 0, 0] }) or {
		assert false, err.msg()
	}
	if _ := ch.recv(300) {
		assert false, 'a 3-byte First Frame must be refused'
	} else {
		assert err.msg().contains('must be a Single Frame'), err.msg()
	}
	ch.close()
	peer.close()
}

// A STALE CONSECUTIVE FRAME AHEAD OF FLOW CONTROL IS SKIPPED: the tail of an abandoned transfer
// must not be taken for the peer's answer to the next request (codex round 11 on #225).
fn test_a_stale_cf_ahead_of_flow_control_is_skipped() {
	mut peer := transport.open('inproc:isotp-stale-fc') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-stale-fc', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	// The abandoned transfer's tail, already queued on our rx id.
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x22), 0, 0, 0, 0, 0, 0, 0] }) or {
		assert false, err.msg()
	}
	time.sleep(20 * time.millisecond)
	// the Flow Control follows a sleep, on the test's schedule
	ch.fc_window_ms = test_fc_window_ms
	mut s := start_send(mut ch, 20)
	time.sleep(80 * time.millisecond) // the FF is out; the stale CF was the first thing queued
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or { assert false, err.msg() }
	msg := s.wait()
	assert msg == 'sent', msg
	ch.close()
	peer.close()
}

// recv(0) LOOKS PAST FRAMES FOR OTHER IDS: a shared bus queues them ahead of the reply, and a
// non-blocking poll must still find it (codex round 12 on #225).
fn test_a_zero_timeout_looks_past_unrelated_frames() {
	mut peer := transport.open('inproc:isotp-poll-mixed') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-poll-mixed', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x123, data: [u8(1)] }) or { assert false, err.msg() }
	peer.send(transport.CanFrame{ id: 0x124, data: [u8(2)] }) or { assert false, err.msg() }
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x01), 0x44] }) or { assert false, err.msg() }
	time.sleep(20 * time.millisecond)
	got := ch.recv(0) or {
		assert false, 'the poll stopped at an unrelated frame: ${err}'
		return
	}
	assert got == [u8(0x44)]
	ch.close()
	peer.close()
}

// recv(0) LOOKS PAST A STALE CONSECUTIVE FRAME TOO, to the reply queued behind it (codex round 13
// on #225).
fn test_a_zero_timeout_looks_past_a_stale_cf() {
	mut peer := transport.open('inproc:isotp-poll-stale') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-poll-stale', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x23), 0, 0, 0, 0, 0, 0, 0] }) or {
		assert false, err.msg()
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x01), 0x55] }) or { assert false, err.msg() }
	time.sleep(20 * time.millisecond)
	got := ch.recv(0) or {
		assert false, 'the poll stopped at a stale CF: ${err}'
		return
	}
	assert got == [u8(0x55)]
	ch.close()
	peer.close()
}

// A SINGLE FRAME ABOVE SEVEN BYTES AND A FIRST FRAME BELOW EIGHT ARE BOTH MALFORMED (codex round
// 14 on #225).
fn test_malformed_single_and_first_frames_are_refused() {
	mut peer := transport.open('inproc:isotp-malformed') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-malformed', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x09), 1, 2, 3, 4, 5, 6, 7, 8, 9], fd: true }) or {
		assert false, err.msg()
	}
	time.sleep(20 * time.millisecond)
	if _ := ch.recv(100) {
		assert false, 'an SF_DL of 9 must be refused'
	} else {
		assert err.msg().contains('exceeds 7'), err.msg()
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 20, 1, 2] }) or { assert false, err.msg() }
	time.sleep(20 * time.millisecond)
	if _ := ch.recv(100) {
		assert false, 'a four-byte First Frame must be refused'
	} else {
		assert err.msg().contains('too short'), err.msg()
	}
	// And an FD-sized one is not a classic First Frame either (codex round 18 on #225).
	peer.send(transport.CanFrame{ id: 0x7E8, data: []u8{len: 12, init: u8(0x10)}, fd: true }) or {
		assert false, err.msg()
	}
	time.sleep(20 * time.millisecond)
	if _ := ch.recv(100) {
		assert false, 'a twelve-byte First Frame must be refused'
	} else {
		assert err.msg().contains('too short'), err.msg()
	}
	// And a frame of the other id WIDTH is not ours at all: an extended 0x7E8 on a standard
	// channel is ignored, not taken for the reply (codex round 18 on #225).
	peer.send(transport.CanFrame{ id: 0x7E8, extended: true, data: [u8(0x01), 0x77] }) or {
		assert false, err.msg()
	}
	time.sleep(20 * time.millisecond)
	if _ := ch.recv(50) {
		assert false, 'an extended frame must not match a standard channel'
	} else {
		assert err.msg() == 'timeout', err.msg()
	}
	// (A remote request on our id is not data either — codex round 19 on #225 — but this app
	// transmits no remote frames (#210), so the in-process bus refuses to inject one and the
	// filter is pinned by review rather than by a test here.)
	ch.close()
	peer.close()
}

// A SHORT CONSECUTIVE FRAME WITH MORE OF THE PDU TO COME IS MALFORMED (codex round 16 on #225).
fn test_a_short_non_final_consecutive_frame_is_refused() {
	mut peer := transport.open('inproc:isotp-short-cf') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-short-cf', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 20, 1, 2, 3, 4, 5, 6] }) or {
		assert false, err.msg()
	}
	time.sleep(20 * time.millisecond)
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x21), 7, 8, 9] }) or { assert false, err.msg() }
	if _ := ch.recv(300) {
		assert false, 'a three-byte CF with 11 bytes still to come must be refused'
	} else {
		assert err.msg().contains('short Consecutive Frame'), err.msg()
	}
	ch.close()
	peer.close()
}

// IDS THAT DO NOT FIT THEIR DECLARED WIDTH ARE REFUSED AT open() (codex round 17 on #225).
fn test_open_refuses_an_id_wider_than_declared() {
	$if !linux {
		if _ := open('inproc:isotp-wide', 0x800, 0x7E8, false) {
			assert false, '0x800 does not fit 11 bits'
		} else {
			assert err.msg().contains('does not fit 11 bits'), err.msg()
		}
	}
	// And the named opener, on every platform (codex round 20 on #225).
	if _ := open_software('inproc:isotp-wide', 0x7E0, 0x2000_0000, true) {
		assert false, '0x20000000 does not fit 29 bits'
	} else {
		assert err.msg().contains('does not fit 29 bits'), err.msg()
	}
}

// AN OVERSIZED CONSECUTIVE FRAME IS NOT ONE OF OURS on a classic channel (codex round 17 on #225).
fn test_an_oversized_consecutive_frame_is_refused() {
	mut peer := transport.open('inproc:isotp-fat-cf') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-fat-cf', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 20, 1, 2, 3, 4, 5, 6] }) or {
		assert false, err.msg()
	}
	time.sleep(20 * time.millisecond)
	peer.send(transport.CanFrame{ id: 0x7E8, data: []u8{len: 16, init: u8(0x21)}, fd: true }) or {
		assert false, err.msg()
	}
	if _ := ch.recv(300) {
		assert false, 'a 16-byte CF must be refused on a classic channel'
	} else {
		assert err.msg().contains('classic channel'), err.msg()
	}
	ch.close()
	peer.close()
}

// A STREAM OF STALE CONSECUTIVE FRAMES ON OUR OWN ID does not keep a zero-timeout poll scanning
// past its budget (codex round 17 on #225).
fn test_a_zero_timeout_poll_is_bounded_across_stale_cfs() {
	mut peer := transport.open('inproc:isotp-stale-stream') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-stale-stream', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	for i in 0 .. 5000 {
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x20 | u8(i & 0x0F)), 0, 0, 0, 0, 0, 0, 0] }) or {}
	}
	time.sleep(50 * time.millisecond)
	t0 := time.ticks()
	if _ := ch.recv(0) {
		assert false, 'nothing but stale CFs was queued'
	} else {
		assert err.msg() == 'timeout', err.msg()
	}
	assert time.ticks() - t0 < 2000, 'recv(0) scanned for ${time.ticks() - t0} ms'
	ch.close()
	peer.close()
}

// A FRAME THE SENDER OWES IS WAITED FOR UNTIL IT ARRIVES OR THE SEND ENDS, never against a clock.
// A wall-clock budget on a hand-off between two threads is failed by a correct implementation
// whenever either thread is descheduled past it, which on a loaded runner happens: the block-size
// test lost a frame at a 500 ms budget, then twice at 5 s on the Windows job (#448), where the
// sender's Flow Control window was already 10 s and the test could not say what the send was
// doing. What does end, and says why, is the send itself: every send these tests wait on is
// bounded by its Flow Control window or its stop, so `must_read_tx` reads until the frame comes
// or the send returns, and its clock is a hang-breaker for a send that neither sends nor ends.
//
// A read that must produce NOTHING is the opposite. A stall there makes it pass when it should
// have failed, so its budget stays SHORT: late is the safe direction, and a long one only costs
// suite time while hiding bugs.
//
// Neither helper takes a timeout from its call site, which is what stops the two being confused
// again -- the name says which promise is being tested.
const tx_hang_ms = 60_000 // hang-breaker for a send that neither sends nor ends
const tx_slice_ms = 50 // how often a wait for a frame asks whether the send has ended
const tx_silence_ms = 250 // how long "nothing may be sent" is actually observed

// The bound on how soon a requested stop ends a send: well under the Flow Control window below,
// so a send the stop did not end fails the test rather than being ended by the window.
const stop_seen_ms = 5000

// The per-block Flow Control window for a channel whose peer answers ON THE TEST'S SCHEDULE --
// after a silence check, a sleep or a stop. At the 1 s default a stalled test thread reads as a
// peer that missed N_BS and the send ends `timeout` before the step under test; this is far past
// any stall, and short enough that a send nothing ends still fails within the suite.
const test_fc_window_ms = 10_000

// Sender is a send running on its own thread, and what it returned once it has.
struct Sender {
	done chan string
mut:
	ended bool
	msg   string
}

// start_send sends a `len`-byte PDU on `ch` from a thread of its own.
fn start_send(mut ch SoftChannel, len int) &Sender {
	done := chan string{cap: 1}
	spawn fn [mut ch, done, len] () {
		ch.send([]u8{len: len, init: u8(index)}) or {
			done <- err.msg()
			return
		}
		done <- 'sent'
	}()
	return &Sender{
		done: done
	}
}

// outcome is what the send returned, if it has returned; it never waits.
fn (mut s Sender) outcome() ?string {
	if !s.ended {
		select {
			msg := <-s.done {
				s.ended = true
				s.msg = msg
			}
			else {}
		}
	}
	return if s.ended { s.msg } else { none }
}

// wait is what the send returned, once it has -- or, past `tx_hang_ms`, that it has not, which
// no assertion on the outcome accepts.
fn (mut s Sender) wait() string {
	if !s.ended {
		select {
			msg := <-s.done {
				s.ended = true
				s.msg = msg
			}
			i64(tx_hang_ms) * time.millisecond {
				return 'the send was still running after ${tx_hang_ms} ms'
			}
		}
	}
	return s.msg
}

// must_read_tx: the send is required to put this on the wire. It fails only if the send ended
// without it -- saying what the send returned -- or neither sent nor ended within `tx_hang_ms`.
fn must_read_tx(mut peer transport.Bus, mut s Sender, tx_id u32) !transport.CanFrame {
	deadline := time.ticks() + tx_hang_ms
	for {
		if f := read_tx(mut peer, tx_id, tx_slice_ms) {
			return f
		}
		if msg := s.outcome() {
			// whatever the send put on the wire was queued before it returned
			if f := read_tx(mut peer, tx_id, 0) {
				return f
			}
			return error('the send ended without it: ${msg} (${peer.diagnostics().dropped} dropped)')
		}
		if time.ticks() >= deadline {
			return error('the send neither sent it nor ended in ${tx_hang_ms} ms (${peer.diagnostics().dropped} dropped)')
		}
	}
	return error('unreachable')
}

// no_read_tx: nothing may be sent. A frame coming back IS the failure.
fn no_read_tx(mut peer transport.Bus, tx_id u32) ?transport.CanFrame {
	return read_tx(mut peer, tx_id, tx_silence_ms)
}

// read_tx returns the next frame the channel under test put on its tx id within `timeout_ms`,
// skipping the peer's own traffic (the in-process bus delivers to every subscriber, this test's
// injections included). It LOOKS before it judges the deadline, so a frame queued while this
// thread was descheduled past it is returned, and a zero timeout is one look.
fn read_tx(mut peer transport.Bus, tx_id u32, timeout_ms int) ?transport.CanFrame {
	deadline := time.ticks() + i64(timeout_ms)
	for {
		rem := deadline - time.ticks()
		f := peer.recv(int(if rem > 0 { rem } else { i64(0) })) or { return none }
		if f.id == tx_id {
			return f
		}
	}
	return none
}

// BLOCK SIZE IS AN INSTRUCTION, NOT A HINT (#226). BS=2 means two Consecutive Frames and then
// silence until the next Flow Control; the old sender read the PCI nibble and pushed the whole
// remainder, which a paced bootloader answers by dropping the transfer.
fn test_block_size_stops_the_sender_until_the_next_flow_control() {
	mut peer := transport.open('inproc:isotp-bs') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-bs', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	// the second Flow Control follows a silence check, on the test's schedule
	ch.fc_window_ms = test_fc_window_ms
	// 34 bytes = 6 in the First Frame + four Consecutive Frames of 7.
	mut s := start_send(mut ch, 34)
	ff := must_read_tx(mut peer, mut s, 0x7E0) or {
		assert false, 'no First Frame: ${err}'
		return
	}
	assert (ff.data[0] & 0xF0) == 0x10, 'expected a First Frame'

	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 2, 0] }) or { assert false, err.msg() }
	for i in 0 .. 2 {
		cf := must_read_tx(mut peer, mut s, 0x7E0) or {
			assert false, 'Consecutive Frame ${i + 1} of the first block did not arrive: ${err}'
			return
		}
		assert (cf.data[0] & 0xF0) == 0x20
	}
	// THE BLOCK IS FULL. Nothing more may go out until another Flow Control does.
	if extra := no_read_tx(mut peer, 0x7E0) {
		assert false, 'sent past the block size: 0x${extra.data[0]:02X}'
	}

	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or { assert false, err.msg() }
	for i in 0 .. 2 {
		cf := must_read_tx(mut peer, mut s, 0x7E0) or {
			assert false, 'Consecutive Frame ${i + 3} did not arrive after the second Flow Control: ${err}'
			return
		}
		assert (cf.data[0] & 0xF0) == 0x20
	}
	msg := s.wait()
	assert msg == 'sent', msg
	ch.close()
	peer.close()
}

// WAIT re-arms the wait and the transfer then completes. A receiver that is not ready says so;
// read as CTS — which masking the nibble did — the sender transmits into a peer that just told
// it not to.
fn test_a_wait_is_honoured_and_the_transfer_resumes() {
	mut peer := transport.open('inproc:isotp-wait') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-wait', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	// the CTS follows a silence check, on the test's schedule
	ch.fc_window_ms = test_fc_window_ms
	mut s := start_send(mut ch, 20)
	must_read_tx(mut peer, mut s, 0x7E0) or {
		assert false, 'no First Frame: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x31), 0, 0] }) or { assert false, err.msg() }
	// Still waiting: a WAIT is not a licence to send.
	if extra := no_read_tx(mut peer, 0x7E0) {
		assert false, 'sent on a WAIT: 0x${extra.data[0]:02X}'
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or { assert false, err.msg() }
	msg := s.wait()
	assert msg == 'sent', msg
	ch.close()
	peer.close()
}

// OVERFLOW is the receiver saying the PDU will not fit. It is a refusal, not a timeout, and the
// caller wants to know which: retrying the same transfer gets the same answer.
fn test_an_overflow_aborts_the_transfer_with_the_reason() {
	mut peer := transport.open('inproc:isotp-ovflw') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-ovflw', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	// the OVERFLOW follows the First Frame, on the test's schedule
	ch.fc_window_ms = test_fc_window_ms
	mut s := start_send(mut ch, 20)
	must_read_tx(mut peer, mut s, 0x7E0) or {
		assert false, 'no First Frame: ${err}'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x32), 0, 0] }) or { assert false, err.msg() }
	msg := s.wait()
	assert msg.contains('overflow'), msg
	// and nothing went out after it
	if extra := no_read_tx(mut peer, 0x7E0) {
		assert false, 'sent after an OVERFLOW: 0x${extra.data[0]:02X}'
	}
	ch.close()
	peer.close()
}

// A PEER THAT ONLY EVER WAITS NEVER TRIPS A TIMEOUT, because a frame keeps arriving — which is
// exactly why N_WFTmax exists. Without the count `send` blocks for as long as the ECU stalls it.
fn test_endless_waits_are_given_up_on() {
	mut peer := transport.open('inproc:isotp-wft') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-wft', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	// QUEUED BEFORE THE SENDER CAN READ THEM, deliberately. The sender needs all n_wft_max + 1
	// of these to reach the count, and each read is bounded by fc_timeout_ms; waiting for the
	// First Frame and only then sending them made the test depend on seventeen SEQUENTIAL reads
	// completing inside a one-second window each. On a CI runner compiling V in parallel a
	// thread can stall past a second, and the send then failed with `timeout` instead of the
	// abort this asserts — which is what it did on the Windows job while passing 30/30 locally.
	//
	// Ordering does not matter to the sender: rx_raw filters to its rx id, so its own First
	// Frame is not in this queue, and the frames simply wait until it looks. Every read is then
	// immediate and nothing is timed.
	for _ in 0 .. n_wft_max + 1 {
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x31), 0, 0] }) or {
			assert false, err.msg()
		}
	}
	// every answer is already queued, so the send runs on this thread
	if _ := ch.send([]u8{len: 20, init: u8(index)}) {
		assert false, 'the send completed on WAITs alone'
	} else {
		assert err.msg().contains('N_WFTmax'), err.msg()
	}
	ch.close()
	peer.close()
}

// CfStamps is a channel's bus with the send time of every Consecutive Frame recorded, so a
// pacing test measures the gaps the sender left rather than when a reader thread happened to run.
// The clock is sys_mono_now: `ticks()` on Windows moves in 15.6 ms steps, too coarse for a 10 ms
// margin.
struct CfStamps {
mut:
	inner transport.Bus
	at    []u64
}

fn (mut b CfStamps) send(f transport.CanFrame) ! {
	if f.data.len > 0 && (f.data[0] & 0xF0) == 0x20 {
		b.at << time.sys_mono_now()
	}
	b.inner.send(f)!
}

fn (mut b CfStamps) recv(timeout_ms int) !transport.CanFrame {
	return b.inner.recv(timeout_ms)
}

fn (mut b CfStamps) close() {
	b.inner.close()
}

fn (mut b CfStamps) health() transport.BusHealth {
	return b.inner.health()
}

fn (mut b CfStamps) diagnostics() transport.BusDiagnostics {
	return b.inner.diagnostics()
}

fn (mut b CfStamps) reconcile_silence(want bool) ! {
	b.inner.reconcile_silence(want)!
}

// cf_span_ms sends a 27-byte PDU (a First Frame and three Consecutive Frames) with `fcs` already
// queued as the receiver's Flow Controls, and returns the time from the first Consecutive Frame
// to the last. Queued up front, the sender takes one per block and never waits on another thread.
fn cf_span_ms(iface string, fcs [][]u8) !f64 {
	mut peer := transport.open(iface)!
	defer {
		peer.close()
	}
	mut ch := open_software(iface, 0x7E0, 0x7E8, false)!
	defer {
		ch.close()
	}
	mut stamps := &CfStamps{
		inner: ch.bus
	}
	ch.bus = stamps
	for fc in fcs {
		peer.send(transport.CanFrame{ id: 0x7E8, data: fc })!
	}
	ch.send([]u8{len: 27, init: u8(index)})!
	if stamps.at.len != 3 {
		return error('${stamps.at.len} Consecutive Frames sent, expected 3')
	}
	return f64(stamps.at[2] - stamps.at[0]) / 1e6
}

// STmin PACES THE CONSECUTIVE FRAMES. Measured rather than asserted structurally, because the
// only thing that makes a bootloader accept the block is the SEPARATION on the wire.
fn test_stmin_separates_consecutive_frames() {
	// one block (BS 0) at STmin 30 ms: two separations between three frames, bound 50 ms
	span := cf_span_ms('inproc:isotp-stmin', [[u8(0x30), 0, 30]]) or {
		assert false, err.msg()
		return
	}
	assert span >= 50, 'three Consecutive Frames at STmin 30 ms spanned ${span:.1f} ms — not paced'
}

// STmin DOES NOT LAPSE AT A BLOCK BOUNDARY. With BS=1 every Consecutive Frame is the first of
// its block, so a sender that pays the separation only "between frames within a block" pays it
// never. ISO 15765-2 exempts nothing at a block boundary.
fn test_stmin_holds_across_block_boundaries() {
	// one frame per block (BS 1) at STmin 30 ms, one Flow Control per block
	fc := [u8(0x30), 1, 30]
	span := cf_span_ms('inproc:isotp-stmin-bs', [fc, fc, fc]) or {
		assert false, err.msg()
		return
	}
	assert span >= 50, 'three single-frame blocks at STmin 30 ms spanned ${span:.1f} ms — the separation lapsed at the boundary'
}

// AN ORPHAN FLOW CONTROL IS NOT A MESSAGE. The aborts this change added (N_WFTmax, OVERFLOW) end
// a send with the peer's later Flow Control frames still queued, and this side never expects one
// — it SENDS flow control as a receiver. Read as a message it surfaced as `unexpected PCI 0x31`
// in place of the next reply: a desync that could not happen before, because the old send took
// the first 0x3x it saw and there was never a second to strand (codex on #226).
// #296: skipping an orphan Flow Control is right, but it turned a diagnosable peer into a bare
// `timeout` — the one answer that says nothing about what is on the wire.
fn test_a_timeout_behind_orphan_flow_control_says_so() {
	mut peer := transport.open('inproc:isotp-orphan-says') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-orphan-says', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	// a peer that keeps answering a transfer that ended, and nothing else
	for _ in 0 .. 3 {
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x31), 0, 0] }) or {
			assert false, err.msg()
		}
	}
	if _ := ch.recv(300) {
		assert false, 'a channel carrying only orphan Flow Control cannot produce a message'
	} else {
		assert err.msg().contains('orphan flow control'), err.msg()
		assert err.msg().contains('0x31'), err.msg()
	}
	// and a quiet channel still times out plainly: the diagnostic is about what was SEEN
	mut quiet := open_software('inproc:isotp-orphan-quiet', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	if _ := quiet.recv(100) {
		assert false, 'nothing was sent'
	} else {
		assert err.msg() == 'timeout', err.msg()
	}
	quiet.close()
	ch.close()
	peer.close()
}

fn test_a_leftover_flow_control_does_not_desync_the_next_receive() {
	mut peer := transport.open('inproc:isotp-orphan-fc') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-orphan-fc', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	// the WAITs follow the First Frame, on the test's schedule
	ch.fc_window_ms = test_fc_window_ms
	mut s := start_send(mut ch, 20)
	must_read_tx(mut peer, mut s, 0x7E0) or {
		assert false, 'no First Frame: ${err}'
		return
	}
	// Enough WAITs to abort, and two more behind them that nothing will consume.
	for _ in 0 .. n_wft_max + 3 {
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x31), 0, 0] }) or {
			assert false, err.msg()
		}
	}
	msg := s.wait()
	assert msg.contains('N_WFTmax'), msg

	// The channel is reused, as a persistent UDS or script connection is. The next reply must be
	// the reply, not whatever the aborted send left behind.
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x02), 0x50, 0x01, 0, 0, 0, 0, 0] }) or {
		assert false, err.msg()
	}
	reply := ch.recv(800) or {
		assert false, 'the next reply was lost behind an orphan Flow Control: ${err}'
		return
	}
	assert reply == [u8(0x50), 0x01], '${reply}'
	ch.close()
	peer.close()
}

// A SEND THAT ABORTED LEAVES FLOW CONTROL BEHIND, AND THE USUAL NEXT MOVE IS ANOTHER SEND. The
// recv() skip does not cover that path: a leftover WAIT would spend the retry's budget, and a
// leftover CTS would authorise Consecutive Frames before the receiver had accepted anything
// (codex on #226).
fn test_a_retry_after_an_aborted_send_does_not_read_the_old_flow_control() {
	mut peer := transport.open('inproc:isotp-retry') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-retry', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	// the retry's CTS follows a silence check, on the test's schedule
	ch.fc_window_ms = test_fc_window_ms
	mut first := start_send(mut ch, 20)
	must_read_tx(mut peer, mut first, 0x7E0) or {
		assert false, 'no First Frame: ${err}'
		return
	}
	// ABORTED WITH ONE FRAME. What this test is about is the RETRY, not how the first send
	// ended — and OVERFLOW ends it on a single Flow Control, where n_wft_max + 1 WAITs made it
	// depend on seventeen sequential reads each bounded by fc_timeout_ms. That is what flaked on
	// the Windows job (the abort came back as `timeout`), and it was testing the wrong thing
	// here anyway: the wait count has its own test.
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x32), 0, 0] }) or { assert false, err.msg() }
	// The message is carried into the assertion deliberately: when this failed on the Windows
	// job it printed only the expression, so what the send ACTUALLY returned — the one fact that
	// would have identified the cause — was not in the log. Every assert here that reads a
	// worker's result names it now.
	aborted := first.wait()
	assert aborted.contains('overflow'), aborted
	// THE STALE CTS ARRIVES LATE — after the retry has begun, which is the case a snapshot drain
	// cannot see: the peer was mid-burst when N_WFTmax gave up, so the last of it is still in
	// flight. The first cut read what was already queued and went straight on, and the test
	// written for it slept here before retrying, which avoided the race instead of covering it
	// (codex on #226). The quiet window is what absorbs this.
	spawn fn [mut peer] () {
		time.sleep(8 * time.millisecond)
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or {}
	}()

	// THE RETRY. The stranded CTS must not authorise anything: this transfer has had no answer.
	mut second := start_send(mut ch, 20)
	ff := must_read_tx(mut peer, mut second, 0x7E0) or {
		assert false, 'the retry sent no First Frame: ${err}'
		return
	}
	assert (ff.data[0] & 0xF0) == 0x10, 'expected the retry First Frame'
	if extra := no_read_tx(mut peer, 0x7E0) {
		assert false, 'the retry sent 0x${extra.data[0]:02X} on the PREVIOUS transfer\'s Flow Control'
	}
	// and it completes normally once THIS transfer is answered
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or { assert false, err.msg() }
	msg := second.wait()
	assert msg == 'sent', msg
	ch.close()
	peer.close()
}

// THE TRANSFER'S TOTAL ALLOWANCE (#296 item 1). The per-block bounds multiply by the number of
// blocks and nothing bounded the product: at BS=1 a maximum PDU is 585 blocks, so a peer using
// every WAIT it is allowed holds one send for about two and a half hours.
fn test_the_wait_budget_clamps_a_read_and_reports_its_own_bound() {
	mut b := new_wait_budget_ms(100)
	// the caller's own window wins while it is the shorter of the two
	assert b.window_ms(50) == 50
	// and the allowance wins when it is not
	assert b.window_ms(500) == 100
	b.spend_ns(60 * 1_000_000)
	assert b.window_ms(500) == 40
	assert !b.spent()
	b.spend_ns(40 * 1_000_000)
	assert b.spent()
	assert b.window_ms(500) == 0, 'a spent allowance permits no read at all'
	// the note names the total bound, not the per-block one, or the reader goes to the wrong
	// constant for the reason a transfer ended
	assert exhausted_note(100).contains('fc_total_wait_ms')
	assert exhausted_note(100).contains('100 ms')
}

// A REMAINDER UNDER A MILLISECOND IS STILL TIME LEFT. Truncating it to 0 would report the
// allowance as spent while it is not, and `window_ms` returning 0 is how the caller is told to
// give up -- so the two must not be confused.
fn test_a_sub_millisecond_remainder_is_not_a_spent_budget() {
	mut b := new_wait_budget_ms(1)
	b.spend_ns(900 * 1_000) // 900 us of a 1000 us allowance
	assert !b.spent()
	assert b.window_ms(500) == 1, 'the smallest read that means anything'
}

// A BOUND THAT REFUNDS IS NOT A BOUND. A clock reading backwards is not this clock's contract,
// but crediting the difference would hand a stalling peer its time back.
fn test_a_backwards_clock_reading_spends_nothing() {
	mut b := new_wait_budget_ms(100)
	b.spend_ns(-5 * 1_000_000)
	assert b.window_ms(500) == 100
}

// ZERO IS THE SMALLEST ALLOWANCE, NOT AN ABSENT ONE: a channel whose field a struct literal
// left at zero must not silently get the unbounded behaviour this closes.
fn test_a_zero_allowance_is_not_an_unbounded_one() {
	b := new_wait_budget_ms(0)
	assert b.spent()
	assert b.window_ms(1000) == 0
	neg := new_wait_budget_ms(-1)
	assert neg.spent()
}

// END TO END, AND GENUINELY ACROSS BLOCKS. The per-block count resets on every Flow Control,
// so a peer that stays under it forever is fine by every per-block rule while the transfer it
// belongs to runs for hours. That is the shape this allowance exists for.
//
// The first draft never reached a second block: the peer only ever sent WAIT, so no Consecutive
// Frame was ever authorised and every WAIT landed in the FIRST `await_flow_control` call --
// testing the per-call path under another name, and making the N_WFTmax assertion vacuous
// (self-review). Here each block gets ONE wait and then a real CTS, so the count is 1 where the
// bound is 16, the blocks actually advance, and what runs out is the total.
fn test_waits_spread_across_blocks_exhaust_the_transfer_allowance() {
	mut peer := transport.open('inproc:isotp-budget') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-budget', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	ch.total_wait_ms = 150
	// THE FIRST BLOCK IS ANSWERED BEFORE THE SEND BEGINS -- its WAIT and its CTS queued, so the
	// sender reads them without blocking and spends none of the allowance on them. Answered as
	// the send went, a runner that stalled this thread past 150 ms spent the whole allowance
	// before the first block and the test read "never advanced a block" -- the precondition
	// failing, not the bound under test. Every later block is paid for in real time, where a
	// stall only spends the allowance sooner; normally three of them spend it, so an allowance
	// that restarted per block would see the send complete.
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x31), 0, 0] }) or { assert false, err.msg() }
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 1, 0] }) or { assert false, err.msg() }
	// 62 bytes = 6 + eight Consecutive Frames, so at BS=1 there are eight blocks to spread over
	mut s := start_send(mut ch, 62)
	must_read_tx(mut peer, mut s, 0x7E0) or {
		assert false, 'no First Frame: ${err}'
		return
	}
	must_read_tx(mut peer, mut s, 0x7E0) or {
		assert false, 'the first block, answered up front, sent no Consecutive Frame: ${err}'
		return
	}
	// AND THE PEER'S OWN QUEUE IS DRAINED, by reading the Consecutive Frame each block. The
	// in-process bus delivers a sender its own frames too, so a peer that only sends fills its
	// own queue, `try_push` starts refusing, and the stall under test stops being fed -- the
	// sender then dies on the per-block timeout and the test reads a plausible wrong answer.
	for _ in 1 .. 8 {
		if _ := s.outcome() {
			break
		}
		// one WAIT, paid for in real time, then the CTS that ends the block
		time.sleep(30 * time.millisecond)
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x31), 0, 0] }) or {
			assert false, 'the peer could not send: ${err}'
			break
		}
		time.sleep(30 * time.millisecond)
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 1, 0] }) or {
			assert false, 'the peer could not send: ${err}'
			break
		}
		must_read_tx(mut peer, mut s, 0x7E0) or {
			// the send ending here, on the allowance, is the outcome under test
			if _ := s.outcome() {
				break
			}
			assert false, err.msg()
			return
		}
	}
	msg := s.wait()
	assert msg.contains('fc_total_wait_ms'), msg
	assert !msg.contains('N_WFTmax'), 'one wait per block must not trip the per-block count: ${msg}'
	ch.close()
	peer.close()
}

// AND THE ALLOWANCE IS NOT SPENT BY OUR OWN PACING, which is the whole reason it counts waiting
// rather than elapsed time: STmin is the receiver's to ask for, and 585 frames at the slowest
// legal separation is 74 seconds that ISO entitles it to. A transfer paced well past its own
// allowance must still complete.
//
// EVERY FLOW CONTROL IS QUEUED UP FRONT, so no read here blocks and none is charged -- the only
// elapsed time is our own sleeping. The first draft had the peer answer as it went, which
// charged the harness's own scheduling to the allowance and could fail on a loaded runner with
// the exhaustion message instead of `sent` (self-review). The margin is 200 ms of pacing
// against a 100 ms allowance, so the assertion is about which of the two is counted, not about
// how fast the machine is.
fn test_stmin_pacing_does_not_spend_the_transfer_allowance() {
	mut peer := transport.open('inproc:isotp-budget-pace') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-budget-pace', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	ch.total_wait_ms = 100
	// three Flow Controls for three blocks, all waiting before the sender looks
	for _ in 0 .. 3 {
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 1, 100] }) or {
			assert false, err.msg()
		}
	}
	// 27 bytes = 6 + three Consecutive Frames, so STmin is paid twice: 200 ms of pacing
	// every Flow Control is already queued, so the send runs on this thread
	ch.send([]u8{len: 27, init: u8(index)}) or { assert false, err.msg() }
	ch.close()
	peer.close()
}

// abandon_after sends a 20-byte PDU on a stoppable channel whose stop is requested `stop_ms`
// after the First Frame is seen, while `peer_fc` (when not empty) is sent every 10 ms. Returns
// the send's error and how long after the stop request the send took to end.
//
// The Flow Control window is `test_fc_window_ms`, so nothing but the stop can end the wait, and
// a wait the stop did not cut short takes that long; how soon a stop is seen is `stop_slice`'s,
// tested without a clock below.
fn abandon_after(iface string, peer_fc []u8, stop_ms int) !(string, i64) {
	mut peer := transport.open(iface)!
	defer {
		peer.close()
	}
	mut ch := open_software(iface, 0x7E0, 0x7E8, false)!
	defer {
		ch.close()
	}
	ch.fc_window_ms = test_fc_window_ms
	stop := chan bool{}
	ch.stop_requested = fn [stop] () bool {
		return stop.closed
	}
	mut s := start_send(mut ch, 20)
	must_read_tx(mut peer, mut s, 0x7E0) or { return error('no First Frame: ${err}') }
	t_stop := time.ticks() + stop_ms
	for time.ticks() < t_stop {
		if peer_fc.len > 0 {
			peer.send(transport.CanFrame{ id: 0x7E8, data: peer_fc })!
		}
		time.sleep(10 * time.millisecond)
	}
	t0 := time.ticks()
	stop.close()
	msg := s.wait()
	return msg, time.ticks() - t0
}

// A RUN WORKER TOLD TO STOP LEAVES ITS SEND (#347): a peer that never answers the First Frame
// would hold it for fc_timeout_ms, and the total allowance for minutes.
fn test_a_stop_abandons_the_wait_for_a_silent_peer() {
	msg, took := abandon_after('inproc:isotp-stop-silent', [], 50) or {
		assert false, err.msg()
		return
	}
	assert msg == abandoned_note, msg
	assert took < stop_seen_ms, 'abandoned ${took} ms after the stop request'
}

// ...and a peer that only ever WAITs, which keeps a frame arriving so no timeout ever fires.
fn test_a_stop_abandons_a_peer_that_only_waits() {
	msg, took := abandon_after('inproc:isotp-stop-wait', [u8(0x31), 0, 0], 60) or {
		assert false, err.msg()
		return
	}
	assert msg == abandoned_note, msg
	assert took < stop_seen_ms, 'abandoned ${took} ms after the stop request'
}

// ...and our own STmin pacing, which at 127 ms a frame is the receiver's to ask for. The stop
// answers true from its third ask once the first Consecutive Frame is on the wire: a pacing
// sliced at `stop_poll_ms` asks seven times across 127 ms, so that ask is inside it; a pacing
// slept whole asks at most once, and the second Consecutive Frame goes out before the third.
fn test_a_stop_abandons_stmin_pacing() {
	mut peer := transport.open('inproc:isotp-stop-pace') or { panic(err) }
	mut ch := open_software('inproc:isotp-stop-pace', 0x7E0, 0x7E8, false) or { panic(err) }
	mut w := &CfWatch{
		bus: transport.open('inproc:isotp-stop-pace') or { panic(err) }
	}
	ch.stop_requested = fn [mut w] () bool {
		return w.ask()
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0x7F] }) or { panic(err) }
	// 20 bytes: two Consecutive Frames, so one 127 ms separation
	if _ := ch.send([]u8{len: 20, init: u8(index)}) {
		assert false, 'the transfer completed: the pacing was not asked to stop'
	} else {
		assert err.msg() == abandoned_note, err.msg()
	}
	mut cfs := 0
	for {
		f := peer.recv(0) or { break }
		if f.id == 0x7E0 && f.data.len > 0 && f.data[0] >> 4 == 2 {
			cfs++
		}
	}
	assert cfs == 1, '${cfs} Consecutive Frames went out; the stop came during the pacing after the first'
	w.bus.close()
	ch.close()
	peer.close()
}

// CfWatch is a stop request that answers true from its third ask after it has seen a
// Consecutive Frame on the wire.
struct CfWatch {
mut:
	bus   transport.Bus
	asked int // asks since the first Consecutive Frame was seen
}

fn (mut w CfWatch) ask() bool {
	for w.asked == 0 {
		f := w.bus.recv(0) or { return false }
		if f.id == 0x7E0 && f.data.len > 0 && f.data[0] >> 4 == 2 {
			break
		}
	}
	w.asked++
	return w.asked >= 3
}

// A stop is seen within `stop_poll_ms` of being requested: a stoppable channel waits in slices
// no longer than that, and a channel nobody can stop waits the whole time asked.
fn test_a_stoppable_wait_is_sliced_at_the_poll_interval() {
	mut ch := open_software('inproc:isotp-stop-slice', 0x7E0, 0x7E8, false) or { panic(err) }
	assert ch.stop_slice(fc_timeout_ms) == fc_timeout_ms
	ch.stop_requested = fn () bool {
		return false
	}
	assert ch.stop_slice(fc_timeout_ms) == stop_poll_ms
	assert ch.stop_slice(stop_poll_ms / 2) == stop_poll_ms / 2
	ch.close()
}

// A CHANNEL NOBODY CAN STOP IS NOT SLICED INTO A DIFFERENT ANSWER: unset, the hook changes
// nothing, and a stoppable channel whose stop never comes completes like any other.
fn test_a_stoppable_send_that_is_not_stopped_completes() {
	mut peer := transport.open('inproc:isotp-stop-none') or { panic(err) }
	mut ch := open_software('inproc:isotp-stop-none', 0x7E0, 0x7E8, false) or { panic(err) }
	// the Flow Control follows a sleep, on the test's schedule
	ch.fc_window_ms = test_fc_window_ms
	stop := chan bool{}
	ch.stop_requested = fn [stop] () bool {
		return stop.closed
	}
	mut s := start_send(mut ch, 20)
	must_read_tx(mut peer, mut s, 0x7E0) or { panic('no First Frame: ${err}') }
	// answered after several stop slices have gone by, at an STmin longer than one
	time.sleep(70 * time.millisecond)
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 45] }) or { panic(err) }
	msg := s.wait()
	assert msg == 'sent', msg
	ch.close()
	peer.close()
}

struct StopCount {
mut:
	asked int
}

// ...and an UNPACED block (BS=0, STmin=0), which waits on nothing between its frames: the stop
// is asked per Consecutive Frame, so the send leaves mid-block rather than writing them all.
fn test_a_stop_abandons_an_unpaced_block() {
	mut peer := transport.open('inproc:isotp-stop-unpaced') or { panic(err) }
	mut ch := open_software('inproc:isotp-stop-unpaced', 0x7E0, 0x7E8, false) or { panic(err) }
	mut n := &StopCount{}
	// asked before the First Frame and while the Flow Control is awaited; true from the third
	ch.stop_requested = fn [mut n] () bool {
		n.asked++
		return n.asked >= 3
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or { panic(err) }
	ch.send([]u8{len: 40, init: u8(index)}) or { assert err.msg() == abandoned_note, err.msg() }
	mut cfs := 0
	for {
		f := peer.recv(20) or { break }
		if f.id == 0x7E0 && f.data.len > 0 && f.data[0] >> 4 == 2 {
			cfs++
		}
	}
	assert cfs < 5, 'all ${cfs} Consecutive Frames written after the stop'
	ch.close()
	peer.close()
}

// ...and the drain of a channel an earlier aborted send left dirty, which a peer that keeps
// sending holds open one quiet window at a time.
//
// The frames are queued before the send, so they hold the quiet window open whatever the
// threads' timing, and the stop answers true from the 20th ask, about twenty frames in.
fn test_a_stop_abandons_the_dirty_channel_drain() {
	mut peer := transport.open('inproc:isotp-stop-drain') or { panic(err) }
	mut ch := open_software('inproc:isotp-stop-drain', 0x7E0, 0x7E8, false) or { panic(err) }
	backlog := 100
	for _ in 0 .. backlog {
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or { panic(err) }
	}
	mut n := &StopCount{}
	ch.stop_requested = fn [mut n] () bool {
		n.asked++
		return n.asked >= 20
	}
	ch.fc_dirty = true
	if _ := ch.send([]u8{len: 20, init: u8(index)}) {
		assert false, 'the send completed: the drain was not asked to stop'
	} else {
		assert err.msg() == abandoned_note, err.msg()
	}
	assert ch.fc_dirty, 'a drain cut short left the channel marked clean'
	// the drain was left partway through the backlog, not read to its end
	mut left := 0
	for {
		ch.bus.recv(0) or { break }
		left++
	}
	assert left > 0 && left < backlog, '${left} of ${backlog} frames left queued'
	if f := peer.recv(0) {
		assert false, 'a frame went out after the stop: ${f.data}'
	}
	ch.close()
	peer.close()
}

// ...and a stop that arrives while the drain waits out its final quiet window: the drain's read
// sees it, and no First Frame may follow it onto the bus.
fn test_a_stop_during_the_final_quiet_window_sends_no_first_frame() {
	mut peer := transport.open('inproc:isotp-stop-quiet') or { panic(err) }
	mut ch := open_software('inproc:isotp-stop-quiet', 0x7E0, 0x7E8, false) or { panic(err) }
	// the stop arrives 10 ms into the drain's 30 ms quiet window
	at := time.ticks() + 10
	ch.stop_requested = fn [at] () bool {
		return time.ticks() >= at
	}
	ch.fc_dirty = true
	ch.send([]u8{len: 20, init: u8(index)}) or { assert err.msg() == abandoned_note, err.msg() }
	if f := peer.recv(50) {
		assert false, 'a frame went out after the stop: ${f.data}'
	}
	ch.close()
	peer.close()
}

// ...and a stop already requested when a segmented send begins on a clean channel: the
// transfer is not begun, so no First Frame goes out for a Flow Control nobody will read.
fn test_a_stop_before_the_first_frame_sends_nothing() {
	mut peer := transport.open('inproc:isotp-stop-first') or { panic(err) }
	mut ch := open_software('inproc:isotp-stop-first', 0x7E0, 0x7E8, false) or { panic(err) }
	ch.stop_requested = fn () bool {
		return true
	}
	if _ := ch.send([]u8{len: 20, init: u8(index)}) {
		assert false, 'a stopped send completed'
	} else {
		assert err.msg() == abandoned_note, err.msg()
	}
	if f := peer.recv(0) {
		assert false, 'a frame went out after the stop: ${f.data}'
	}
	ch.close()
	peer.close()
}

// a stoppable channel's receive ends when the stop is requested, not at its deadline
fn test_a_stop_ends_a_blocked_receive() {
	mut ch := open_software('inproc:isotp-stop-recv', 0x7E0, 0x7E8, false) or { panic(err) }
	at := time.ticks() + 50
	ch.stop_requested = fn [at] () bool {
		return time.ticks() >= at
	}
	// the note is the stop's; the deadline would have said `timeout`
	if _ := ch.recv(5000) {
		assert false, 'nothing was sent'
	} else {
		assert err.msg().starts_with(abandoned_recv_note), err.msg()
	}
	ch.close()
}

// with no stop requested, a stoppable channel still receives, and still times out on time
fn test_a_stoppable_receive_still_receives_and_times_out() {
	mut peer := transport.open('inproc:isotp-stop-recv2') or { panic(err) }
	mut ch := open_software('inproc:isotp-stop-recv2', 0x7E0, 0x7E8, false) or { panic(err) }
	ch.stop_requested = fn () bool {
		return false
	}
	spawn fn [mut peer] () {
		time.sleep(60 * time.millisecond)
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x02), 0x50, 0x03, 0, 0, 0, 0, 0] }) or {}
	}()
	got := ch.recv(2000) or { panic(err) }
	assert got == [u8(0x50), 0x03]
	t0 := time.ticks()
	if _ := ch.recv(120) {
		assert false, 'nothing more was sent'
	} else {
		assert err.msg().starts_with('timeout'), err.msg()
	}
	assert time.ticks() - t0 >= 100
	ch.close()
	peer.close()
}

// RecvCount is a channel's bus with its receive calls counted: how many times a wait went round,
// which is what a spin is, measured without a clock.
struct RecvCount {
mut:
	inner transport.Bus
	calls int
	// answer every receive with 'timeout' at once, as a bus with no queue to wait on would
	instant bool
}

fn (mut b RecvCount) send(f transport.CanFrame) ! {
	b.inner.send(f)!
}

fn (mut b RecvCount) recv(timeout_ms int) !transport.CanFrame {
	b.calls++
	if b.instant {
		return error('timeout')
	}
	return b.inner.recv(timeout_ms)
}

fn (mut b RecvCount) close() {
	b.inner.close()
}

fn (mut b RecvCount) health() transport.BusHealth {
	return b.inner.health()
}

fn (mut b RecvCount) diagnostics() transport.BusDiagnostics {
	return b.inner.diagnostics()
}

fn (mut b RecvCount) reconcile_silence(want bool) ! {
	b.inner.reconcile_silence(want)!
}

// A CLOSED BUS ENDS A STOPPABLE RECEIVE (#401): the inproc queue closed under its reader answers
// a select at once, which the stop-sliced wait read as a quiet slice and asked again, as fast as
// it could, until the deadline (or for ever, for a blocking read). Now the closed bus is an error
// on the first call.
fn test_a_closed_bus_ends_a_stoppable_recv() {
	mut ch := open_software('inproc:isotp-closed-recv', 0x7E0, 0x7E8, false) or { panic(err) }
	mut counted := &RecvCount{
		inner: ch.bus
	}
	ch.bus = counted
	ch.stop_requested = fn () bool {
		return false
	}
	counted.inner.close()
	if _ := ch.recv(500) {
		assert false, 'a closed bus delivered a message'
	} else {
		assert err.msg().contains('closed'), err.msg()
	}
	assert counted.calls == 1, 'the receive asked a closed bus ${counted.calls} times'
	// the blocking form too: it would otherwise never return
	counted.calls = 0
	ch.recv(-1) or { assert err.msg().contains('closed'), err.msg() }
	assert counted.calls == 1, 'a blocking receive asked a closed bus ${counted.calls} times'
}

// ...and a bus that answers 'timeout' WITHOUT waiting is waited out by the slice: one call per
// stop_poll_ms, not one per instant.
fn test_an_instant_timeout_does_not_spin_a_stoppable_recv() {
	mut ch := open_software('inproc:isotp-instant-recv', 0x7E0, 0x7E8, false) or { panic(err) }
	mut counted := &RecvCount{
		inner:   ch.bus
		instant: true
	}
	ch.bus = counted
	ch.stop_requested = fn () bool {
		return false
	}
	ch.recv(200) or { assert err.msg() == 'timeout', err.msg() }
	// 200 ms in 20 ms slices: ten calls, and a little slack for a short last slice
	assert counted.calls <= 200 / stop_poll_ms + 2, '${counted.calls} receive calls in 200 ms'
	ch.close()
}

// drain_idle reads what is queued and returns at once; a closed bus is an error.
fn test_drain_idle_reads_what_is_queued() {
	mut peer := transport.open('inproc:isotp-drain-idle') or { panic(err) }
	mut ch := open_software('inproc:isotp-drain-idle', 0x7E0, 0x7E8, false) or { panic(err) }
	for _ in 0 .. 5 {
		peer.send(transport.CanFrame{ id: 0x123, data: [u8(1)] }) or { panic(err) }
	}
	assert ch.drain_idle(3) or { panic(err) } == 3
	assert ch.drain_idle(100) or { panic(err) } == 2
	assert ch.drain_idle(100) or { panic(err) } == 0
	ch.close()
	if _ := ch.drain_idle(100) {
		assert false, 'a closed bus drained cleanly'
	}
	peer.close()
}
