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

// default_timing is a new client's: ISO 14229-2's P2* until a 0x10 answer names one, the rest
// generous for a carrier's own latency (see Client).
pub const default_timing = Timing{
	timeout_ms:        1000
	p2_star_ms:        default_p2_star_ms
	margin_ms:         1000
	pending_budget_ms: 120_000
}

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

// Waits is what a host states of a client's timing: the waits it gives, the others left as they are.
pub struct Waits {
pub:
	timeout_ms        ?int
	p2_star_ms        ?int
	margin_ms         ?int
	pending_budget_ms ?int
}

// state takes the waits `w` gives from the client's next request on, and as what it starts again
// from on another ECU (another_ecu): a wait not given keeps what it is, adopted or stated. Refused,
// changing nothing, when one is out of range (timing_refusal). A later 0x10 answer still adopts its
// P2*, and lengthens `timeout_ms` where its P2 needs more.
pub fn (mut c Client) state(w Waits) ! {
	live := Timing{
		timeout_ms:        w.timeout_ms or { c.timeout_ms }
		p2_star_ms:        w.p2_star_ms or { c.p2_star_ms }
		margin_ms:         w.margin_ms or { c.margin_ms }
		pending_budget_ms: w.pending_budget_ms or { c.pending_budget_ms }
	}
	if why := timing_refusal(live) {
		return error(why)
	}
	c.stated = Timing{
		timeout_ms:        w.timeout_ms or { c.stated.timeout_ms }
		p2_star_ms:        w.p2_star_ms or { c.stated.p2_star_ms }
		margin_ms:         w.margin_ms or { c.stated.margin_ms }
		pending_budget_ms: w.pending_budget_ms or { c.stated.pending_budget_ms }
	}
	c.apply(live)
}

fn (mut c Client) apply(t Timing) {
	c.timeout_ms = t.timeout_ms
	c.p2_star_ms = t.p2_star_ms
	c.margin_ms = t.margin_ms
	c.pending_budget_ms = t.pending_budget_ms
}

// carry_from takes into a client on a new connection to the same ECU what the old one knew of it:
// its waits — P2* only where it loosens this one's (loosen_p2_star: the session that announced it
// may have ended with the old connection) —, the snapshot DID and extended record sizes, and what
// the host stated.
pub fn (mut c Client) carry_from(from &Client) {
	c.timeout_ms = from.timeout_ms
	c.loosen_p2_star(from.p2_star_ms)
	c.margin_ms = from.margin_ms
	c.pending_budget_ms = from.pending_budget_ms
	c.did_lens = from.did_lens.clone()
	c.ext_lens = from.ext_lens.clone()
	c.stated = from.stated
	c.stated_did_lens = from.stated_did_lens.clone()
}

// another_ecu: the client now addresses another ECU on its carrier (a DoIP retarget), so what it
// learned of the one before — a 0x10 answer's timing, the snapshot DID sizes it read — is that
// ECU's: it starts again from what the host stated.
pub fn (mut c Client) another_ecu() {
	c.apply(c.stated)
	c.did_lens = c.stated_did_lens.clone()
	c.state = ConnState{} // its session and security are that ECU's
}
