module script

import blobly.doip
import blobly.uds

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

// a connection retargeted to a node the gateway does not route is negatively acknowledged by the
// entity: alive, and replacing it would lose what was unlocked on the gateway over it
fn test_a_negative_acknowledgement_is_not_a_dead_connection() {
	assert !probe_says_dead(uds.CarrierFailed{
		text: '${doip.nack_note} (0x06)'
	})
	assert probe_says_dead(uds.CarrierFailed{
		text: 'DoIP connection lost: connection reset'
	})
}

fn test_a_transport_failure_is_a_dead_connection() {
	assert probe_says_dead(error('net: op timed out'))
}
