module project

fn test_a_typed_replay_speed_ignores_space_and_falls_back_to_real_time() {
	assert replay_speed_of('2') == 2.0
	assert replay_speed_of(' 2') == 2.0
	assert replay_speed_of('0.5 ') == 0.5
	for bad in ['', '0', '-1', 'fast', 'nan', 'inf', '1e400', '1e-320'] {
		assert replay_speed_of(bad) == 1.0, bad
	}
}
