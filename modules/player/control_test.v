module player

import canlog
import transport

// The command protocol between a replay panel and its worker. Every test here corresponds to a
// rule that was, until now, enforced only by a comment — and two of them correspond to defects
// that reached review on #160, one of which was a defect of the other's fix (#161).

// ctl_rec builds a 0.2 s recording: frames at 0.0 / 0.1 / 0.2 s carrying ids 1, 2, 3. Named apart
// from the other files' helpers because `v test` compiles each _test.v on its own.
fn ctl_rec() []canlog.LogEntry {
	mut out := []canlog.LogEntry{}
	for i, t in [0.0, 0.1, 0.2] {
		out << canlog.LogEntry{
			t_s:   50.0 + t
			iface: 'test0'
			frame: transport.CanFrame{
				id:   u32(i + 1)
				data: [u8(i)]
			}
		}
	}
	return out
}

// ---- the sentinels -------------------------------------------------------

fn test_a_fresh_command_set_asks_for_nothing() {
	c := no_request()
	assert !c.pending()
	assert c.state == .stopped
	assert c.speed == 0
	assert c.seek == -1.0
	assert c.repeat == -1
}

// LOOP OFF IS A REQUEST. This is the whole reason the field is an i8 and not a bool: `false` as
// "no request" meant the worker re-cleared the flag every tick, so loop could never stay on.
fn test_turning_loop_off_is_distinguishable_from_asking_nothing() {
	mut off := no_request()
	off.repeat = 0
	assert off.pending(), 'loop off is a command, not silence'

	mut on := no_request()
	on.repeat = 1
	assert on.pending()
}

fn test_each_command_registers_as_pending() {
	mut a := no_request()
	a.state = .paused
	assert a.pending()
	mut b := no_request()
	b.speed = 2.0
	assert b.pending()
	mut c := no_request()
	c.seek = 0.0 // seeking to the very start is a real request
	assert c.pending(), 'position zero is a position'
}

// take() must read and clear together, or a command is applied twice or lost between the two.
fn test_take_returns_the_commands_and_clears_them() {
	mut c := no_request()
	c.state = .playing
	c.speed = 2.0
	c.seek = 0.1
	c.repeat = 1

	got := c.take()
	assert got.state == .playing
	assert got.speed == 2.0
	assert got.seek == 0.1
	assert got.repeat == 1
	assert !c.pending(), 'the second take of one tick must find nothing'
}

// ---- the ordering invariant ---------------------------------------------

// THE DEFECT THIS FILE EXISTS FOR (codex #160 r4, itself a defect of r2's fix). The panel's
// checkbox clears its pending latch when the published value agrees with it. Publish before
// applying and the status carries the value from BEFORE the command in the same tick — so a
// pending `false` matched a stale `false` the worker had not applied yet, the box cleared early,
// and then visibly flipped back on when the next tick published the intervening `true`.
fn test_the_published_status_includes_a_loop_command_taken_in_the_same_tick() {
	mut p := new_player(ctl_rec(), 1.0, false)
	mut cmds := no_request()
	cmds.repeat = 1

	taken := cmds.take()
	p.apply_latched(taken)
	st := p.status(0.0)

	assert st.repeat, 'the status published in a tick must reflect the command consumed in it'
}

fn test_the_same_holds_for_turning_loop_off() {
	mut p := new_player(ctl_rec(), 1.0, true)
	assert p.status(0.0).repeat

	mut cmds := no_request()
	cmds.repeat = 0
	p.apply_latched(cmds.take())
	assert !p.status(0.0).repeat
}

// And no request must not disturb it, in either direction.
fn test_no_loop_request_leaves_the_flag_alone() {
	mut on := new_player(ctl_rec(), 1.0, true)
	on.apply_latched(no_request())
	assert on.status(0.0).repeat, 'silence is not "turn loop off"'

	mut off := new_player(ctl_rec(), 1.0, false)
	off.apply_latched(no_request())
	assert !off.status(0.0).repeat
}

// apply_latched applies loop and NOTHING else — the other commands want a freshly sampled clock,
// and moving one of them in here would put mutex jitter into the replayed cadence.
fn test_apply_latched_touches_only_loop() {
	mut p := new_player(ctl_rec(), 1.0, false)
	p.play(0.0)
	before := p.state()

	mut cmds := no_request()
	cmds.state = .paused
	cmds.speed = 4.0
	cmds.seek = 0.2
	p.apply_latched(cmds)

	assert p.state() == before, 'apply_latched must not act on a state command'
	assert p.speed == 1.0, 'nor on a speed command'
}

// ---- a target, not a toggle ---------------------------------------------

// Two clicks inside one worker tick must not cancel out. The panel computes a TARGET from the
// state it can see, which publishes up to a tick late — a toggle applied here would undo itself.
fn test_asking_for_the_state_it_is_already_in_does_nothing() {
	mut p := new_player(ctl_rec(), 1.0, false)
	p.play(0.0)
	p.pause(50.0)
	pos := p.position_s(50.0)

	mut cmds := no_request()
	cmds.state = .paused
	p.apply_timed(cmds, 60.0)

	assert p.state() == .paused, 'pausing a paused player is not a resume'
	assert p.position_s(60.0) == pos, 'and must not move it'
}

