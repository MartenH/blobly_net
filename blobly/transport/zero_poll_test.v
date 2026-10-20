module transport

import time

// The one rule every backend applies after it skips a filtered record — and the only test that
// reaches it for the drivers no CI runner loads (Kvaser, Vector, PCAN).
fn test_look_again_is_the_callers_wait_and_a_bounded_look_at_zero() {
	// forever is forever
	assert look_again(-1, 1_000_000, 1_000_000_000_000)
	// a positive wait lasts exactly as long as it was asked to
	assert look_again(200, 1, 199_999_999)
	assert !look_again(200, 1, 200_000_000)
	// a zero-timeout look skips what is queued, within the count and the time bound
	assert look_again(0, 1, 0)
	assert look_again(0, zero_poll_skip_limit - 1, zero_poll_budget_ns - 1)
	assert !look_again(0, zero_poll_skip_limit, 0)
	assert !look_again(0, 1, zero_poll_budget_ns)
}

// recv(0) on an empty in-process bus answers at once, and returns what is queued.
fn test_inproc_zero_receive_is_a_look() {
	mut rx := open_inproc('zero_poll_inproc')!
	mut tx := open_inproc('zero_poll_inproc')!
	defer {
		rx.close()
		tx.close()
	}
	t0 := time.ticks()
	for _ in 0 .. 100 {
		if _ := rx.recv(0) {
			assert false, 'a frame from nowhere'
		}
	}
	assert time.ticks() - t0 < 50, '100 looks at an empty bus took ${time.ticks() - t0} ms'
	tx.send(CanFrame{ id: 0x42 })!
	assert rx.recv(0)!.id == 0x42
}
