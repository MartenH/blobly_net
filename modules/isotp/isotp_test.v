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
	assert took < 600, 'recv(300) took ${took} ms: the deadline was renewed per frame'
	time.sleep(700 * time.millisecond) // let the peer finish before the bus goes
	ch.close()
	peer.close()
}
