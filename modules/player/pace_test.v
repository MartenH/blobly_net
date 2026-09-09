module player

import time

// wait_until_ms returns at or after its deadline, never before, and does not overshoot it by
// more than the platform's quantum with a wide margin: the bound a replay's cadence rests on.
// Loose on purpose — a preempted shared runner must not fail a correct build.
fn test_wait_until_ms_returns_at_or_after_the_deadline() {
	mut sw := time.new_stopwatch()
	for gap in [0.3, 1.2, 3.7, 12.0] {
		start := f64(i64(sw.elapsed())) / 1e6
		wait_until_ms(mut sw, start + gap)
		took := f64(i64(sw.elapsed())) / 1e6 - start
		assert took >= gap, 'returned ${took} ms into a ${gap} ms wait'
		assert took < gap + 100.0, 'a ${gap} ms wait took ${took} ms'
	}
	// a deadline already passed returns at once
	start := f64(i64(sw.elapsed())) / 1e6
	wait_until_ms(mut sw, start - 5.0)
	assert f64(i64(sw.elapsed())) / 1e6 - start < 50.0
}
