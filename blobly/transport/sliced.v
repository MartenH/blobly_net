module transport

import time

// sliced_stop_code marks a recv_sliced that ended because its `stop` said so — the message is the
// caller's to choose, so each caller maps the code to its own note.
pub const sliced_stop_code = 0x5A1

// recv_sliced waits for a frame up to timeout_ms (negative: until one), in slices of slice_ms,
// asking `stop` before each — a receive another thread must be able to end (a run's Stop, a
// handle closed under it). A bus error other than a timeout ends it with that error; a 'timeout'
// a bus answered WITHOUT waiting is waited out to the slice's end on the monotonic clock, so such
// a bus costs one call per slice and not a core (#401). A zero timeout is one look (Bus.recv's
// recv(0) contract), stop not asked.
pub fn recv_sliced(mut bus Bus, timeout_ms int, slice_ms int, stop fn () bool) !CanFrame {
	if timeout_ms == 0 {
		return bus.recv(0)
	}
	deadline := time.ticks() + i64(timeout_ms)
	for {
		if stop() {
			return error_with_code('stopped', sliced_stop_code)
		}
		mut step := slice_ms
		if timeout_ms > 0 {
			left := deadline - time.ticks()
			if left <= 0 {
				return error('timeout')
			}
			if left < step {
				step = int(left)
			}
		}
		t0 := time.sys_mono_now()
		f := bus.recv(step) or {
			if err.msg() != 'timeout' {
				return err // the bus is gone (closed, failed): the receive ends with it
			}
			waited := i64(time.sys_mono_now() - t0)
			left_ns := i64(step) * time.millisecond - waited
			if left_ns > 0 {
				time.sleep(left_ns)
			}
			continue
		}
		return f
	}
	return error('timeout')
}
