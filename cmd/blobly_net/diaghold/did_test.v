module diaghold

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

fn test_a_write_made_under_a_reloaded_description_is_not_sent() {
	assert write_still_current('sys@a', 'sys@a') == ''
	// changed between queueing and sending: nothing is sent, and it says why
	r := write_still_current('sys@a', 'sys@b')
	assert r.starts_with('not written')
	assert write_still_current('sys@a', '') != '' // the description went away
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

