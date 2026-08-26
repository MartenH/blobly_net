// The command protocol between a replay panel and its worker — the part that is not GUI.
//
// WHY THIS IS A MODULE AND NOT A COMMENT. Two of the four codex findings on #160 landed in this
// path, and the second was a defect of the first one's fix (#161). Both were found by review
// rather than by a test, because there was no test that could reach it: `cmd/blobly_net` has no
// `_test.v` files, CI runs `v test modules/` only, and the logic sat between a `&App` and a 60 Hz
// ImGui draw call, so neither end could be exercised without the whole GUI.
//
// What was left enforcing it was prose: a tri-state sentinel, a TARGET rather than a toggle, an
// apply/publish ordering, and a pending latch that clears on acknowledgement — four different
// staleness rules on four adjacent struct fields, each correct, none checkable. The comments in
// the worker asked the next reader not to move two lines apart. This file is those rules written
// as code a test can hold.
//
// GUI-FREE, like every module here: it knows about a Player and about intent, and nothing about
// panels, mutexes or frames. The caller owns the locking — these are plain values.
module player

// Commands is one tick's worth of intent: panel -> worker.
//
// EVERY FIELD ENCODES "NO REQUEST" IN A SENTINEL, because the worker clears the whole set each
// tick and must be able to tell "nothing was asked" from "this exact value was asked for".
pub struct Commands {
pub mut:
	// A TARGET STATE, NOT A TOGGLE. State publishes up to a tick late, so two clicks inside one
	// worker tick collapsed a toggle into a no-op while the button still showed the pre-click
	// label. `.stopped` is the no-request sentinel: stopping is not something this path asks for.
	state State = .stopped
	// > 0 changes the rate, position preserved.
	speed f64
	// >= 0 jumps to this recording position, in seconds.
	seek f64 = -1.0
	// TRI-STATE, unlike the bool it carries. A bool has no value to spare for "no request":
	// `false` would be indistinguishable from "turn loop off", so the worker would re-clear the
	// flag every tick and loop could never stay on.
	repeat i8 = -1
}

// no_request is the cleared state — what the worker leaves behind after taking a tick's commands.
pub fn no_request() Commands {
	return Commands{}
}

// pending reports whether anything at all was asked for.
pub fn (c Commands) pending() bool {
	return c.state != .stopped || c.speed > 0 || c.seek >= 0 || c.repeat >= 0
}

// take reads this tick's commands and clears them in one step, so a command cannot be applied
// twice or dropped between the read and the clear. The caller holds whatever lock guards them.
pub fn (mut c Commands) take() Commands {
	got := Commands{
		state:  c.state
		speed:  c.speed
		seek:   c.seek
		repeat: c.repeat
	}
	c = Commands{}
	return got
}

// Status is what the worker publishes back: worker -> panel.
pub struct Status {
pub:
	state  State
	pos_s  f64
	speed  f64
	repeat bool
	loops  int
}

// Applied says what changed, for the counters only the caller owns.
pub struct Applied {
pub:
	// A run BEGAN AGAIN. play() from .finished rewinds the recording and the pass count, so every
	// other per-run number has to rewind with it — left cumulative, a second play-through
	// announced "2N frames, 1 pass", a worker-lifetime total paired with a per-run count.
	restarted bool
	// A finished player was seeked. NOT a restart: seek moves within the run it is already in,
	// demoting .finished to .paused at a position rather than rewinding to 0, so its frames
	// belong to the same run and keep counting. What it does re-arm is the end-of-run
	// announcement, because the next run-out is fresh news.
	revived bool
}

// apply_latched applies the commands that must land BEFORE the status is published, and nothing
// else.
//
// ONLY LOOP QUALIFIES, and the ordering is the whole point. set_repeat takes no clock and touches
// none, so it has nothing to gain from being applied later and one thing to lose: the status
// published in a tick would predate the command consumed in it. That is not cosmetic lag — the
// panel's checkbox clears its pending latch when the published value agrees, so a stale `false`
// matched a pending `false` the worker had not applied yet, the box cleared early, and then
// visibly flipped back on when the next tick published the intervening `true`.
//
// Every other command wants a freshly sampled clock instead, so that mutex jitter stays out of
// the replayed cadence — those are in apply_timed.
pub fn (mut p Player) apply_latched(c Commands) {
	if c.repeat >= 0 {
		p.set_repeat(c.repeat == 1)
	}
}

// status is the published view. Call it AFTER apply_latched, in the same tick, so that what it
// reports includes every command the worker has taken — the invariant the panel's acknowledgement
// rests on.
pub fn (p Player) status(now_ms f64) Status {
	return Status{
		state:  p.state()
		pos_s:  p.position_s(now_ms)
		speed:  p.speed
		repeat: p.repeat
		loops:  p.passes()
	}
}

// apply_timed applies the commands that need a freshly sampled clock, and reports what the
// caller's own counters must do about it.
pub fn (mut p Player) apply_timed(c Commands, now_ms f64) Applied {
	mut restarted := false
	mut revived := false
	// A TARGET, so two clicks inside one tick cannot cancel out: whatever the last one asked for
	// is what happens, and asking for the state it is already in does nothing.
	if c.state == .paused && p.state() == .playing {
		p.pause(now_ms)
	} else if c.state == .playing && p.state() in [State.paused, .finished] {
		restarted = p.state() == .finished
		p.play(now_ms) // from .finished this restarts at 0 — a panel labels it Restart
	}
	if c.speed > 0 {
		p.set_speed(c.speed, now_ms)
	}
	if c.seek >= 0 {
		revived = p.state() == .finished
		p.seek(c.seek, now_ms)
	}
	return Applied{
		restarted: restarted
		revived:   revived
	}
}
