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
