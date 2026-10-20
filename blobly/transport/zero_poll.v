module transport

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
