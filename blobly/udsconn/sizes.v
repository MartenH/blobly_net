module udsconn

import blobly.doip
import blobly.isotp

// the largest a snapshot DID's value and an extended record can be in one answer: the header (59
// sub DTC status, 6 bytes), then a record's number and DID count and the DID (4 more), or the
// record's number (1)
pub const snapshot_did_overhead = 10
pub const ext_record_overhead = 7

// max_answer is the longest answer a connection's carrier brings: an ISO-TP PDU, or a DoIP
// diagnostic message's user data (its payload less the two logical addresses)
pub fn max_answer(over_doip bool) int {
	return if over_doip { int(doip.max_payload_len) - 4 } else { isotp.max_pdu }
}

// did_size_refusal says why a stated snapshot DID size cannot be one on the carrier, none if it can
pub fn did_size_refusal(n i64, over_doip bool) ?string {
	if n < 0 || n > max_answer(over_doip) - snapshot_did_overhead {
		return '${n} bytes is not a DID size'
	}
	return none
}

// ext_size_refusal says why a stated extended record size cannot be one on the carrier, none if it can
pub fn ext_size_refusal(n i64, over_doip bool) ?string {
	if n < 0 || n > max_answer(over_doip) - ext_record_overhead {
		return '${n} bytes is not a record size'
	}
	return none
}
