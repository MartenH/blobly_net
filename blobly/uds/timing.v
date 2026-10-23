module uds

// Timing is what bounds a Client's requests (see Client): the first answer's wait, the server's
// P2* after each responsePending, the margin added to it, and one request's whole allowance from
// its send. What a host reads and states; one rule for every binding.
pub struct Timing {
pub:
	timeout_ms        int
	p2_star_ms        int
	margin_ms         int
	pending_budget_ms int
}

// max_timing_ms is the longest wait a host may state: an hour, so every request stays bounded.
pub const max_timing_ms = 3_600_000

// timing is the client's waits as they stand: a 0x10 answer has adopted its P2* and may have
// lengthened `timeout_ms` (adopt).
pub fn (c &Client) timing() Timing {
	return Timing{
		timeout_ms:        c.timeout_ms
		p2_star_ms:        c.p2_star_ms
		margin_ms:         c.margin_ms
		pending_budget_ms: c.pending_budget_ms
	}
}

// timing_refusal is why `t` cannot be stated, or none: the first answer's wait and the request's
// allowance from 1 ms, P2* and the margin from 0, each at most max_timing_ms.
pub fn timing_refusal(t Timing) ?string {
	for name, v in {
		'timeout_ms':        t.timeout_ms
		'pending_budget_ms': t.pending_budget_ms
	} {
		if v < 1 || v > max_timing_ms {
			return 'UDS timing: ${name} ${v} is not 1 .. ${max_timing_ms} ms'
		}
	}
	for name, v in {
		'p2_star_ms': t.p2_star_ms
		'margin_ms':  t.margin_ms
	} {
		if v < 0 || v > max_timing_ms {
			return 'UDS timing: ${name} ${v} is not 0 .. ${max_timing_ms} ms'
		}
	}
	return none
}

// set_timing states the client's waits from its next request on; refused, changing nothing, when
// one is out of range (timing_refusal). A later 0x10 answer still adopts its P2*, and lengthens
// `timeout_ms` where its P2 needs more.
pub fn (mut c Client) set_timing(t Timing) ! {
	if why := timing_refusal(t) {
		return error(why)
	}
	c.timeout_ms = t.timeout_ms
	c.p2_star_ms = t.p2_star_ms
	c.margin_ms = t.margin_ms
	c.pending_budget_ms = t.pending_budget_ms
}

// carry_timing takes `from`'s waits into a client on a new connection to the same ECU: the first
// answer's wait, the margin and the allowance as they were, P2* only where it loosens this one's
// (loosen_p2_star: the session that announced it may have ended with the old connection).
pub fn (mut c Client) carry_timing(from &Client) {
	c.timeout_ms = from.timeout_ms
	c.loosen_p2_star(from.p2_star_ms)
	c.margin_ms = from.margin_ms
	c.pending_budget_ms = from.pending_budget_ms
}
