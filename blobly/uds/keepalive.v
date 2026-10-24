module uds

// keepalive.v — a session kept alive between a script's requests: TesterPresent with the positive
// response suppressed (3E 80) every period while the client holds a non-default session, from a
// thread of its own and never inside an exchange (the caller's lock, which it holds around every
// use of the client, is taken for each one). The rules are the Diagnostics panel's
// (cmd/blobly_net/diaghold): only a session a 0x10 answer established and not the default one is
// kept; any request restarts the period, since any request restarts S3; one keep-alive is BOUNDED
// (keepalive_wait_ms for the first answer and as the pending budget), so a 0x78 cannot hold the
// client for its pending budget — a 0x78 the window ran out on is the keep-alive failing; a
// refusal forgets the session, so nothing is sent again until a 0x10 is answered.
import sync
import time

// keepalive_wait_ms is how long a keep-alive listens for a refusal before its quiet is success.
pub const keepalive_wait_ms = 200

// keepalive_min_ms / keepalive_max_ms bound a keep-alive's period: above the window one takes, and
// at most a minute (ISO 14229-2's default S3server is 5 s).
pub const keepalive_min_ms = 250
pub const keepalive_max_ms = 60_000

// KeepAliveOutcome is what one keep-alive came to.
pub enum KeepAliveOutcome {
	ok      // the quiet of a suppressed answer, or a positive one
	refused // a negative response: the session is no longer known, and not kept until a 0x10
	pending // 0x78 and nothing more within the window
	failed  // the carrier failed, or nothing could be sent
}

// keepalive_outcome reads one keep-alive's error: none is ok.
pub fn keepalive_outcome(err ?IError) KeepAliveOutcome {
	e := err or { return .ok }
	if e is NegativeResponse {
		return .refused
	}
	return if e is PendingExpired { KeepAliveOutcome.pending } else { KeepAliveOutcome.failed }
}

// keepalive_due: a keep-alive goes out now — the client holds a session a 0x10 answer established
// that is not the default one, and nothing has gone to the ECU for `period_ms`.
pub fn keepalive_due(session u8, last_tx_ns u64, now_ns u64, period_ms int) bool {
	if session == 0 || session == default_session {
		return false
	}
	return now_ns >= last_tx_ns + u64(period_ms) * 1_000_000
}

// keep_alive_once sends one bounded 3E 80, its lock held by the caller: none when it went well,
// else its error (keepalive_outcome reads it). keepalive_wait_ms bounds its first answer and, a
// 0x78 come, the whole exchange; nothing of it is the client's `last` exchange, its count of
// requests or its exchange hook, which belong to the caller's requests, and none of the caller's
// waits is touched. A refusal forgets the session (ConnState.forget).
pub fn (mut c Client) keep_alive_once() ?IError {
	c.exchange_once([sid_tester_present, suppress_positive], true, keepalive_wait_ms) or {
		if keepalive_outcome(err) == .refused {
			c.state.forget(.session)
		}
		return err
	}
	return none
}

// on_heap is the client at an address of its own, which a keep-alive's thread can hold.
pub fn (c Client) on_heap() &Client {
	return &Client{
		...c
	}
}

// KeepAliveHost is how a keep-alive reaches its client: `acquire` takes the caller's lock and
// gives the client (none: nothing to keep alive now — a lost connection, a closing handle; the lock
// is then not held), `release` lets the lock go, and `failed`, when set, is told of a keep-alive
// that failed, the lock still held (a binding marks a lost connection).
pub struct KeepAliveHost {
pub:
	acquire fn () ?&Client @[required]
	release fn () @[required]
	failed  fn (IError) = unsafe { nil }
}

// KeepAliveStatus is a keep-alive as it is now: how many it sent, how many failed and the last
// failure's words, and whether its thread runs.
pub struct KeepAliveStatus {
pub:
	period_ms int
	sent      u64
	failures  u64
	failure   string
	running   bool
}

