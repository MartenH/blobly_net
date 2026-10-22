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

// zero_poll_spent_code marks a zero-timeout look that stopped at its bound with filtered records
// still queued — the message stays 'timeout', so every caller reads it as one, and a caller that
// must know the queue is EMPTY (a boundary drain) reads the code.
pub const zero_poll_spent_code = 0x5A0

// look_was_spent says a receive's error is a zero-timeout look that stopped at its bound with
// records still queued, as opposed to an empty queue: a caller polling several buses looks again
// at once rather than sleeping.
pub fn look_was_spent(err IError) bool {
	return err.code() == zero_poll_spent_code
}

// look_over is the timeout a receive answers once look_again says stop: a spent zero-timeout look
// carries zero_poll_spent_code; a spent positive wait is an ordinary timeout.
fn look_over(timeout_ms int) IError {
	if timeout_ms == 0 {
		return error_with_code('timeout', zero_poll_spent_code)
	}
	return error('timeout')
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
