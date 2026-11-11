module udsconn

fn says(why ?string) string {
	return why or { '' }
}

fn test_stated_sizes_are_held_to_one_answer_on_the_carrier() {
	assert says(did_size_refusal(65525, false)) == ''
	assert says(did_size_refusal(65526, false)) == '65526 bytes is not a DID size'
	assert says(ext_size_refusal(65528, false)) == ''
	assert says(ext_size_refusal(65529, false)) == '65529 bytes is not a record size'
	assert says(did_size_refusal(-1, false)) != ''
	assert says(did_size_refusal(65522, true)) == ''
	assert says(did_size_refusal(65523, true)) != ''
	assert says(ext_size_refusal(65525, true)) == ''
	assert says(ext_size_refusal(65526, true)) != ''
}
