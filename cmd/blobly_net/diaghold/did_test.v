module diaghold

fn test_a_write_switches_to_the_session_its_did_is_written_in() {
	// SteerLimit: extended, level 1, from a fresh connection (no session answered yet)
	p := write_plan(0, [u8(0x03)], 1, 0, true)
	assert p.session == 0x03 && p.unlock == 1 && p.refusal == ''
	assert p.words() == 'switch to the extended session (0x10 03), then unlock level 1 with the reference key (0x27 01/02), then write (0x2E), then read it back (0x22)'
	// already there and unlocked: just the write
	q := write_plan(0x03, [u8(0x03)], 1, 1, true)
	assert q.session == 0 && q.unlock == 0
	// there, but locked
	assert write_plan(0x03, [u8(0x03)], 1, 0, true).unlock == 1
	// an open DID: nothing first
	o := write_plan(0x01, [], 0, 0, false)
	assert o.session == 0 && o.unlock == 0 && o.refusal == ''
	assert o.words() == 'write (0x2E), then read it back (0x22)'
}

fn test_a_session_change_locks_again() {
	// unlocked in the programming session, written in extended: the switch relocks it
	p := write_plan(0x02, [u8(0x03)], 1, 1, true)
	assert p.session == 0x03 && p.unlock == 1
}

fn test_extended_is_preferred_and_any_listed_session_is_kept() {
	assert write_plan(0x01, [u8(0x02), 0x03], 0, 0, false).session == 0x03
	assert write_plan(0x02, [u8(0x02), 0x03], 0, 0, false).session == 0
	assert write_plan(0x01, [u8(0x02)], 0, 0, false).session == 0x02
}

fn test_a_level_the_panel_cannot_unlock_is_said_not_faked() {
	p := write_plan(0x03, [u8(0x03)], 1, 0, false)
	assert p.unlock == 0
	assert p.refusal.contains('needs security level 1')
	assert p.refusal.contains('cannot compute')
	assert p.words() == p.refusal
	// a level already unlocked (by whatever means) needs no key
	assert write_plan(0x03, [u8(0x03)], 1, 1, false).refusal == ''
}

fn tm(us i64) Timing {
	return Timing{
		sent:   true
		rtt_us: us
	}
}

fn test_read_all_goes_on_past_a_refusal_and_says_one_line() {
	mut b := DidBatch{}
	b.answered(tm(2000))
	b.refusal(tm(500), 0x31)
	b.refusal(tm(500), 0x31)
	b.refusal(tm(700), 0x33)
	assert b.going()
	b.answered(Timing{
		sent:       true
		rtt_us:     60_000
		pending:    1
		pending_us: 50_000
	})
	assert b.summary(5) == 'Read all, 5 DID(s): 2 read, 3 refused (0x31 ×2, 0x33 ×1)'
	assert b.t.rtt_us == 63_700 && b.t.pending == 1 && b.t.pending_us == 50_000
}

fn test_read_all_stops_on_the_connection_and_says_what_was_not_asked() {
	mut b := DidBatch{}
	b.answered(tm(1000))
	b.failure(tm(0), 'timeout')
	assert !b.going()
	assert b.summary(10) == 'Read all, 10 DID(s): 1 read; stopped: timeout (8 not asked)'
	mut c := DidBatch{}
	c.refusal(tm(10), 0)
	assert c.summary(1) == 'Read all, 1 DID(s): 0 read, 1 refused (unreadable ×1)'
}

fn test_a_did_typed_by_hand_is_read_exactly_or_not_at_all() {
	assert parse_did('F190') or { 0 } == 0xF190
	assert parse_did('0xf190') or { 0 } == 0xF190
	assert parse_did(' 110 ') or { 0 } == 0x0110
	assert parse_did('') == none
	assert parse_did('1F190') == none // not a truncated F190
	assert parse_did('zz') == none // not 0x0000
	assert parse_did('0x') == none
}
