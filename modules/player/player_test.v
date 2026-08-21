module player

import canlog
import transport

// rec builds a tiny recording: frames at the given offsets (seconds), each
// with its index as the CAN id so emissions are identifiable.
fn rec(offsets []f64) []canlog.LogEntry {
	mut out := []canlog.LogEntry{}
	for i, t in offsets {
		out << canlog.LogEntry{
			t_s:   100.0 + t // absolute base proves only deltas matter
			iface: 'test0'
			frame: transport.CanFrame{
				id:   u32(i + 1)
				data: [u8(i)]
			}
		}
	}
	return out
}

fn ids(es []canlog.LogEntry) []u32 {
	return es.map(it.frame.id)
}

fn test_recorded_cadence() {
	mut p := new_player(rec([0.0, 0.1, 0.2]), 1.0, false)
	assert p.due(0).len == 0 // not playing yet
	p.play(0)
	assert ids(p.due(0)) == [u32(1)] // first frame is due immediately
	assert p.due(50).len == 0 // 100ms frame not yet due
	assert ids(p.due(100)) == [u32(2)]
	assert ids(p.due(250)) == [u32(3)]
	assert p.finished()
	assert p.due(9999).len == 0
}

fn test_tick_granularity_emits_every_frame_once() {
	mut p := new_player(rec([0.0, 0.1, 0.2]), 1.0, false)
	p.play(0)
	// One late tick catches everything that has become due, in order.
	assert ids(p.due(1000)) == [u32(1), 2, 3]
	assert p.finished()
}

fn test_speed_factor() {
	mut p := new_player(rec([0.0, 1.0]), 2.0, false)
	p.play(0)
	p.due(0)
	assert p.due(400).len == 0 // 1s of recording = 500ms at 2x
	assert ids(p.due(500)) == [u32(2)]
}

fn test_pause_resume_keeps_position() {
	mut p := new_player(rec([0.0, 0.1, 0.2]), 1.0, false)
	p.play(0)
	assert p.due(0).len == 1
	p.pause(50) // 50ms in — frame 2 (due at 100) not yet played
	assert p.due(5000).len == 0 // paused: nothing emits, clock may run on
	p.play(1000) // resume much later
	assert p.due(1040).len == 0 // only 90ms of playback elapsed
	assert ids(p.due(1050)) == [u32(2)] // 100ms of playback elapsed
	assert ids(p.due(1150)) == [u32(3)]
}

fn test_stop_resets_to_start() {
	mut p := new_player(rec([0.0, 0.1]), 1.0, false)
	p.play(0)
	assert p.due(100).len == 2
	p.stop()
	assert p.state() == .stopped
	p.play(500)
	assert ids(p.due(500)) == [u32(1)] // restarted from the beginning
}

fn test_repeat_loops_with_duration_period() {
	mut p := new_player(rec([0.0, 0.1, 0.2]), 1.0, true)
	p.play(0)
	assert p.due(199).len == 2
	// 200ms: last frame of pass 1; the loop period is the 200ms duration, so
	// pass 2's first frame coincides with it.
	got := ids(p.due(200))
	assert got == [u32(3), 1]
	assert p.passes() == 1
	assert ids(p.due(300)) == [u32(2)]
	assert !p.finished()
}

fn test_repeat_zero_duration_finishes() {
	mut p := new_player(rec([0.0]), 1.0, true) // single frame: can't loop
	p.play(0)
	assert p.due(0).len == 1
	assert p.due(1).len == 0
	assert p.finished()
}

fn test_empty_recording_finishes_immediately() {
	mut p := new_player([]canlog.LogEntry{}, 1.0, false)
	p.play(0)
	assert p.due(0).len == 0
	assert p.finished()
	assert p.progress(0) == 1.0
}

fn test_play_after_finish_restarts() {
	mut p := new_player(rec([0.0, 0.1]), 1.0, false)
	p.play(0)
	p.due(1000)
	assert p.finished()
	p.play(2000)
	assert ids(p.due(2000)) == [u32(1)]
}

