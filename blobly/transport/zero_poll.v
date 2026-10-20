module transport

import time

// zero_poll_skip_limit and zero_poll_budget_ns bound how far ONE zero-timeout receive looks past
// records its backend filters before it answers timeout — the "bounded by count AND by time" of
// the recv(0) contract stated on the Bus interface (transport.v).
const zero_poll_skip_limit = 4096
const zero_poll_budget_ns = i64(1_000_000)

// look_again is whether a receive that just SKIPPED a record its backend filters — an error frame,
// a TX confirmation, a chip-state or status record, our own echo, a malformed datagram — reads
// once more: for as long as the caller's wait lasts (forever when it is negative), and for a
// zero-timeout look while the skips stay within zero_poll_skip_limit and zero_poll_budget_ns. A
// zero-timeout look that reads again reads only what is already queued; it never waits.
//
// ONE RULE FOR EVERY BACKEND, and pure, so a Linux test pins it for the drivers no CI runner can
// load: each of them had its own, and four of them stopped after skipping ONE record, answering
// timeout with a data frame queued right behind it.
fn look_again(timeout_ms int, skipped int, elapsed_ns i64) bool {
	if timeout_ms < 0 {
		return true
	}
	if timeout_ms > 0 {
		return elapsed_ns < i64(timeout_ms) * 1_000_000
	}
	return skipped < zero_poll_skip_limit && elapsed_ns < zero_poll_budget_ns
}

// since_ns is the time since `started` (a time.sys_mono_now() reading), for look_again.
fn since_ns(started u64) i64 {
	return i64(time.sys_mono_now() - started)
}

// read_wait_ms is how long a receive's next driver read may wait, for a backend that re-reads
// after a skip: the whole timeout on its first read, what is LEFT of it on a retry, and none — the
// receive is over — once a positive wait is spent, since a zero-wait read past expiry could accept
// a frame that arrived after it. A negative timeout reads in `slice_ms` slices; zero is a look.
fn read_wait_ms(timeout_ms int, skipped int, elapsed_ns i64, slice_ms u32) ?u32 {
	if timeout_ms < 0 {
		return slice_ms
	}
	if timeout_ms == 0 || skipped == 0 {
		return u32(timeout_ms)
	}
	left := i64(timeout_ms) - elapsed_ns / 1_000_000
	if left <= 0 {
		return none
	}
	return u32(left)
}
