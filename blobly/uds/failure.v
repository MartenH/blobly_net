module uds

import blobly.isotp

// failure.v — what kind of failure a Client call ended in, for a caller that hands the error on
// to a host that cannot match V types (cmd/libblobly's typed errors): the kinds a tester acts on
// differently, read from the error types the exchange returns.

pub enum Failure {
	refused     // the request did not go out whole, or the call failed for a reason its text gives
	negative    // a NegativeResponse
	no_answer   // a NoAnswer: nothing answered within the wait
	pending     // a PendingExpired: responsePending (0x78), then nothing within P2*
	undecodable // an UndecodableAnswer: an answer arrived that cannot be read
	carrier     // a CarrierFailed: the bus, the ISO-TP channel or the connection failed
	abandoned   // ended by stop_requested (the client's, or its channel's)
}

// abandoned: an error is a stop's, the client's or its channel's — whatever context the channel
// appended to the note (the orphan Flow Controls it skipped).
fn abandoned(msg string) bool {
	return msg.starts_with(abandoned_note) || msg.starts_with(isotp.abandoned_note)
		|| msg.starts_with(isotp.abandoned_recv_note)
}

// failure_of is the kind of `err`, an error a Client call returned.
pub fn failure_of(err IError) Failure {
	if abandoned(err.msg()) {
		return .abandoned
	}
	if err is NegativeResponse {
		return .negative
	}
	if err is NoAnswer {
		return .no_answer
	}
	if err is PendingExpired {
		return .pending
	}
	if err is UndecodableAnswer {
		return .undecodable
	}
	if err is CarrierFailed {
		return .carrier
	}
	return .refused
}