fn test_seek_forward_and_back() {
	mut p := new_player(rec([0.0, 0.1, 0.2, 0.3]), 1.0, false)
	p.play(0)
	p.seek(0.2, 0) // jump forward while playing
	assert ids(p.due(0)) == [u32(3)]
	p.seek(0.05, 50) // jump back while playing: next frame is the 100ms one
	assert ids(p.due(100)) == [u32(2)]
	assert ids(p.due(9999)) == [u32(3), 4]
	assert p.finished()
}

fn test_position_and_progress() {
	mut p := new_player(rec([0.0, 1.0]), 1.0, false)
	assert p.duration_s() == 1.0
	p.play(0)
	p.due(0)
	assert p.position_s(500) == 0.5
	assert p.progress(500) == 0.5
	p.pause(500)
	assert p.position_s(99999) == 0.5 // frozen while paused
}

fn test_unsorted_input_is_sorted() {
	mut es := rec([0.2, 0.0, 0.1]) // ids 1,2,3 at offsets 0.2,0.0,0.1
	mut p := new_player(es, 1.0, false)
	p.play(0)
	assert ids(p.due(1000)) == [u32(2), 3, 1] // emitted in time order
}

fn test_speed_guard() {
	p := new_player(rec([0.0]), -3.0, false)
	assert p.speed == 1.0
}

// set_speed preserves the recording position in every state — the property the GUI's
// hand-rolled pause/set/play dance violated (position scaled by new/old, then a burst of
// every frame in the gap; net#133). The probe position sits MID-GAP deliberately: seek's
// boundary rule is "an entry exactly at pos is the next to play", so a set_speed landing
// precisely on a frame time re-emits that frame — correct per that rule, but not what this
// test is about.
fn test_set_speed_keeps_position() {
	mut p := new_player(rec([0.0, 1.0, 2.0, 3.0, 4.0]), 1.0, false)
	p.play(0.0)
	assert p.due(2500.0).len == 3 // t=0,1,2 played; position now 2.5s, mid-gap
	assert p.position_s(2500.0) == 2.5

	// playing: double the rate at now=2500 — position must stay 2.5s
	p.set_speed(2.0, 2500.0)
	assert p.position_s(2500.0) == 2.5
	// nothing already owed — the burst bug returned the whole 2.5..5.0s gap here
	assert p.due(2500.0).len == 0
	// the NEXT frame (t=3.0s) is half a recording-second away: +250ms at 2x
	nd := p.next_due_ms() or {
		assert false, 'next frame must be pending'
		return
	}
	assert nd - 2500.0 > 249.0 && nd - 2500.0 < 251.0

	// paused: the same invariant without the clock running
	p.pause(2600.0)
	pos_before := p.position_s(2600.0)
	p.set_speed(0.5, 2600.0)
	assert p.position_s(2600.0) == pos_before

	// a nonsense rate is refused, not divided by
	p.set_speed(0.0, 2600.0)
	assert p.speed == 0.5
	p.set_speed(-2.0, 2600.0)
	assert p.speed == 0.5
}

// the binary-search seek lands where the linear scan did, including the exact boundary
// (an entry precisely AT the sought position is the next to play, not skipped).
fn test_seek_binary_boundaries() {
	mut p := new_player(rec([0.0, 1.0, 2.0, 3.0, 4.0]), 1.0, false)
	p.play(0.0)
	p.seek(2.0, 0.0)
	nxt := p.due(0.0) // same clock instant: exactly the boundary entry is due
	assert nxt.len == 1
	assert nxt[0].t_s - p.t0_s() == 2.0
	p.seek(0.0, 0.0)
	assert p.due(0.0).len == 1 // t=0 replays from the start
	p.seek(99.0, 0.0) // past the end clamps to duration
	assert p.position_s(0.0) == 4.0
}
