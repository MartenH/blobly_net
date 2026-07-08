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
// trace-dump desync. Inject a wrong-SN CF and assert recv() errors here, at the source.
fn test_cf_sequence_gap_is_a_clean_error() {
	mut rx := open_software('inproc:ISOTPSN', 0x100, 0x200, false) or { panic(err) }
	mut raw := transport.open('inproc:ISOTPSN') or { panic(err) }
	mut r := &SnRecv{
		ch: rx
	}

	// First Frame: total 14 bytes, first 6 of payload. The receiver will reply with Flow Control
	// (on 0x100) and then wait for CF sequence number 1.
	raw.send(transport.CanFrame{ id: 0x200, data: [u8(0x10), 14, 1, 2, 3, 4, 5, 6] }) or { panic(err) }
	spawn r.run()
	time.sleep(40 * time.millisecond) // let recv() read the FF, send FC, and wait for a CF

	// Send a CF with the WRONG sequence number (SN 2, expected 1) — a dropped-frame gap.
	raw.send(transport.CanFrame{ id: 0x200, data: [u8(0x22), 7, 8, 9, 10, 11, 12, 13] }) or { panic(err) }
	time.sleep(80 * time.millisecond) // let recv() read the bad CF and error out

	assert !r.ok, 'recv() should have failed on the sequence gap, not returned data'
	assert r.err_msg.contains('sequence') || r.err_msg.contains('CF'), 'unexpected error: ${r.err_msg}'
	rx.close()
	raw.close()
}
