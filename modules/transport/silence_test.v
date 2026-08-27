module transport

import time

// The silence rules are pure and cross-platform, so they are tested where CI runs — unlike the two
// drivers they exist for, whose `_windows.v` files a Linux runner never compiles.

// A stand-in for the driver call, recording what it was asked for and in what order.
struct SilenceSpy {
mut:
	calls []bool
	fail  bool
	// Milliseconds spent "in the driver", PER REQUESTED STATE. Two different delays, because equal
	// ones cannot express the failure being tested: with both calls taking the same time they can
	// only complete in the order they started, and the record is right by accident. The bug needs a
	// LATER request to finish FIRST.
	slow_normal int
	slow_silent int
}

fn (s &SilenceSpy) setter() fn (bool) int {
	return fn [s] (silent bool) int {
		mut m := unsafe { s }
		d := if silent { m.slow_silent } else { m.slow_normal }
		if d > 0 {
			time.sleep(d * time.millisecond)
		}
		m.calls << silent
		return if m.fail { -7 } else { 0 }
	}
}

// THE FIRST ATTEMPT ON A WIRE ALWAYS REACHES THE DRIVER, EVEN FOR `false`. The table is empty at
// process start and the controller is not: a run that ended while this wire was marked left it
// silent, with nothing in this process to say so. "Nobody has told this wire anything yet" must
// therefore mean WRITE, never "it must already be normal".
fn test_the_first_attempt_on_a_wire_always_reaches_the_driver() {
	forget_silence_claims()
	mut spy := &SilenceSpy{}
	apply_silence('inproc:sil-a', false, spy.setter()) or { assert false, err.msg() }
	assert spy.calls == [false]

	mut spy2 := &SilenceSpy{}
	apply_silence('inproc:sil-b', true, spy2.setter()) or { assert false, err.msg() }
	assert spy2.calls == [true]
}

// And a second attempt at the same state is somebody else's job already done. The app opens each
// wire several times per Start — a reader, transmit taps, diagnostics — and on Kvaser every write
// bounces the bus, so one tick must not cost one bounce per handle.
fn test_a_repeat_of_the_same_state_does_not_reach_the_driver() {
	forget_silence_claims()
	mut spy := &SilenceSpy{}
	set := spy.setter()
	apply_silence('inproc:sil-c', true, set) or { assert false, err.msg() }
	apply_silence('inproc:sil-c', true, set) or { assert false, err.msg() }
	apply_silence('inproc:sil-c', true, set) or { assert false, err.msg() }
	assert spy.calls == [true]
}

fn test_a_change_of_mind_reaches_the_driver_again() {
	forget_silence_claims()
	mut spy := &SilenceSpy{}
	set := spy.setter()
	apply_silence('inproc:sil-d', true, set) or { assert false, err.msg() }
	apply_silence('inproc:sil-d', false, set) or { assert false, err.msg() }
	apply_silence('inproc:sil-d', false, set) or { assert false, err.msg() }
	apply_silence('inproc:sil-d', true, set) or { assert false, err.msg() }
	assert spy.calls == [true, false, true]
}

// A REFUSED WRITE IS REPORTED AND MAKES THE WIRE UNKNOWN. Reported, because entering silence is a
// promise the operator ticked a box for and the open path turns this into a refusal to open at
// all. Unknown rather than "whatever it was before", because a refused reconfiguration leaves the
// controller in a state nobody measured — so the next attempt writes instead of comparing against
// a guess.
fn test_a_refusal_is_reported_and_leaves_the_wire_unknown() {
	forget_silence_claims()
	mut spy := &SilenceSpy{
		fail: true
	}
	set := spy.setter()
	if _ := apply_silence('inproc:sil-e', true, set) {
		assert false, 'a driver refusal must not be swallowed'
	} else {
		assert err.msg().contains('listen-only'), err.msg()
		assert err.msg().contains('-7'), err.msg()
	}
	spy.fail = false
	apply_silence('inproc:sil-e', true, set) or { assert false, err.msg() }
	assert spy.calls == [true, true], 'the retry must reach the driver, not be suppressed'
}

