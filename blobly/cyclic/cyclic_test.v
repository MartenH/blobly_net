module cyclic

import time
import blobly.candb
import blobly.transport

// frames_within is what `rx` hears of id `id` for `ms`.
fn frames_within(mut rx transport.Bus, id u32, ms int) []transport.CanFrame {
	until := time.ticks() + ms
	mut out := []transport.CanFrame{}
	for time.ticks() < until {
		f := rx.recv(10) or { continue }
		if f.id == id {
			out << f
		}
	}
	return out
}

fn test_a_raw_sender_is_heard_at_its_period_and_takes_an_update() {
	mut rx := transport.open('inproc:CYC1')!
	defer {
		rx.close()
	}
	mut s := start(transport.open('inproc:CYC1')!, Spec{
		id:        0x123
		data:      [u8(1), 2]
		period_ms: 20
	}, Life{})!
	got := frames_within(mut rx, 0x123, 210)
	// a first frame at once, then one per 20 ms, never a burst: about 11 in 210 ms
	assert got.len >= 5 && got.len <= 12, '${got.len} frames'
	assert got[0].data == [u8(1), 2]
	s.set_data([u8(9)])!
	time.sleep(60 * time.millisecond)
	for {
		rx.recv(0) or { break } // what went out before the update
	}
	later := frames_within(mut rx, 0x123, 60)
	assert later.len > 0 && later.all(it.data == [u8(9)])
	assert s.stop()
	i := s.info()
	assert !i.running && i.sent >= 6 && i.failed == 0
	// stopped: nothing more
	assert frames_within(mut rx, 0x123, 60).len == 0
}

fn test_a_period_change_applies_from_the_next_frame() {
	mut rx := transport.open('inproc:CYC2')!
	defer {
		rx.close()
	}
	mut s := start(transport.open('inproc:CYC2')!, Spec{
		id:        0x10
		period_ms: 1000
	}, Life{})!
	assert frames_within(mut rx, 0x10, 100).len == 1 // the first, at once
	s.set_period(10)!
	n := frames_within(mut rx, 0x10, 200).len
	assert n >= 5, '${n} frames at 10 ms'
	assert s.stop()
}

fn test_a_message_sender_encodes_its_values_and_stamps_its_e2e() {
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
	assert m.e2e.declared()
	mut rx := transport.open('inproc:CYC3')!
	defer {
		rx.close()
	}
	mut s := start(transport.open('inproc:CYC3')!, Spec{
		by_message: true
		message:    m
		values:     {
			'Speed': 50.0
		}
		period_ms:  10
	}, Life{})!
	got := frames_within(mut rx, 0x100, 80)
	assert got.len >= 3
	speed := m.signal_named('Speed') or { panic('') }
	ctr := m.signal_named('Ctr') or { panic('') }
	assert got.all(speed.physical(it.data) == 50.0)
	// its counter moves frame by frame, from 0
	assert ctr.physical(got[0].data) == 0 && ctr.physical(got[1].data) == 1
	s.set_values({
		'Speed': 12.5
	})!
	time.sleep(30 * time.millisecond)
	for {
		rx.recv(0) or { break }
	}
	assert frames_within(mut rx, 0x100, 40).all(speed.physical(it.data) == 12.5)
	s.set_values({
		'Nope': 1.0
	}) or { assert err.msg().contains('unknown signal "Nope"') }
	s.set_data([u8(1)]) or { assert err.msg().contains('takes signal values') }
	assert s.stop()
	// stopped, it takes no change
	s.set_period(999) or { assert err.msg() == stopped_note }
	assert s.info().period_ms == 10
}

fn test_a_spec_no_sender_could_send_is_refused() {
	for sp in [Spec{
		period_ms: 0
	}, Spec{
		period_ms: max_period_ms + 1
	}, Spec{
		period_ms: 10
		data:      []u8{len: 65}
	}, Spec{
		period_ms: 10
		data:      []u8{len: 9}
		format:    .classic
	}, Spec{
		period_ms: 10
		id:        0x800 // past an 11-bit id
	}, Spec{
		period_ms: 10
		id:        0x2000_0000 // past a 29-bit id
		ext:       true
	}] {
		start(transport.open('inproc:CYC4')!, sp, Life{}) or { continue }
		assert false, 'started ${sp}'
	}
}

fn test_its_owner_ending_ends_it_and_is_told() {
	mut o := &Owner{
		running: true
	}
	mut s := start(transport.open('inproc:CYC5')!, Spec{
		period_ms: 5
	}, Life{
		running: fn [o] () bool {
			return o.running
		}
		ended:   fn [mut o] () {
			o.ended++
		}
	})!
	time.sleep(20 * time.millisecond)
	o.running = false
	assert s.wait_out(time.sys_mono_now() + 1_000_000_000)
	assert o.ended == 1
	assert !s.info().running
	// a stop after is answered at once
	assert s.stop()
	assert o.ended == 1
}

fn test_a_refused_send_is_counted_and_said() {
	// every send refused: counted, the last refusal kept, the sender going on
	mut s := start(&RefusingBus{}, Spec{
		period_ms: 5
	}, Life{})!
	time.sleep(40 * time.millisecond)
	i := s.info()
	assert i.running && i.failed >= 3 && i.sent == 0 && i.error == 'refused'
	assert s.stop()
}

fn test_stop_all_ends_every_sender_in_one_bound() {
	mut ss := []&Sender{}
	for _ in 0 .. 3 {
		ss << start(transport.open('inproc:CYC6')!, Spec{
			period_ms: 10
		}, Life{})!
	}
	t0 := time.ticks()
	assert stop_all(mut ss) == 0
	assert time.ticks() - t0 < 500
	assert ss.all(!it.info().running)
}

struct RefusingBus {}

fn (mut b RefusingBus) send(_ transport.CanFrame) ! {
	return error('refused')
}

fn (mut b RefusingBus) recv(_ int) !transport.CanFrame {
	return error('timeout')
}

fn (mut b RefusingBus) close() {}

fn (mut b RefusingBus) health() transport.BusHealth {
	return .unknown
}

fn (mut b RefusingBus) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn (mut b RefusingBus) reconcile_silence(_ bool) ! {}

@[heap]
struct Owner {
mut:
	running bool
	ended   int
}
