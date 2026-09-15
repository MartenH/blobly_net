module txclaim

const w = 'inproc:READINESS'

fn test_expected_wire_waits_before_any_tap_is_filed() {
	mut l := Ledger{}
	l.expect(w, 1)
	assert !l.send_ready(w, 1)
	assert l.may_claim_now(w, 1)
	l.claim(w, 1)
	assert !l.send_ready(w, 1)
	assert !l.may_claim_now(w, 1)
	l.opened(w, 1)
	l.expect(w, 1) // another tap cannot revoke an already-open handle
	assert l.send_ready(w, 1)
}

fn test_new_run_expectation_blocks_a_surviving_tools_old_readiness() {
	mut l := Ledger{}
	l.claim(w, 1)
	l.opened(w, 1)
	l.expect(w, 2)
	l.opened(w, 1)
	l.release(w, 1, false)
	assert !l.send_ready(w, 2)
	assert l.may_claim_now(w, 2)
	l.claim(w, 2)
	l.release(w, 2, true)
	l.expect(w, 2)
	assert !l.send_ready(w, 2)
	assert !l.may_claim_now(w, 2), 'expect must not bypass the supervisor retry cadence'
}

fn test_a_spawned_reader_does_not_make_transmission_ready() {
	mut l := Ledger{}
	assert l.send_ready('inproc:UNPLANNED', 1)
	l.claim(w, 1)
	assert !l.send_ready(w, 1)
	l.opened(w, 1)
	assert l.send_ready(w, 1)
}

fn test_a_retry_needs_its_own_open_receive_handle() {
	mut l := Ledger{}
	l.claim(w, 1)
	l.opened(w, 1)
	l.release(w, 1, true)
	assert !l.send_ready(w, 1)
	l.claim(w, 1)
	assert !l.send_ready(w, 1)
	l.opened(w, 1)
	assert l.send_ready(w, 1)
}

fn test_a_late_open_cannot_make_a_new_run_ready() {
	mut l := Ledger{}
	l.claim(w, 1)
	l.claim(w, 2)
	l.opened(w, 1)
	assert !l.send_ready(w, 2)
	l.opened(w, 2)
	assert l.send_ready(w, 2)
	l.release(w, 1, true)
	assert l.send_ready(w, 2)
}

fn test_retirement_is_not_readiness_and_does_not_leak_to_the_next_run() {
	mut l := Ledger{}
	for _ in 0 .. max_failures {
		l.claim(w, 1)
		l.release(w, 1, true)
	}
	l.opened(w, 1) // no held claim: cannot revive a released reader
	assert !l.send_ready(w, 1)
	assert l.retired(w, 1)
	assert l.send_ready(w, 2) // this run has not claimed it yet

	l.claim(w, 2)
	assert !l.send_ready(w, 2)
}