fn test_a_pause_target_pauses_a_playing_player() {
	mut p := new_player(ctl_rec(), 1.0, false)
	p.play(0.0)
	mut cmds := no_request()
	cmds.state = .paused
	p.apply_timed(cmds, 50.0)
	assert p.state() == .paused
}

fn test_a_play_target_resumes_a_paused_player() {
	mut p := new_player(ctl_rec(), 1.0, false)
	p.play(0.0)
	p.pause(50.0)
	mut cmds := no_request()
	cmds.state = .playing
	out := p.apply_timed(cmds, 60.0)
	assert p.state() == .playing
	assert !out.restarted, 'resuming a pause is not a new run'
}

// ---- what the caller's counters must do ---------------------------------

// play() from .finished rewinds the recording AND the pass count, so every per-run number the
// caller owns has to rewind with it. Left cumulative, a second play-through announced "2N frames,
// 1 pass" — a worker-lifetime total paired with a per-run count (codex #160 r1).
fn test_restarting_a_finished_player_is_reported_as_a_restart() {
	mut p := new_player(ctl_rec(), 1.0, false)
	p.play(0.0)
	p.due(100000.0) // run it off the end
	assert p.state() == .finished

	mut cmds := no_request()
	cmds.state = .playing
	out := p.apply_timed(cmds, 100000.0)

	assert out.restarted, 'the caller has per-run counters to rewind'
	assert !out.revived
	assert p.state() == .playing
	assert p.passes() == 0, 'play() from finished rewinds the pass count too'
}

// SEEK IS NOT A RESTART. It moves within the run it is already in — demoting .finished to .paused
// at a position rather than rewinding to 0 — so its frames belong to the same run and keep
// counting. What it does re-arm is the end-of-run announcement.
fn test_seeking_a_finished_player_revives_it_without_restarting_the_run() {
	mut p := new_player(ctl_rec(), 1.0, false)
	p.play(0.0)
	p.due(100000.0)
	assert p.state() == .finished

	mut cmds := no_request()
	cmds.seek = 0.1
	out := p.apply_timed(cmds, 100000.0)

	assert out.revived, 'the next run-out is fresh news'
	assert !out.restarted, 'a seek does not begin a run, so the counters must not rewind'
	assert p.state() != .finished
}

fn test_an_ordinary_seek_reports_neither() {
	mut p := new_player(ctl_rec(), 1.0, false)
	p.play(0.0)
	mut cmds := no_request()
	cmds.seek = 0.1
	out := p.apply_timed(cmds, 50.0)
	assert !out.restarted
	assert !out.revived
}

// ---- speed ---------------------------------------------------------------

// The transport math belongs to the module, where a test can reach it: the hand-rolled
// pause/set/play dance this replaced scaled the position by new/old and dumped the difference
// onto the wire in one burst.
fn test_a_speed_command_changes_the_rate_and_keeps_the_position() {
	mut p := new_player(ctl_rec(), 1.0, false)
	p.play(0.0)
	before := p.position_s(100.0)

	mut cmds := no_request()
	cmds.speed = 2.0
	p.apply_timed(cmds, 100.0)

	assert p.speed == 2.0
	assert p.position_s(100.0) == before, 'a rate change is position-preserving'
	assert p.status(100.0).speed == 2.0
}

fn test_a_zero_speed_is_not_a_request() {
	mut p := new_player(ctl_rec(), 3.0, false)
	p.apply_timed(no_request(), 0.0)
	assert p.speed == 3.0, 'speed 0 is the sentinel, not a rate to set'
}

// ---- one whole tick ------------------------------------------------------

// The order the worker uses, end to end: take, apply what must precede the publish, publish,
// then apply what wants a fresh clock. What the panel reads back must never contradict the last
// intent it expressed.
fn test_a_full_tick_never_publishes_a_status_that_contradicts_the_intent() {
	mut p := new_player(ctl_rec(), 1.0, false)
	p.play(0.0)

	mut cmds := no_request()
	cmds.repeat = 1
	cmds.speed = 2.0
	cmds.state = .paused

	taken := cmds.take()
	p.apply_latched(taken)
	published := p.status(50.0)
	p.apply_timed(taken, 50.0)

	// Loop was applied before the publish, so the panel sees it immediately and its latch clears.
	assert published.repeat, 'loop must be acknowledged in the tick that took it'
	// The others are applied after, so the panel sees them on the NEXT tick — which is correct,
	// and is why the panel latches its own intent for those controls rather than reading back.
	assert p.state() == .paused
	assert p.speed == 2.0
	assert p.status(50.0).speed == 2.0
	assert !cmds.pending(), 'and the tick consumed every command exactly once'
}
