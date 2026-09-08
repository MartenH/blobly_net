module drainrule

// #107 AND #125 AS A TABLE. The bug both issues describe is one state — a run that has been
// stopped whose workers have not finished — so that state gets its own case, and the two it
// sits between are pinned beside it to say why neither condition alone is the rule.

fn test_stopped_and_drained_is_the_only_safe_state() {
	c := Census{ running: false, readers: 0 }
	assert c.may_rebuild()
	assert c.why() == ''
}

fn test_a_run_in_progress_refuses() {
	c := Census{ running: true, readers: 3 }
	assert !c.may_rebuild()
	assert c.why() == 'stop the measurement first'
}

// THE STATE #107 AND #125 LIVE IN: stopped, but not finished. Every plain Stop leaves the app
// here for ~200 ms — stop() ends its workers and returns without waiting — and a Lua script can
// leave it here for minutes. What changed is that rebuild_from_proj waits this state out instead
// of rebuilding into it; the state itself is still perfectly reachable, which is why the two
// panels gate on it and why this case is pinned. It is the one `!running` gets wrong.
fn test_stopped_but_still_draining_refuses() {
	c := Census{ running: false, readers: 1 }
	assert !c.may_rebuild()
	assert c.why().contains('still using this project')
	assert c.why().contains('1 background worker')
}

// A run whose census has not caught up yet: the spawner reserves as it goes, so `running` is
// true before every worker is counted. Reading the census alone would call this safe.
fn test_running_with_no_readers_yet_still_refuses() {
	c := Census{ running: true, readers: 0 }
	assert !c.may_rebuild()
	assert c.why() == 'stop the measurement first'
}

// The refusal is shown to a person, so it has to read as a sentence in both directions.
fn test_the_drain_message_agrees_with_itself_about_number() {
	assert Census{ readers: 1 }.why().contains('1 background worker')
	assert Census{ readers: 2 }.why().contains('2 background workers')
}

// A held slot is not necessarily a draining run — a Lua script holds one for as long as it runs
// — so the text must not name a cause the census cannot see. This is a real case, not a
// hypothetical: gating Start on the census made a running script report the previous run as
// still shutting down, which is a confident wrong answer about the one thing the operator
// cannot check from there.
fn test_the_held_slot_text_claims_no_cause() {
	w := Census{ readers: 1 }.why()
	assert !w.contains('run')
	assert !w.contains('stop')
	assert !w.contains('Stop')
}

// A run in progress is named as such however many workers it has: "stop first" is an
// instruction the operator can act on, and the drain text is not.
fn test_running_wins_the_explanation() {
	assert Census{ running: true, readers: 0 }.why() == Census{
		running: true
		readers: 9
	}.why()
}

// THE VERDICT AND THE WORDS FOR IT MUST AGREE AT EVERY INPUT, including one neither should ever
// see. Every reservation is paired, so a count below zero means a bug elsewhere — and the way
// that bug would present is a rebuild refused with nothing written beside it to say why, which
// is the least debuggable shape this pair can take.
fn test_the_verdict_and_the_reason_never_contradict() {
	for readers in [-2, -1, 0, 1, 5] {
		for running in [true, false] {
			c := Census{ running: running, readers: readers }
			assert c.may_rebuild() == (c.why() == '')
		}
	}
}
