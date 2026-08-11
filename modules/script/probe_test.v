module script

import uds

// The liveness probe must not confuse "the ECU refused me" with "the ECU is gone". This is
// unreachable from a Lua suite — the simulated server answers 0x3E positively whatever the
// project says — so the decision is pinned here instead. It has regressed once already, when
// a cross-branch patch silently reverted the branch that made it.
fn test_a_negative_response_is_not_a_dead_connection() {
	nrc := uds.NegativeResponse{
		sid: 0x3E
		nrc: 0x11 // serviceNotSupported — a refusal, from a live ECU
	}
	assert !probe_says_dead(nrc)
}

fn test_a_transport_failure_is_a_dead_connection() {
	assert probe_says_dead(error('net: op timed out'))
}
