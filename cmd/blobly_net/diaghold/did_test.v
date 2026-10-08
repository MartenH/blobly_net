module diaghold

fn test_a_write_switches_to_the_session_its_did_is_written_in() {
	// SteerLimit: extended, level 1, from a fresh connection (no session answered yet)
	p := write_plan(true, 0, [u8(0x03)], 1, 0, true)
	assert p.session == 0x03 && p.unlock == 1 && p.refusal == ''
	assert p.words() == 'switch to the extended session (0x10 03), then unlock level 1 with the reference key (0x27 01/02), then write (0x2E), then read it back (0x22)'
	// already there and unlocked: just the write
	q := write_plan(true, 0x03, [u8(0x03)], 1, 1, true)
	assert q.session == 0 && q.unlock == 0
	// there, but locked
	assert write_plan(true, 0x03, [u8(0x03)], 1, 0, true).unlock == 1
	// an open DID: nothing first
	o := write_plan(true, 0x01, [], 0, 0, false)
	assert o.session == 0 && o.unlock == 0 && o.refusal == ''
	assert o.words() == 'write (0x2E), then read it back (0x22)'
}

fn test_a_session_change_locks_again() {
	// unlocked in the programming session, written in extended: the switch relocks it
	p := write_plan(true, 0x02, [u8(0x03)], 1, 1, true)
	assert p.session == 0x03 && p.unlock == 1
}

fn test_extended_is_preferred_and_any_listed_session_is_kept() {
	assert write_plan(true, 0x01, [u8(0x02), 0x03], 0, 0, false).session == 0x03
	assert write_plan(true, 0x02, [u8(0x02), 0x03], 0, 0, false).session == 0
	assert write_plan(true, 0x01, [u8(0x02)], 0, 0, false).session == 0x02
}

fn test_a_level_the_panel_cannot_unlock_is_said_not_faked() {
	p := write_plan(true, 0x03, [u8(0x03)], 1, 0, false)
	assert p.unlock == 0
	assert p.refusal.contains('needs security level 1')
	assert p.refusal.contains('cannot compute')
	assert p.words() == p.refusal
	// a level already unlocked (by whatever means) needs no key
	assert write_plan(true, 0x03, [u8(0x03)], 1, 1, false).refusal == ''
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

fn test_an_absent_write_gate_is_not_writable_never_no_requirements() {
	p := write_plan(false, 0x03, [], 0, 1, true)
	assert p.refusal == 'not writable: the description declares no write gate for it'
	assert p.session == 0 && p.unlock == 0
	// the same gate DECLARED with no session and no level is open
	assert write_plan(true, 0x03, [], 0, 0, false).refusal == ''
}

fn test_a_write_made_under_a_reloaded_description_is_not_sent() {
	assert write_still_current('sys@a', 'sys@a') == ''
	// changed between queueing and sending: nothing is sent, and it says why
	r := write_still_current('sys@a', 'sys@b')
	assert r.starts_with('not written')
	assert write_still_current('sys@a', '') != '' // the description went away
}

fn test_a_session_or_security_refusal_of_a_write_forgets_what_was_established() {
	assert write_refusal_forgets(0x7F) == .session
	assert write_refusal_forgets(0x33) == .security
	// refusals about the DID, the data or its conditions say nothing about the session
	for nrc in [u8(0x22), 0x31, 0x13, 0x72, 0x11] {
		assert write_refusal_forgets(nrc) == .nothing
	}
	// what is forgotten is planned again: a lost session switches and unlocks, a relocked level
	// unlocks in the session it still has
	p := write_plan(true, 0, [u8(0x03)], 1, 0, true)
	assert p.session == 0x03 && p.unlock == 1
	q := write_plan(true, 0x03, [u8(0x03)], 1, 0, true)
	assert q.session == 0 && q.unlock == 1
}

fn test_a_level_is_unlocked_by_its_own_sub_functions() {
	assert seed_sub(1) == 0x01
	assert seed_sub(2) == 0x03
	assert seed_sub(8) == 0x0F
	p := write_plan(true, 0x03, [u8(0x03)], 2, 0, true)
	assert p.unlock == 2
	assert p.words().contains('unlock level 2 with the reference key (0x27 03/04)'), p.words()
	assert write_plan(true, 0x03, [], 3, 0, false).refusal.starts_with('needs security level 3 (0x27 05)')
}

fn test_an_edit_buffer_holds_its_whole_text() {
	assert edit_room(2, 0) == 128
	assert edit_room(64, 0) == 3 * 64 + 16
	// an ASCII DID's text can outrun the hex room only when it is longer than the DID: held whole,
	// so encode says too long rather than the field cutting it
	assert edit_room(4, 300) == 317
	assert edit_room(200, 200) == 616
}

fn test_a_refused_did_says_its_code_by_name() {
	assert refused_words(0x31, 'requestOutOfRange') == '0x31 requestOutOfRange'
	assert refused_words(0x33, 'securityAccessDenied') == '0x33 securityAccessDenied'
	assert refused_words(0x7F, 'serviceNotSupportedInActiveSession') == '0x7F not supported in this session'
	assert refused_words(0x7E, 'subFunctionNotSupportedInActiveSession') == '0x7E not supported in this session'
}

fn test_a_gated_write_is_not_planned_in_the_default_session() {
	// only the default session: no 0x27 there, so the gate cannot be met
	p := write_plan(true, 0x01, [default_session], 1, 0, true)
	assert p.refusal.contains('needs security level 1 but names only the default session'), p.refusal
	assert p.session == 0 && p.unlock == 0
	assert p.words() == p.refusal
	assert write_plan(true, 0x03, [default_session], 2, 2, true).refusal != ''
	// default or extended, from default: written in extended, where the unlock is
	q := write_plan(true, 0x01, [default_session, 0x03], 1, 0, true)
	assert q.refusal == '' && q.session == 0x03 && q.unlock == 1
	// default or programming: the programming session
	assert write_plan(true, 0x01, [default_session, 0x02], 1, 0, true).session == 0x02
	// a level and any session, from default: the switch the unlock makes is in the plan
	a := write_plan(true, 0x01, [], 1, 0, true)
	assert a.session == 0x03 && a.unlock == 1
	assert write_plan(true, 0x02, [], 1, 0, true).session == 0
	// with no level the default session is fine
	assert write_plan(true, 0x01, [default_session], 0, 0, false) == WritePlan{}
}
