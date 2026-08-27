module transport

// The claim rule is pure and cross-platform, so it is tested where CI runs — unlike the two
// drivers it exists for, whose `_windows.v` files a Linux runner never compiles.

fn test_the_first_claim_on_a_wire_always_wins() {
	forget_silence_claims()
	// EVEN FOR `false`, which is the whole point. The table is empty at process start and the
	// controller's mode is not: a run that ended while this wire was marked left it silent, with
	// nothing in this process to say so. "Nobody has told this wire anything yet" must therefore
	// mean WRITE, never "it must already be normal".
	assert claim_silence('inproc:silence-a', false)
	assert claim_silence('inproc:silence-b', true)
}

fn test_a_second_claim_for_the_same_state_is_somebody_elses_job() {
	forget_silence_claims()
	assert claim_silence('inproc:silence-c', true)
	// The app opens each wire several times per Start — a reader, transmit taps, diagnostics — and
	// on Kvaser every write bounces the bus. One tick must not cost one bounce per handle.
	assert !claim_silence('inproc:silence-c', true)
	assert !claim_silence('inproc:silence-c', true)
}

fn test_a_change_of_mind_is_claimed_again() {
	forget_silence_claims()
	assert claim_silence('inproc:silence-d', true)
	assert claim_silence('inproc:silence-d', false)
	assert !claim_silence('inproc:silence-d', false)
	assert claim_silence('inproc:silence-d', true)
}

// A FAILED WRITE MAKES THE WIRE UNKNOWN, not "whatever it was before": a refused reconfiguration
// leaves the controller in a state nobody measured, and unknown is both the honest record and the
// useful one — the next caller writes instead of comparing against a guess.
fn test_a_released_claim_is_retried_by_the_next_caller() {
	forget_silence_claims()
	assert claim_silence('inproc:silence-e', true)
	release_silence_claim('inproc:silence-e', true)
	assert claim_silence('inproc:silence-e', true)
}

// And a straggler reporting an OLD failure must not erase a claim that has since superseded it,
// or a wire that was successfully set back to normal is recorded as unknown and bounced again.
fn test_releasing_a_superseded_claim_changes_nothing() {
	forget_silence_claims()
	assert claim_silence('inproc:silence-f', true)
	assert claim_silence('inproc:silence-f', false)
	release_silence_claim('inproc:silence-f', true) // the stale one
	assert !claim_silence('inproc:silence-f', false)
}

// KEYED BY WIRE, so the several addresses that name one physical channel share one answer — which
// is the fact that makes claiming correct at all: the mode belongs to the controller, and every
// handle open on it sees the same one.
fn test_addresses_for_one_wire_share_a_claim() {
	forget_silence_claims()
	assert claim_silence('inproc:silence-g@500000', true)
	assert !claim_silence('inproc:silence-g@500000', true)
	// A different wire is a different answer, however similar the name.
	assert claim_silence('inproc:silence-g2@500000', true)
}
