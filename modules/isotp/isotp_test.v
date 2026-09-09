module isotp

import transport
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
	done := chan string{cap: 1}
	spawn fn [mut ch, done] () {
		ch.send([]u8{len: 20, init: u8(index)}) or {
			done <- err.msg()
			return
		}
		done <- 'sent'
	}()
	time.sleep(50 * time.millisecond)
	peer.send(transport.CanFrame{ id: 0x7E8 }) or { assert false, err.msg() }
	msg := <-done
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
		assert err.msg() == 'timeout', err.msg()
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
	time.sleep(700 * time.millisecond) // the peer finishes its abandoned transfer meanwhile
	// AND THE CHANNEL IS REUSABLE: the abandoned transfer's late CFs must not be taken for the
	// start of the next reply (codex round 4 on #225).
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x01), 0xAA] }) or { assert false, err.msg() }
	next := ch.recv(500) or {
		assert false, 'the next reply was lost behind the abandoned transfer: ${err}'
		return
	}
	assert next == [u8(0xAA)]
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
	done := chan string{cap: 1}
	spawn fn [mut ch, done] () {
		ch.send([]u8{len: 20, init: u8(index)}) or {
			done <- err.msg()
			return
		}
		done <- 'sent'
	}()
	time.sleep(80 * time.millisecond) // the FF is out; the stale CF was the first thing queued
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or { assert false, err.msg() }
	msg := <-done
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

// read_tx returns the next frame the channel under test put on its tx id, skipping the peer's
// own traffic (the in-process bus delivers to every subscriber, this test's injections included).
// THE DEADLINE ON A READ IS NOT A MEASUREMENT, and which kind of read it is decides its budget.
//
// A read that MUST produce a frame can only be failed by its deadline if the implementation was
// CORRECT and something else was slow -- so that budget is a hang-breaker and nothing more, and
// it is generous. A runner compiling V in parallel stalls a thread for hundreds of milliseconds
// routinely, which is what took `test_block_size_stops_the_sender_until_the_next_flow_control`
// down on `main` at a 500 ms budget: "Consecutive Frame 4 did not arrive". #291 removed the same
// class of fragility from two sibling tests (and could not reproduce the flake either); this was
// the third instance, so the budget stops being a per-call-site guess.
//
// A read that must produce NOTHING is the opposite. A stall there makes it pass when it should
// have failed, so its budget stays SHORT: late is the safe direction, and a long one only costs
// suite time while hiding bugs.
//
// Neither helper takes a timeout from its call site, which is what stops the two being confused
// again -- the name says which promise is being tested.
const tx_arrive_ms = 5000 // hang-breaker for a frame the implementation owes us
const tx_silence_ms = 250 // how long "nothing may be sent" is actually observed

// must_read_tx: the implementation is required to send this. Returns none only if it never did.
fn must_read_tx(mut peer transport.Bus, tx_id u32) ?transport.CanFrame {
	return read_tx(mut peer, tx_id, tx_arrive_ms)
}

// no_read_tx: nothing may be sent. A frame coming back IS the failure.
fn no_read_tx(mut peer transport.Bus, tx_id u32) ?transport.CanFrame {
	return read_tx(mut peer, tx_id, tx_silence_ms)
}

fn read_tx(mut peer transport.Bus, tx_id u32, timeout_ms int) ?transport.CanFrame {
	deadline := time.ticks() + i64(timeout_ms)
	for {
		rem := int(deadline - time.ticks())
		if rem <= 0 {
			return none
		}
		f := peer.recv(rem) or { return none }
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
	done := chan string{cap: 1}
	// 34 bytes = 6 in the First Frame + four Consecutive Frames of 7.
	spawn fn [mut ch, done] () {
		ch.send([]u8{len: 34, init: u8(index)}) or {
			done <- err.msg()
			return
		}
		done <- 'sent'
	}()
	ff := must_read_tx(mut peer, 0x7E0) or {
		assert false, 'no First Frame'
		return
	}
	assert (ff.data[0] & 0xF0) == 0x10, 'expected a First Frame'

	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 2, 0] }) or { assert false, err.msg() }
	for i in 0 .. 2 {
		cf := must_read_tx(mut peer, 0x7E0) or {
			assert false, 'Consecutive Frame ${i + 1} of the first block did not arrive'
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
		cf := must_read_tx(mut peer, 0x7E0) or {
			assert false, 'Consecutive Frame ${i + 3} did not arrive after the second Flow Control'
			return
		}
		assert (cf.data[0] & 0xF0) == 0x20
	}
	msg := <-done
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
	done := chan string{cap: 1}
	spawn fn [mut ch, done] () {
		ch.send([]u8{len: 20, init: u8(index)}) or {
			done <- err.msg()
			return
		}
		done <- 'sent'
	}()
	must_read_tx(mut peer, 0x7E0) or {
		assert false, 'no First Frame'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x31), 0, 0] }) or { assert false, err.msg() }
	// Still waiting: a WAIT is not a licence to send.
	if extra := no_read_tx(mut peer, 0x7E0) {
		assert false, 'sent on a WAIT: 0x${extra.data[0]:02X}'
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or { assert false, err.msg() }
	msg := <-done
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
	done := chan string{cap: 1}
	spawn fn [mut ch, done] () {
		ch.send([]u8{len: 20, init: u8(index)}) or {
			done <- err.msg()
			return
		}
		done <- 'sent'
	}()
	must_read_tx(mut peer, 0x7E0) or {
		assert false, 'no First Frame'
		return
	}
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x32), 0, 0] }) or { assert false, err.msg() }
	msg := <-done
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
	done := chan string{cap: 1}
	spawn fn [mut ch, done] () {
		ch.send([]u8{len: 20, init: u8(index)}) or {
			done <- err.msg()
			return
		}
		done <- 'sent'
	}()
	msg := <-done
	assert msg.contains('N_WFTmax'), msg
	ch.close()
	peer.close()
}