// KEYED BY WIRE, which is the fact that makes any of this correct: the mode belongs to the
// controller, so every address naming one physical channel shares one answer.
fn test_addresses_for_one_wire_share_one_answer() {
	forget_silence_claims()
	mut spy := &SilenceSpy{}
	set := spy.setter()
	apply_silence('inproc:sil-f@500000', true, set) or { assert false, err.msg() }
	apply_silence('inproc:sil-f@500000', true, set) or { assert false, err.msg() }
	assert spy.calls == [true]
	// A different wire is a different answer, however similar the name.
	apply_silence('inproc:sil-f2@500000', true, set) or { assert false, err.msg() }
	assert spy.calls == [true, true]
}

// THE OPEN PATH TELLS THE TABLE WITHOUT GOING THROUGH IT. Both drivers choose the mode before the
// channel joins the bus — applied afterwards it would leave a window in which a listen-only row
// acknowledges on a live bus — so `open` sets it directly and records the result here.
fn test_a_mode_applied_at_open_is_not_applied_a_second_time() {
	forget_silence_claims()
	mut spy := &SilenceSpy{}
	note_silence_applied('inproc:sil-g', true)
	apply_silence('inproc:sil-g', true, spy.setter()) or { assert false, err.msg() }
	assert spy.calls == []
}

// AND WHAT THE DRIVER RESETS, THE TABLE MUST FORGET. PCAN's CAN_Uninitialize resets the mode, so a
// record surviving its close would let the next open skip a write the controller needs and hand
// back an acknowledging channel for a row that is still marked.
fn test_forgetting_a_wire_makes_the_next_attempt_reach_the_driver() {
	forget_silence_claims()
	mut spy := &SilenceSpy{}
	set := spy.setter()
	apply_silence('inproc:sil-h', true, set) or { assert false, err.msg() }
	forget_wire_silence('inproc:sil-h')
	apply_silence('inproc:sil-h', true, set) or { assert false, err.msg() }
	assert spy.calls == [true, true]
}

// THE RECORD AND THE CONTROLLER CANNOT DISAGREE, however the transitions interleave.
//
// This is the one the per-wire lock exists for. Publishing the requested state and then doing the
// I/O unlocked lets two opposite transitions finish in the wrong order — mark on, mark off again
// while the first write is still in flight — leaving the table saying `true` while the `false`
// write was the one that actually landed last. Every later attempt to silence the wire is then
// suppressed as redundant and the controller acknowledges indefinitely (codex round 1 on #219).
//
// Asserted as the property rather than as a schedule: whatever order the two threads run in, the
// LAST call the driver received is what the wire is recorded as.
fn test_opposing_transitions_leave_the_record_matching_the_last_write() {
	forget_silence_claims()
	// The FIRST request is the slow one and the second is quick, so that left to themselves they
	// complete in the reverse of the order they were made — which is exactly the interleaving that
	// inverted the record.
	mut spy := &SilenceSpy{
		slow_normal: 120
		slow_silent: 5
	}
	set := spy.setter()
	a := spawn fn [set] () {
		apply_silence('inproc:sil-race', false, set) or {}
	}()
	time.sleep(10 * time.millisecond)
	b := spawn fn [set] () {
		apply_silence('inproc:sil-race', true, set) or {}
	}()
	a.wait()
	b.wait()
	assert spy.calls.len == 2, '${spy.calls}'
	have := recorded_silence(wire_key('inproc:sil-race')) or {
		assert false, 'the wire should be recorded after both transitions'
		return
	}
	assert have == spy.calls.last(), 'recorded ${have}, driver last saw ${spy.calls.last()} (${spy.calls})'
}

// NOT ATTEMPTED IS NEITHER APPLIED NOR REFUSED. A closure that could not reach the driver says so,
// and the seam records nothing: no applied mode (the next attempt must write) and no fault (nothing
// was refused). Recording a fault here is how a device that was merely unreachable for one GET read
// as one that had declined.
fn test_not_attempted_records_neither_a_mode_nor_a_fault() {
	forget_silence_claims()
	if _ := apply_silence('inproc:sil-na', true, fn (silent bool) int {
		return silence_not_attempted
	})
	{
		assert false, 'not attempted must be reported as not done'
	} else {
		assert err.msg().contains('not applied'), err.msg()
	}
	assert wire_silence_fault('inproc:sil-na') == none
	mut spy := &SilenceSpy{}
	apply_silence('inproc:sil-na', true, spy.setter()) or { assert false, err.msg() }
	assert spy.calls == [true], 'the next attempt must reach the driver'
}