@[heap]
pub struct KeepAlive {
	period_ms int
	host      KeepAliveHost
mut:
	mu       sync.Mutex
	asked    bool
	out      bool
	sent     u64
	failures u64
	failure  string
	said     u64 // failures already taken by take_failure
}

// keep_alive starts a keep-alive every `period_ms` on the client `host` reaches.
pub fn keep_alive(period_ms int, host KeepAliveHost) !&KeepAlive {
	if period_ms < keepalive_min_ms || period_ms > keepalive_max_ms {
		return error('a keep-alive period of ${period_ms} ms: give ${keepalive_min_ms} .. ${keepalive_max_ms}')
	}
	mut k := &KeepAlive{
		period_ms: period_ms
		host:      host
		out:       true
	}
	spawn k.run()
	return k
}

fn (mut k KeepAlive) run() {
	defer {
		k.mu.lock()
		k.out = false
		k.mu.unlock()
	}
	for !k.is_asked() {
		time.sleep(20 * time.millisecond)
		mut c := k.host.acquire() or { continue }
		if k.is_asked() {
			k.host.release()
			return
		}
		if !keepalive_due(c.state.session, c.last_tx_ns, time.sys_mono_now(), k.period_ms) {
			k.host.release()
			continue
		}
		failure := c.keep_alive_once()
		outcome := keepalive_outcome(failure)
		why := if e := failure { e.msg() } else { '' }
		// an exchange the client's own stop ended is no failure: its handle is closing
		stopped := c.stopping()
		if e := failure {
			if !stopped && k.host.failed != unsafe { nil } {
				k.host.failed(e)
			}
		}
		k.host.release()
		k.mu.lock()
		if outcome == .ok {
			k.sent++
		} else if !stopped {
			k.failures++
			k.failure = match outcome {
				.refused { 'keep-alive 3E 80 refused (${why}); not sent again until a session is answered' }
				.pending { 'keep-alive 3E 80 answered 0x78 (responsePending) and nothing within ${keepalive_wait_ms} ms' }
				else { 'keep-alive 3E 80: ${why}' }
			}
		}
		k.mu.unlock()
	}
}

fn (mut k KeepAlive) is_asked() bool {
	k.mu.lock()
	defer {
		k.mu.unlock()
	}
	return k.asked
}

// status is the keep-alive as it is now.
pub fn (mut k KeepAlive) status() KeepAliveStatus {
	k.mu.lock()
	defer {
		k.mu.unlock()
	}
	return KeepAliveStatus{
		period_ms: k.period_ms
		sent:      k.sent
		failures:  k.failures
		failure:   k.failure
		running:   k.out && !k.asked
	}
}

// is_out is whether its thread has ended.
pub fn (mut k KeepAlive) is_out() bool {
	k.mu.lock()
	defer {
		k.mu.unlock()
	}
	return !k.out
}

// take_failure is the last failure when one happened since the previous take: what a binding says
// at the client's next call, so a failure is reported once and never swallowed.
pub fn (mut k KeepAlive) take_failure() ?string {
	k.mu.lock()
	defer {
		k.mu.unlock()
	}
	if k.failures == k.said {
		return none
	}
	n := k.failures - k.said
	k.said = k.failures
	return if n > 1 { '${k.failure} (${n} keep-alives failed)' } else { k.failure }
}

// stop ends the keep-alive: true once its thread is out, within a keep-alive's window and the
// caller's lock — which the caller must not hold, or the thread cannot leave a pending acquire.
pub fn (mut k KeepAlive) stop() bool {
	k.mu.lock()
	k.asked = true
	k.mu.unlock()
	until := time.sys_mono_now() + u64(keepalive_wait_ms + 2000) * 1_000_000
	for time.sys_mono_now() < until {
		k.mu.lock()
		out := k.out
		k.mu.unlock()
		if !out {
			return true
		}
		time.sleep(2 * time.millisecond)
	}
	return false
}
