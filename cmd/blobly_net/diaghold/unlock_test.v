module diaghold

fn test_the_selector_starts_at_the_lowest_level_the_gates_name() {
	assert unlock_level_default([], 8) == 1
	assert unlock_level_default([3, 2], 8) == 2
	assert unlock_level_default([0, 5], 8) == 5
	// a level the selector does not offer is not its default
	assert unlock_level_default([9], 8) == 1
}

fn test_an_unlock_leaves_the_default_session_and_keeps_any_other() {
	assert unlock_session(0) == extended_session // nothing answered 0x10 yet
	assert unlock_session(default_session) == extended_session
	assert unlock_session(0x03) == 0
	assert unlock_session(0x02) == 0 // a bootloader unlocks in its own session
}

fn test_a_level_maps_to_its_seed_and_key_sub_functions() {
	assert seed_sub(1) == 0x01
	assert seed_sub(2) == 0x03
	assert seed_sub(8) == 0x0F
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
	assert unlock_refusal(true, true) == ''
	assert unlock_refusal(false, false) == '' // undescribed: tried, and a 0x35 says so
	assert unlock_refusal(true, false).contains('names no reference key')
}

fn test_a_refused_unlock_forgets_what_it_may_have_taken_back() {
	assert unlock_refusal_forgets(0x7F) == .session
	assert unlock_refusal_forgets(0x7E) == .security // the session is still the one it was
	assert unlock_refusal_forgets(0x35) == .security
	assert unlock_refusal_forgets(0x12) == .security
}

fn test_a_queued_unlock_is_not_sent_after_a_reload() {
	assert unlock_still_current('a', 'a') == ''
	assert unlock_still_current('', '') == ''
	assert unlock_still_current('a', 'b').contains('reloaded')
}
