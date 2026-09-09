module txclaim

const w = 'inproc:BARE'

fn test_an_unclaimed_wire_may_be_claimed() {
	l := Ledger{}
	assert l.may_claim(w, 1)
}

fn test_one_reader_per_wire() {
	mut l := Ledger{}
	l.claim(w, 1)
	assert !l.may_claim(w, 1), 'a reader is already running for it'
}

fn test_a_clean_release_frees_the_wire() {
	mut l := Ledger{}
	l.claim(w, 1)
	l.release(w, 1, false)
	assert l.may_claim(w, 1), 'the tap went; if it comes back the wire is watched again'
	assert !l.retired(w, 1)
}

// ROUND 3's finding, and it falls out of generation being part of the identity rather than
// needing a reset to keep in step: an adapter repaired between a Stop and a Start is watched
// again, without anything having to remember to clear the map.
fn test_a_previous_runs_entry_is_not_a_claim_on_this_one() {
	mut l := Ledger{}
	l.claim(w, 1)
	for _ in 0 .. max_failures {
		l.claim(w, 1)
		l.release(w, 1, true)
	}
	assert !l.may_claim(w, 1), 'retired for run 1'
	assert l.may_claim(w, 2), 'run 2 is a different run'
	assert !l.retired(w, 2)
}

// ROUND 4's finding: a reader still blocked in recv across a Stop and a Start reaches its release
// after the NEW supervisor has claimed the wire. An unconditional delete there hands out a second
// reader for one tap, and two readers narrate one transition twice.
fn test_a_departing_reader_does_not_erase_its_successors_claim() {
	mut l := Ledger{}
	l.claim(w, 1) // the old run's reader
	l.claim(w, 2) // Start; the new supervisor claims the same wire
	l.release(w, 1, false) // the old reader finally wakes up and lets go
	assert !l.may_claim(w, 2), "the new run's reader still holds it"
}

fn test_a_release_from_a_run_that_never_claimed_is_ignored() {
	mut l := Ledger{}
	l.claim(w, 2)
	l.release(w, 1, true)
	assert !l.may_claim(w, 2)
	assert !l.retired(w, 2), 'and it did not book a failure against run 2 either'
}

// ROUND 4's other finding: a wire can carry several taps, so the one a reader holds may be closed
// while others stay live and transmitting. One hard error cannot tell that from a dead adapter, so
// it is counted rather than acted on — a lifecycle close happens once, and the wire is read again.
fn test_a_single_hard_error_does_not_retire_the_wire() {
	mut l := Ledger{}
	l.claim(w, 1)
	l.release(w, 1, true)
	assert l.may_claim(w, 1), 'one failure is not an adapter that has gone'
	assert !l.retired(w, 1)
}

// …and an adapter that really has gone stops being retried, instead of being reopened once a
// second for the rest of the run.
fn test_repeated_hard_errors_retire_the_wire() {
	mut l := Ledger{}
	for i in 0 .. max_failures {
		assert l.may_claim(w, 1), 'attempt ${i + 1} of ${max_failures}'
		l.claim(w, 1)
		l.release(w, 1, true)
	}
	assert !l.may_claim(w, 1)
	assert l.retired(w, 1), 'and the caller can say so, once'
}

// A wire that fails and then succeeds keeps its count: the failures are what the run has seen,
// and a clean release is not evidence the adapter came back.
fn test_a_clean_release_does_not_forgive_earlier_failures() {
	mut l := Ledger{}
	l.claim(w, 1)
	l.release(w, 1, true)
	l.claim(w, 1)
	l.release(w, 1, false)
	l.claim(w, 1)
	l.release(w, 1, true)
	l.claim(w, 1)
	l.release(w, 1, true)
	assert l.retired(w, 1), 'three failures across the run, whatever happened between them'
}

// Carried into a new run, the count starts again: those failures belonged to the old run's
// adapter, not to this one's.
fn test_a_new_run_starts_the_count_again() {
	mut l := Ledger{}
	l.claim(w, 1)
	l.release(w, 1, true)
	l.claim(w, 1)
	l.release(w, 1, true)
	l.claim(w, 2)
	l.release(w, 2, true)
	assert l.may_claim(w, 2), 'one failure in run 2, not three'
	assert !l.retired(w, 2)
}

fn test_wires_do_not_interfere() {
	mut l := Ledger{}
	other := 'inproc:OTHER'
	for _ in 0 .. max_failures {
		l.claim(w, 1)
		l.release(w, 1, true)
	}
	assert !l.may_claim(w, 1)
	assert l.may_claim(other, 1)
}

fn test_a_release_without_a_claim_is_ignored() {
	mut l := Ledger{}
	l.release(w, 1, true)
	assert l.may_claim(w, 1)
	assert !l.retired(w, 1)
}

// Releasing twice must not book two failures for one reader.
fn test_a_second_release_is_ignored() {
	mut l := Ledger{}
	l.claim(w, 1)
	l.release(w, 1, true)
	l.release(w, 1, true)
	l.release(w, 1, true)
	assert l.may_claim(w, 1), 'one reader, one failure'
	assert !l.retired(w, 1)
}
