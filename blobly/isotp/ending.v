module isotp

import blobly.transport

// Ending is how a send or a receive on a software channel failed, for a host that answers each
// kind its own way (a raw ISO-TP channel a script opened: the Lua isotp.open, bb_isotp_*).
pub enum Ending {
	// nothing whole within the wait: a receive's deadline passed in silence, or with a transfer
	// begun and kept for the next receive (stall_note); a send's receiver sent no Flow Control
	// within N_Bs, or not within the transfer's allowance (exhausted_note)
	waited_out
	// nothing went out: a message the channel cannot carry (empty, past max_pdu), or a send on a
	// listen-only wire
	refused
	// stop_requested ended it
	abandoned
	// the carrier: the bus, or the transfer (a frame lost, N_Cr passed mid-transfer, the receiver
	// reporting overflow or waiting past N_WFTmax, a frame that is not ISO-TP)
	failed
}

// ending_of is how `err`, the failure of a send (`sending`) or a receive on `c`, ended. A receive
// that cannot answer a First Frame's Flow Control on a listen-only wire failed: the refusal is the
// Flow Control's, and the message says so.
pub fn (c &SoftChannel) ending_of(err IError, sending bool) Ending {
	m := err.msg()
	// prefixes: a receive that skipped an orphan Flow Control says so after the note (orphan_note)
	if m.starts_with(abandoned_note) || m.starts_with(abandoned_recv_note) {
		return .abandoned
	}
	if m.starts_with('timeout') || m == stall_note || m == exhausted_note(c.total_wait_ms) {
		return .waited_out
	}
	if err is transport.NotWritten || (sending && transport.wire_policy(c.iface).silent) {
		return .refused
	}
	return .failed
}
