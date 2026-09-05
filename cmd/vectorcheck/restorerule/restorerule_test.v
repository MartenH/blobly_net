module restorerule

fn two() (Entry, Entry) {
	return Entry{
		app: 61
		target: '57:0:0'
	}, Entry{
		app: 62
	}
}

fn test_a_channel_is_restored_exactly_once_whoever_claims_first() {
	a, b := two()
	mut l := Ledger{}
	assert l.record(a) && l.record(b)
	// the handler snapshots and claims both; the deferred cleanup, arriving second, gets nothing
	snap := l.close()
	handler := l.claim(snap)
	deferred := l.claim([a, b])
	assert handler.len == 2
	assert deferred.len == 0
	assert l.restoring == 1, 'an empty claim is not a restorer at work (round 4)'
	assert l.in_flight.len == 2
	// while the handler is writing, any exit is UNKNOWN and names both records
	v := l.verdict(false)
	assert v.outcome == .unknown && v.exit == 3
	assert v.pending.map(it.app) == [61, 62]
	// once it finishes, clean — and an interrupt's clean exit is 130, a command's 0
	l.finish(handler)
	l.finish(deferred) // a no-op finish for an empty claim
	assert l.restoring == 0 && l.in_flight.len == 0
	assert l.verdict(false).exit == 0
	assert l.verdict(true).exit == 130
}

fn test_a_failed_restore_fails_the_command_on_either_path() {
	a, b := two()
	mut l := Ledger{}
	l.record(a)
	l.record(b)
	mine := l.claim([a, b])
	l.fail()
	l.finish(mine)
	for interrupted in [false, true] {
		v := l.verdict(interrupted)
		assert v.outcome == .failed && v.exit == 3 && v.failed == 1
		assert v.pending.len == 0
	}
}

fn test_a_restore_still_in_flight_outranks_a_counted_failure() {
	a, b := two()
	mut l := Ledger{}
	l.record(a)
	l.record(b)
	first := l.claim([a])
	l.fail()
	l.finish(first)
	second := l.claim([b]) // stalled in the driver when the wait runs out
	v := l.verdict(true)
	assert v.outcome == .unknown && v.exit == 3
	assert v.failed == 1
	assert v.pending == [b]
	l.finish(second)
	assert l.verdict(true).outcome == .failed
}

fn test_no_borrow_after_the_handler_has_snapshotted() {
	a, b := two()
	mut l := Ledger{}
	assert l.record(a)
	snap := l.close()
	assert snap == [a]
	assert !l.record(b), 'a borrow after the snapshot is one nothing would restore'
	assert l.borrowed == [a]
}

fn test_a_borrow_whose_driver_write_failed_leaves_nothing_to_restore() {
	a, b := two()
	mut l := Ledger{}
	l.record(a)
	l.record(b)
	l.unrecord(61)
	assert l.borrowed == [b]
	l.unrecord(99) // unknown: nothing happens
	assert l.claim([a, b]) == [b]
}

fn test_two_claims_of_disjoint_channels_are_two_restorers() {
	a, b := two()
	mut l := Ledger{}
	l.record(a)
	l.record(b)
	ma := l.claim([a])
	mb := l.claim([b])
	assert l.restoring == 2
	l.finish(ma)
	assert l.restoring == 1
	assert l.verdict(false).pending == [b]
	l.finish(mb)
	assert l.verdict(false).outcome == .clean
}
