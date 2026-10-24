module diaghold

fn test_the_selector_starts_at_the_lowest_level_the_gates_name() {
	assert unlock_level_default([], 8) == 1
	assert unlock_level_default([3, 2], 8) == 2
	assert unlock_level_default([0, 5], 8) == 5
	// a level the selector does not offer is not its default
	assert unlock_level_default([9], 8) == 1
}

fn test_an_all_zero_seed_is_already_unlocked() {
	assert seed_state([u8(0), 0, 0, 0]) == .unlocked
	assert seed_state([u8(0), 1]) == .locked
	assert seed_state([]) == .empty
}

fn test_a_refusal_says_what_it_means() {
	k := unlock_refusal_words(0x35, 'invalidKey', 1, true)
	assert k.starts_with('0x35 invalidKey — this ECU does not accept blobly_net\'s reference key')
	assert unlock_refusal_words(0x36, 'exceededNumberOfAttempts', 1, true).contains('locked out')
	assert unlock_refusal_words(0x37, 'requiredTimeDelayNotExpired', 1, false).contains('delay')
	assert unlock_refusal_words(0x24, 'requestSequenceError', 1, true).contains('no seed outstanding')
	assert unlock_refusal_words(0x12, 'subFunctionNotSupported', 3, false) == '0x12 subFunctionNotSupported — this ECU has no security level 3'
	assert unlock_refusal_words(0x10, 'generalReject', 1, false) == '0x10 generalReject'
}

fn test_an_unlock_is_refused_only_where_the_description_names_another_key() {
	assert unlock_refusal(true, true, false, false) == ''
	assert unlock_refusal(false, false, true, false) == '' // undescribed: tried, and a 0x35 says so
	assert unlock_refusal(true, false, false, false).contains('names no reference key')
	// over DoIP the reference key also needs the node's opt-in
	assert unlock_refusal(true, true, true, true) == ''
	assert unlock_refusal(true, true, true, false).contains('allow_bench_key')
	// on CAN the opt-in is not asked
	assert unlock_refusal(true, true, false, false) == ''
}

fn test_a_queued_unlock_is_not_sent_after_a_reload() {
	assert unlock_still_current('a', 'a') == ''
	assert unlock_still_current('', '') == ''
	assert unlock_still_current('a', 'b').contains('reloaded')
}

fn test_every_0x27_passes_one_gate() {
	// the press's verdict holds while its description is the loaded one
	assert unlock_step('a', 'a', '', 0) == UnlockStep{}
	// a reload since the press (it may have dropped the reference key or the DoIP opt-in): no 0x27
	assert unlock_step('a', 'b', '', 0).refusal.contains('reloaded')
	// a description that refuses the key on this carrier: no 0x27, whatever the session
	r := unlock_step('a', 'a', unlock_refusal(true, true, true, false), 0x03)
	assert r.refusal.contains('allow_bench_key') && r.session == 0
	// otherwise the session the caller leaves for first is the step's
	assert unlock_step('a', 'a', '', 0x03).session == 0x03
}
