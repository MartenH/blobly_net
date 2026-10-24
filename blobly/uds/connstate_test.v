module uds

fn test_a_write_switches_to_the_session_its_did_is_written_in() {
	// SteerLimit: extended, level 1, from a fresh connection (no session answered yet)
	p := write_plan(true, 0, [u8(0x03)], 1, 0, true)
	assert p.session == 0x03 && p.unlock == 1 && p.refusal == ''
	assert p.words() == 'switch to the extended session (0x10 03), then unlock level 1 with the reference key (0x27 01/02), then write (0x2E), then read it back (0x22)'
	assert p.steps() == ['switch to the extended session (0x10 03)', 'unlock level 1 (0x27 01/02)']
	// already there and unlocked: just the write
	q := write_plan(true, 0x03, [u8(0x03)], 1, 1, true)
	assert q.session == 0 && q.unlock == 0 && q.steps() == []
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

fn test_a_level_the_tester_cannot_unlock_is_said_not_faked() {
	p := write_plan(true, 0x03, [u8(0x03)], 1, 0, false)
	assert p.unlock == 0
	assert p.refusal.contains('needs security level 1')
	assert p.refusal.contains('cannot compute')
	assert p.words() == p.refusal
	// a level already unlocked (by whatever means) needs no key
	assert write_plan(true, 0x03, [u8(0x03)], 1, 1, false).refusal == ''
}

fn test_an_absent_write_gate_is_not_writable_never_no_requirements() {
	p := write_plan(false, 0x03, [], 0, 1, true)
	assert p.refusal == 'not writable: the description declares no write gate for it'
	assert p.session == 0 && p.unlock == 0
	// the same gate DECLARED with no session and no level is open
	assert write_plan(true, 0x03, [], 0, 0, false).refusal == ''
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
	assert a.session == unlock_session(default_session) && a.unlock == 1
	assert write_plan(true, 0x02, [], 1, 0, true).session == 0
	// with no level the default session is fine
	assert write_plan(true, 0x01, [default_session], 0, 0, false) == WritePlan{}
}

fn test_an_unlock_leaves_the_default_session_and_keeps_any_other() {
	assert unlock_session(0) == extended_session // nothing answered 0x10 yet
	assert unlock_session(default_session) == extended_session
	assert unlock_session(0x03) == 0
	assert unlock_session(0x02) == 0 // a bootloader unlocks in its own session
}

fn test_a_refused_unlock_forgets_what_it_may_have_taken_back() {
	assert unlock_refusal_forgets(0x7F) == .session
	assert unlock_refusal_forgets(0x7E) == .security // the session is still the one it was
	assert unlock_refusal_forgets(0x35) == .security
	assert unlock_refusal_forgets(0x12) == .security
	assert unlock_refusal_forgets(0) == .security // a malformed answer
}

fn test_security_is_unknown_locked_or_a_level() {
	fresh := Security{}
	assert !fresh.known && fresh.unlocked() == 0 && fresh.words() == 'security unknown'
	assert security_locked().words() == 'locked' && security_locked().unlocked() == 0
	assert security_unlocked(2).words() == 'level 2 unlocked' && security_unlocked(2).unlocked() == 2
	// a write gated at a level asks the connection's unlocked level: unknown plans the unlock
	assert write_plan(true, 0x03, [u8(0x03)], 1, Security{}.unlocked(), true).unlock == 1
	assert write_plan(true, 0x03, [u8(0x03)], 1, security_unlocked(1).unlocked(), true).unlock == 0
}

fn test_session_names() {
	assert session_name(0) == '—'
	assert session_name(0x01) == 'default'
	assert session_name(0x02) == 'programming'
	assert session_name(0x03) == 'extended'
	assert session_name(0x60) == '0x60'
}

fn ok_x(req []u8, resp []u8) Exchange {
	return Exchange{
		req:    req
		resp:   resp
		timing: ExchangeTiming{
			sent: true
		}
	}
}

fn nrc_x(req []u8, nrc u8) Exchange {
	return Exchange{
		req:      req
		resp:     [u8(0x7F), req[0], nrc]
		err:      'negative'
		negative: true
		timing:   ExchangeTiming{
			sent: true
		}
	}
}

fn silent_x(req []u8, sent bool) Exchange {
	return Exchange{
		req:    req
		err:    'timeout'
		timing: ExchangeTiming{
			sent: sent
		}
	}
}

fn test_a_session_change_establishes_its_session_locked() {
	mut s := ConnState{
		session:  0x03
		security: security_unlocked(1)
	}
	s.observe(ok_x([u8(0x10), 0x03], [u8(0x50), 0x03, 0, 0x32, 0x01, 0xF4]))
	assert s.session == 0x03 && s.security == security_locked()
	// a suppressed one's quiet success is the session it asked for
	s.observe(ok_x([u8(0x10), 0x81], []))
	assert s.session == 0x01 && s.security.known
	// and an echo that carries the suppress bit, the session without it
	s.observe(ok_x([u8(0x10), 0x83], [u8(0x50), 0x83]))
	assert s.session == 0x03
	// refused: nothing changed
	s.observe(nrc_x([u8(0x10), 0x02], 0x22))
	assert s.session == 0x03
	// sent and unanswered: the ECU may have changed, so nothing is known
	s.observe(silent_x([u8(0x10), 0x03], true))
	assert s.session == 0 && !s.security.known
	assert s.words() == 'no session known, security unknown'
}

fn test_a_reset_is_the_default_session_locked() {
	mut s := ConnState{
		session:  0x03
		security: security_unlocked(1)
	}
	// rapid power shutdown on / off resets nothing
	s.observe(ok_x([u8(0x11), 0x04], [u8(0x51), 0x04, 0x05]))
	assert s.session == 0x03 && s.security == security_unlocked(1)
	s.observe(ok_x([u8(0x11), 0x01], [u8(0x51), 0x01]))
	assert s.session == default_session && s.security == security_locked()
}

fn test_a_granted_key_or_a_zero_seed_unlocks_its_level() {
	mut s := ConnState{
		session:  0x03
		security: security_locked()
	}
	// a seed to answer: still locked
	s.observe(ok_x([u8(0x27), 0x01], [u8(0x67), 0x01, 0x12, 0x34]))
	assert s.security.unlocked() == 0 && s.security.known
	s.observe(ok_x([u8(0x27), 0x02, 0xED, 0xCB], [u8(0x67), 0x02]))
	assert s.security == security_unlocked(1)
	assert s.words() == 'extended session, level 1 unlocked'
	// level 2's all-zero seed: already unlocked
	s.observe(ok_x([u8(0x27), 0x03], [u8(0x67), 0x03, 0, 0]))
	assert s.security == security_unlocked(2)
	// level 2 asked again and answered with a seed: it is locked again
	s.observe(ok_x([u8(0x27), 0x03], [u8(0x67), 0x03, 0x12, 0x34]))
	assert s.security.unlocked() == 0
	// an answer with no seed to answer: the level is not known
	s.observe(ok_x([u8(0x27), 0x05], [u8(0x67), 0x05]))
	assert !s.security.known && s.session == 0x03
}

fn test_a_refused_unlock_or_write_forgets_what_its_code_says() {
	base := ConnState{
		session:  0x03
		security: security_unlocked(1)
	}
	mut a := base
	a.observe(nrc_x([u8(0x27), 0x02, 0], 0x35))
	assert a.session == 0x03 && !a.security.known
	mut b := base
	b.observe(nrc_x([u8(0x27), 0x01], 0x7F))
	assert b.session == 0 && !b.security.known
	mut c := base
	c.observe(nrc_x([u8(0x2E), 0x01, 0x10, 0], 0x33))
	assert c.session == 0x03 && !c.security.known
	mut d := base
	d.observe(nrc_x([u8(0x2E), 0x01, 0x10, 0], 0x7F))
	assert d.session == 0 && !d.security.known
	mut e := base
	e.observe(nrc_x([u8(0x2E), 0x01, 0x10, 0], 0x31))
	assert e == base // about the DID, not the connection
	// a key sent and unanswered may have been processed
	mut f := base
	f.observe(silent_x([u8(0x27), 0x02, 0], true))
	assert f.session == 0x03 && !f.security.known
}

fn test_a_request_that_never_went_out_changes_nothing() {
	base := ConnState{
		session:  0x03
		security: security_unlocked(1)
	}
	mut s := base
	s.observe(silent_x([u8(0x10), 0x01], false))
	s.observe(silent_x([u8(0x27), 0x02], false))
	s.observe(Exchange{})
	assert s == base
	// nor does any other service
	s.observe(ok_x([u8(0x22), 0xF1, 0x90], [u8(0x62), 0xF1, 0x90, 0x41]))
	assert s == base
}

fn test_a_functional_request_is_observed_on_each_target() {
	mut c := Client{}
	c.state = ConnState{
		session:  0x03
		security: security_unlocked(1)
	}
	// answered: as a physical exchange
	c.observe_functional([u8(0x10), 0x01], FunctionalReply{
		outcome: .positive
		resp:    [u8(0x50), 0x01, 0, 0x32, 0x01, 0xF4]
	})
	assert c.state.session == 0x01 && c.state.security == security_locked()
	// silent: the server may have done it or suppressed a refusal, so nothing is known
	c.observe_functional([u8(0x10), 0x83], FunctionalReply{
		outcome: .silent
	})
	assert c.state.session == 0 && !c.state.security.known
	c.state = ConnState{
		session:  0x03
		security: security_unlocked(1)
	}
	// refused: what its code says
	c.observe_functional([u8(0x2E), 0x01, 0x10, 0], FunctionalReply{
		outcome: .negative
		resp:    [u8(0x7F), 0x2E, 0x33]
		nrc:     0x33
	})
	assert c.state.session == 0x03 && !c.state.security.known
}

fn test_another_ecu_knows_nothing_of_its_state() {
	mut c := Client{}
	c.state = ConnState{
		session:  0x03
		security: security_unlocked(1)
	}
	c.another_ecu()
	assert c.state == ConnState{}
}
