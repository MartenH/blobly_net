// player — replay a CAN recording at its recorded cadence (Phase 8).
//
// A Player steps through a time-sorted []canlog.LogEntry stream (the common
// currency of canlog `.log` and the native MF4 reader) and tells the caller
// which frames are due *now*, scaled by a speed factor and optionally looping.
// What "now" means is the caller's business: the GUI feeds it a wall-clock
// (time.ticks() deltas) and pushes due frames onto a transport.Bus and/or the
// trace; tests feed it a simulated clock — the module itself never reads time,
// so it is hermetic and platform-free (same pattern as sim.Engine.due_frames).
//
// Transport model: play/pause/stop/seek like a media player. The playback
// clock is `now_ms` (monotonic ms, caller-defined origin); the recording
// position is seconds into the recording (entry t_s minus the first entry's
// t_s). speed scales recording-time → playback-time (2.0 = twice as fast).
module player

import canlog

// time_eps_ms absorbs float error in the offset arithmetic (timestamps are
// f64 seconds; subtracting a large epoch base leaves ~1e-11 ms residue that
// would push an exactly-due frame past the comparison). 1 µs slack.
const time_eps_ms = 0.001

// State is the player's transport state.
pub enum State {
	stopped // at the start, not emitting
	playing
	paused
	finished // ran off the end (non-looping); play() restarts from 0
}

// Player replays a recording. Create with new_player; drive with due().
pub struct Player {
pub mut:
	speed  f64 = 1.0 // playback rate (1.0 = recorded cadence); must be > 0
	repeat bool // loop back to the start at the end of the recording
mut:
	entries    []canlog.LogEntry // time-sorted
	st         State = .stopped
	idx        int // next entry to emit (into the current pass)
	base_ms    f64 // playback clock at which the current pass's first entry plays
	elapsed_ms f64 // playback-clock position retained across pause/stop/seek
	loops      int // completed loop passes (diagnostics)
}

// new_player builds a Player over a recording. Entries are sorted by timestamp
// defensively (canlog/mf4 already produce sorted streams). A speed <= 0 is
// coerced to 1.0.
pub fn new_player(entries []canlog.LogEntry, speed f64, repeat bool) Player {
	mut es := entries.clone()
	es.sort(a.t_s < b.t_s)
	return Player{
		entries: es
		speed:   if speed > 0 { speed } else { 1.0 }
		repeat:  repeat
	}
}

// play starts (or resumes) playback at playback-clock now_ms. From .finished
// it restarts at the beginning.
pub fn (mut p Player) play(now_ms f64) {
	if p.st == .playing {
		return
	}
	if p.st == .finished {
		p.idx = 0
		p.elapsed_ms = 0
	}
	p.base_ms = now_ms - p.elapsed_ms
	p.st = .playing
}

// pause freezes playback, retaining the current position.
pub fn (mut p Player) pause(now_ms f64) {
	if p.st != .playing {
		return
	}
	p.elapsed_ms = now_ms - p.base_ms
	p.st = .paused
}

// stop resets to the start of the recording.
pub fn (mut p Player) stop() {
	p.st = .stopped
	p.idx = 0
	p.elapsed_ms = 0
}

// seek jumps to a recording position (seconds into the recording, clamped to
// [0, duration]). Works in any state; while playing it re-anchors the clock so
// playback continues from the new position.
pub fn (mut p Player) seek(pos_s f64, now_ms f64) {
	mut pos := pos_s
	if pos < 0 {
		pos = 0
	}
	if pos > p.duration_s() {
		pos = p.duration_s()
	}
	p.elapsed_ms = pos * 1000.0 / p.speed
	t0 := p.t0_s()
	p.idx = 0
	for p.idx < p.entries.len && p.entries[p.idx].t_s - t0 < pos {
		p.idx++
	}
	if p.st == .playing {
		p.base_ms = now_ms - p.elapsed_ms
	} else if p.st == .finished {
		p.st = .paused
	}
}

// due returns every entry whose recorded offset has elapsed by playback-clock
// now_ms, advancing past them. Returns nothing unless playing. At the end of
// the recording it either loops (repeat, recording longer than zero) or moves
// to .finished. Call it at whatever tick rate suits the sink; every frame is
// emitted exactly once per pass regardless of tick granularity.
pub fn (mut p Player) due(now_ms f64) []canlog.LogEntry {
	mut out := []canlog.LogEntry{}
	if p.st != .playing {
		return out
	}
	if p.entries.len == 0 {
		p.st = .finished
		return out
	}
	t0 := p.t0_s()
	for {
		if p.idx >= p.entries.len {
			// End of a pass. Loop with the recording's duration as the period
			// (a zero-length recording can't loop — it would spin forever).
			if p.repeat && p.duration_s() > 0 {
				p.base_ms += p.duration_s() * 1000.0 / p.speed
				p.idx = 0
				p.loops++
				continue
			}
			p.st = .finished
			p.elapsed_ms = p.duration_s() * 1000.0 / p.speed
			break
		}
		e := p.entries[p.idx]
		due_at := p.base_ms + (e.t_s - t0) * 1000.0 / p.speed
		if due_at > now_ms + time_eps_ms {
			break
		}
		out << e
		p.idx++
	}
	return out
}

// state returns the transport state.
pub fn (p Player) state() State {
	return p.st
}

// finished reports whether a non-looping replay has run off the end.
pub fn (p Player) finished() bool {
	return p.st == .finished
}

// len returns the number of frames in the recording.
pub fn (p Player) len() int {
	return p.entries.len
}

// sent returns how many frames of the current pass have been emitted.
pub fn (p Player) sent() int {
	return p.idx
}

// passes returns how many complete loop passes have finished.
pub fn (p Player) passes() int {
	return p.loops
}

// t0_s is the recording's first timestamp (the zero of recording position).
fn (p Player) t0_s() f64 {
	if p.entries.len == 0 {
		return 0
	}
	return p.entries[0].t_s
}

// duration_s is the recording's length in seconds (first to last frame).
pub fn (p Player) duration_s() f64 {
	if p.entries.len < 2 {
		return 0
	}
	return p.entries.last().t_s - p.entries[0].t_s
}

// position_s is the current recording position in seconds.
pub fn (p Player) position_s(now_ms f64) f64 {
	mut el := p.elapsed_ms
	if p.st == .playing {
		el = now_ms - p.base_ms
	}
	mut pos := el * p.speed / 1000.0
	if pos < 0 {
		pos = 0
	}
	if pos > p.duration_s() {
		pos = p.duration_s()
	}
	return pos
}

// progress is the current position as a 0..1 fraction (1.0 for an empty or
// single-frame recording once playback has started).
pub fn (p Player) progress(now_ms f64) f64 {
	d := p.duration_s()
	if d <= 0 {
		return if p.st == .finished { 1.0 } else { 0.0 }
	}
	return p.position_s(now_ms) / d
}
