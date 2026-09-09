module player

import time

// raise_timer_resolution: nothing to raise — nanosleep is accurate to the scheduler's tick, which
// is well below a millisecond on every Linux this runs on.
pub fn raise_timer_resolution() {
}

// wait_until_ms holds the caller until `due_ms` on its stopwatch: one nanosleep, which is
// accurate here. The Windows file is where the platform makes this harder.
pub fn wait_until_ms(mut sw time.StopWatch, due_ms f64) {
	rem := due_ms - f64(i64(sw.elapsed())) / 1e6
	if rem > 0 {
		time.sleep(i64(rem * 1_000_000.0) * time.nanosecond)
	}
}
