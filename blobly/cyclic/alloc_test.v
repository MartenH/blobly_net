module cyclic

import time
import blobly.candb
import blobly.transport

// alloc_test.v — what a wire's loop ALLOCATES per frame it sends, in bytes (the method of
// blobly/wiretap/bench_test.v): its pass, its wait for the next due and the send itself. A
// `select` per wait allocated its case arrays on every pass, a sender's frame was copied per
// send, and a declared E2E's windows were built per frame (#689). Only the wire's loop runs while
// it is measured.

// bytes_per_frame is what `s`'s wire allocates per frame it sends, over 400 ms.
fn bytes_per_frame(mut s Sender) f64 {
	time.sleep(100 * time.millisecond)
	sent0 := s.info().sent
	before := u64(gc_heap_usage().total_bytes)
	time.sleep(400 * time.millisecond)
	after := u64(gc_heap_usage().total_bytes)
	sent := s.info().sent - sent0
	assert sent > 50, 'a 1 ms sender sent ${sent} frames in 400 ms'
	return f64(after - before) / f64(sent)
}

fn test_a_wire_loop_sends_without_garbage() {
	$if !gcboehm ? {
		println('wire loop cost: skipped, no Boehm allocation counter in this build')
		return
	}
	mut s := start(transport.open('inproc:CYCALLOC')!, Spec{
		id:        0x123
		data:      [u8(1), 2, 3, 4, 5, 6, 7, 8]
		period_ms: 1
	}, Life{})!
	defer {
		s.stop()
	}
	per := bytes_per_frame(mut s)
	println('wire loop cost: ${per:.0f} bytes allocated per frame')
	assert per < 64, 'a wire loop allocates ${per:.0f} bytes per frame it sends'
}

// a message whose E2E is declared: a payload per frame, its counter and checksum stamped on it
fn test_an_e2e_sender_allocates_its_payload_per_frame() {
	$if !gcboehm ? {
		println('e2e sender cost: skipped, no Boehm allocation counter in this build')
		return
	}
	db := candb.parse_dbc('VERSION ""
BU_: A
BO_ 256 M: 8 A
 SG_ Speed : 0|16@1+ (0.5,0) [0|1000] "km/h" A
 SG_ Ctr : 16|4@1+ (1,0) [0|15] "" A
 SG_ Crc : 24|8@1+ (1,0) [0|255] "" A
BA_DEF_ BO_ "E2ECounterSignal" STRING ;
BA_DEF_ BO_ "E2ECrcSignal" STRING ;
BA_DEF_ BO_ "E2EProfile" STRING ;
BA_DEF_ BO_ "E2EDataId" INT 0 65535;
BA_ "E2ECounterSignal" BO_ 256 "Ctr";
BA_ "E2ECrcSignal" BO_ 256 "Crc";
BA_ "E2EProfile" BO_ 256 "P01";
BA_ "E2EDataId" BO_ 256 66;
')!
	m := db.message_named('M') or { panic('no M') }
	mut s := start(transport.open('inproc:CYCALLOCE')!, Spec{
		by_message: true
		message:    m
		values:     {
			'Speed': 50.0
		}
		period_ms:  1
	}, Life{})!
	defer {
		s.stop()
	}
	per := bytes_per_frame(mut s)
	println('e2e sender cost: ${per:.0f} bytes allocated per frame')
	assert per < 256, 'an E2E sender allocates ${per:.0f} bytes per frame it sends'
}