// STmin PACES THE CONSECUTIVE FRAMES. Measured rather than asserted structurally, because the
// only thing that makes a bootloader accept the block is the SEPARATION on the wire.
fn test_stmin_separates_consecutive_frames() {
	mut peer := transport.open('inproc:isotp-stmin') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-stmin', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	done := chan string{cap: 1}
	// 27 bytes = 6 + three Consecutive Frames, so STmin is paid twice.
	spawn fn [mut ch, done] () {
		ch.send([]u8{len: 27, init: u8(index)}) or {
			done <- err.msg()
			return
		}
		done <- 'sent'
	}()
	must_read_tx(mut peer, 0x7E0) or {
		assert false, 'no First Frame'
		return
	}
	t0 := time.ticks()
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 30] }) or { assert false, err.msg() }
	msg := <-done
	elapsed := time.ticks() - t0
	assert msg == 'sent', msg
	// two separations of 30 ms; a lower bound only, since a sleep may overshoot and the bus adds
	// its own time
	assert elapsed >= 50, 'three Consecutive Frames at STmin 30 ms took ${elapsed} ms — not paced'
	ch.close()
	peer.close()
}

// STmin DOES NOT LAPSE AT A BLOCK BOUNDARY. With BS=1 every Consecutive Frame is the first of
// its block, so a sender that pays the separation only "between frames within a block" pays it
// never — a receiver asking for 30 ms gets frames as fast as it can answer. The first cut did
// exactly that, on the reasoning that the Flow Control opening a block is itself the separation;
// ISO 15765-2 exempts nothing there, and the argument was never measured (codex on #226).
fn test_stmin_holds_across_block_boundaries() {
	mut peer := transport.open('inproc:isotp-stmin-bs') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-stmin-bs', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	done := chan string{cap: 1}
	// 27 bytes = 6 + three Consecutive Frames, so two separations are owed.
	spawn fn [mut ch, done] () {
		ch.send([]u8{len: 27, init: u8(index)}) or {
			done <- err.msg()
			return
		}
		done <- 'sent'
	}()
	must_read_tx(mut peer, 0x7E0) or {
		assert false, 'no First Frame'
		return
	}
	t0 := time.ticks()
	// ONE frame per block, so the sender must ask again for each — and must still pace.
	for _ in 0 .. 3 {
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 1, 30] }) or {
			assert false, err.msg()
		}
		must_read_tx(mut peer, 0x7E0) or {
			assert false, 'a Consecutive Frame did not arrive'
			return
		}
	}
	msg := <-done
	elapsed := time.ticks() - t0
	assert msg == 'sent', msg
	assert elapsed >= 50, 'three single-frame blocks at STmin 30 ms took ${elapsed} ms — the separation lapsed at the boundary'
	ch.close()
	peer.close()
}

// AN ORPHAN FLOW CONTROL IS NOT A MESSAGE. The aborts this change added (N_WFTmax, OVERFLOW) end
// a send with the peer's later Flow Control frames still queued, and this side never expects one
// — it SENDS flow control as a receiver. Read as a message it surfaced as `unexpected PCI 0x31`
// in place of the next reply: a desync that could not happen before, because the old send took
// the first 0x3x it saw and there was never a second to strand (codex on #226).
fn test_a_leftover_flow_control_does_not_desync_the_next_receive() {
	mut peer := transport.open('inproc:isotp-orphan-fc') or {
		assert false, 'in-process bus: ${err}'
		return
	}
	mut ch := open_software('inproc:isotp-orphan-fc', 0x7E0, 0x7E8, false) or {
		assert false, 'software channel: ${err}'
		return
	}
	done := chan string{cap: 1}
	spawn fn [mut ch, done] () {
		ch.send([]u8{len: 20, init: u8(index)}) or {
			done <- err.msg()
			return
		}
		done <- 'sent'
	}()
	must_read_tx(mut peer, 0x7E0) or {
		assert false, 'no First Frame'
		return
	}
	// Enough WAITs to abort, and two more behind them that nothing will consume.
	for _ in 0 .. n_wft_max + 3 {
		peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x31), 0, 0] }) or {
			assert false, err.msg()
		}
	}
	msg := <-done
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
	first := chan string{cap: 1}
	spawn fn [mut ch, first] () {
		ch.send([]u8{len: 20, init: u8(index)}) or {
			first <- err.msg()
			return
		}
		first <- 'sent'
	}()
	must_read_tx(mut peer, 0x7E0) or {
		assert false, 'no First Frame'
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
	aborted := <-first
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
	second := chan string{cap: 1}
	spawn fn [mut ch, second] () {
		ch.send([]u8{len: 20, init: u8(index)}) or {
			second <- err.msg()
			return
		}
		second <- 'sent'
	}()
	ff := must_read_tx(mut peer, 0x7E0) or {
		assert false, 'the retry sent no First Frame'
		return
	}
	assert (ff.data[0] & 0xF0) == 0x10, 'expected the retry First Frame'
	if extra := no_read_tx(mut peer, 0x7E0) {
		assert false, 'the retry sent 0x${extra.data[0]:02X} on the PREVIOUS transfer\'s Flow Control'
	}
	// and it completes normally once THIS transfer is answered
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] }) or { assert false, err.msg() }
	msg := <-second
	assert msg == 'sent', msg
	ch.close()
	peer.close()
}