// A PROBE REACHES THE DRIVER EVEN WHEN THE RECORD SAYS THERE IS NOTHING TO DO. That is its whole
// purpose: the record is trusted by every ordinary caller, and the probe is what keeps it honest
// against a controller changed behind our back (codex round 1 on #223).
fn test_a_probe_asks_the_driver_despite_the_record() {
	forget_silence_claims()
	mut spy := &SilenceSpy{}
	set := spy.setter()
	apply_silence('inproc:sil-probe', true, set) or { assert false, err.msg() }
	apply_silence('inproc:sil-probe', true, set) or { assert false, err.msg() }
	assert spy.calls == [true], 'the ordinary path must be free once recorded'
	apply_silence_probe('inproc:sil-probe', true, set, fn (want bool, st int) SilenceReason {
		return SilenceReason{
			why: 'n/a'
		}
	}) or { assert false, err.msg() }
	assert spy.calls == [true, true], 'the probe must reach the driver'
}

// A DECLARED REFUSAL IS THE BACKEND'S WORD, and it travels with the fault.
fn test_an_explained_refusal_carries_the_backends_reading() {
	forget_silence_claims()
	apply_silence_explained('inproc:sil-decl', true, fn (silent bool) int {
		return 500
	}, fn (want bool, st int) SilenceReason {
		return SilenceReason{
			why:      'the device says no (${st})'
			declared: st == 500
		}
	}) or {}
	f := wire_silence_fault('inproc:sil-decl') or {
		assert false, 'a refusal must be recorded'
		return
	}
	assert f.declared
	assert f.why == 'the device says no (500)'
	// The generic seam declares nothing.
	forget_silence_claims()
	apply_silence('inproc:sil-decl', true, fn (silent bool) int {
		return -13
	}) or {}
	g := wire_silence_fault('inproc:sil-decl') or {
		assert false, 'a refusal must be recorded'
		return
	}
	assert !g.declared
}

// A REFUSAL IS RECORDED AGAINST THE WIRE, not only returned. The `open` path turns one into a
// refusal to open and `send` returns it to a caller — but a PASSIVE listener never calls send, so
// on a receive-only wire the error had no way out at all and the reconcile there is deliberately
// best-effort (a receive that fails takes the wire's reader down with it). The record is what the
// Buses panel reads beside the row (codex round 3 on #219).
fn test_a_refusal_is_recorded_against_the_wire() {
	forget_silence_claims()
	assert wire_silence_fault('inproc:sil-i') == none
	mut spy := &SilenceSpy{
		fail: true
	}
	set := spy.setter()
	apply_silence('inproc:sil-i', true, set) or {}
	f := wire_silence_fault('inproc:sil-i') or {
		assert false, 'a refused mode must leave a fault on the wire'
		return
	}
	assert f.why.contains('listen-only'), f.why
	assert f.want, 'the fault must say WHICH mode was refused'
	// AND CLEARED BY A LATER SUCCESS, because every receive retries: a transient refusal must not
	// leave the row shouting after the controller has come round.
	spy.fail = false
	apply_silence('inproc:sil-i', true, set) or { assert false, err.msg() }
	assert wire_silence_fault('inproc:sil-i') == none
}

// And a mode applied at OPEN clears it too — that path does not go through apply_silence, so it
// has to say so itself or a fault from a previous run outlives the wire it described.
fn test_a_mode_applied_at_open_clears_a_previous_fault() {
	forget_silence_claims()
	mut spy := &SilenceSpy{
		fail: true
	}
	apply_silence('inproc:sil-j', true, spy.setter()) or {}
	assert wire_silence_fault('inproc:sil-j') != none
	note_silence_applied('inproc:sil-j', true)
	assert wire_silence_fault('inproc:sil-j') == none
}

// AND WHICH DIRECTION IT WAS, because the two are opposite faults. A refused SILENCE is a wire
// still acknowledging on a bus it was told to observe; a refused NORMAL is a wire that cannot
// transmit at all. Reported as one message the panel described every fault as the first kind, and
// was exactly backwards for half of them (codex round 4 on #219).
fn test_a_fault_records_which_mode_was_refused() {
	forget_silence_claims()
	mut spy := &SilenceSpy{
		fail: true
	}
	apply_silence('inproc:sil-k', false, spy.setter()) or {}
	f := wire_silence_fault('inproc:sil-k') or {
		assert false, 'a refused normal-mode set must leave a fault too'
		return
	}
	assert !f.want, 'this wire was asked to be NORMAL, not silent'
	assert f.why.contains('normal'), f.why
}
