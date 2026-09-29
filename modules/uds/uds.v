// uds — a minimal UDS (ISO 14229) diagnostic client riding on ISO-TP
// (modules/isotp). Implements the handful of services we need first:
// DiagnosticSessionControl (0x10), ReadDataByIdentifier (0x22) and
// TesterPresent (0x3E), plus proper positive/negative-response handling
// (including 0x78 "response pending", timed by the server's P2*). GUI-free and protocol-only.
//
// The Python SUT (sut/uds_server.py) is the verification oracle.
module uds

import isotp
import time

// Request service ids.
pub const sid_diagnostic_session_control = u8(0x10)
pub const sid_ecu_reset = u8(0x11)
pub const sid_read_dtc_information = u8(0x19)
pub const sid_read_data_by_identifier = u8(0x22)
pub const sid_security_access = u8(0x27)
pub const sid_write_data_by_identifier = u8(0x2E)
pub const sid_tester_present = u8(0x3E)

const positive_response_offset = u8(0x40)
const negative_response_sid = u8(0x7F)
const nrc_response_pending = u8(0x78)

// Client is a UDS tester over one ISO-TP channel (any platform backend).
//
// Timing (ISO 14229-2): the first answer is awaited for `timeout_ms` — the client's P2, generous
// by default because the carrier may be a USB or network adapter whose own latency dwarfs the
// server's 50 ms; after each responsePending (0x78) the next is awaited for the server's P2*
// plus `margin_ms`. P2 and P2* bound the START of an answer, but a carrier returns a PDU only
// once it is reassembled, so the margin covers the transfer as well as the latency — a large
// multi-frame answer begun just inside P2* on a slow bus still arrives. Both server values arrive in the 0x10 answer and are adopted there; the
// adoption only ever LOOSENS `timeout_ms`. However often the server says pending, and whatever P2*
// it announces, one request is bounded by `pending_budget_ms` from its send.
pub struct Client {
mut:
	ch isotp.Channel
pub mut:
	timeout_ms        int = 1000
	p2_star_ms        int = default_p2_star_ms
	margin_ms         int = 1000
	pending_budget_ms int = 120_000
}

// default_p2_star_ms is ISO 14229-2's default P2*server, used until a 0x10 answer names one.
pub const default_p2_star_ms = 5000

pub fn new_client(ch isotp.Channel) Client {
	return Client{
		ch: ch
	}
}

// NegativeResponse is returned (as an IError) when the ECU replies 0x7F.
pub struct NegativeResponse {
pub:
	sid u8 // the rejected service id
	nrc u8 // negative response code
}

pub fn (e NegativeResponse) msg() string {
	return 'UDS negative response: service 0x${e.sid:02X} NRC 0x${e.nrc:02X} (${nrc_name(e.nrc)})'
}

pub fn (e NegativeResponse) code() int {
	return int(e.nrc)
}

// Answer is what a received PDU is to the request in flight.
pub enum Answer {
	positive // its positive response
	negative // its negative response
	pending   // responsePending (0x78): the server is still working on it
	stale     // not an answer to it — a late or duplicated answer to an earlier request
	malformed // no response at all: empty, or a negative response without its NRC
}

// answer_to classifies `resp` against `req`. A response names the request it answers — the SID a
// negative response echoes, and the sub-function or identifier a positive one echoes — and one
// that names another is STALE: on a real bus an answer can arrive twice (a CAN frame retransmitted
// after an error at its end is received again by a node that had already accepted it), and taken
// as the next request's answer it would answer the wrong question.
//
// The three verdicts that are not an answer are kept apart: STALE is a complete response to some
// other request; MALFORMED is no valid response at all — empty, a negative response that is not
// exactly `7F <sid> <nrc>`, or a positive one too short for the echo its own request asks for.
// The echo asked for is only what the request carries (0x2C's clear-all has no identifier to
// echo), so a well-formed short request is answered by a well-formed short response.
pub fn answer_to(req []u8, resp []u8) Answer {
	if req.len == 0 {
		return .stale
	}
	if resp.len == 0 {
		return .malformed
	}
	if resp[0] == negative_response_sid {
		if resp.len != 3 {
			return .malformed
		}
		if resp[1] != req[0] {
			return .stale
		}
		return if resp[2] == nrc_response_pending { Answer.pending } else { Answer.negative }
	}
	if resp[0] != req[0] + positive_response_offset {
		return .stale
	}
	n, subfn := echo_of(req[0])
	echo := if n < req.len { n } else { req.len }
	if resp.len < echo {
		return .malformed
	}
	for i in 1 .. echo {
		// a sub-function is echoed without its suppress-positive-response bit; the bit itself is
		// tolerated (the in-process server echoes it)
		if resp[i] != req[i] && !(i == 1 && subfn && resp[i] == req[i] & 0x7F) {
			return .stale
		}
	}
	return .positive
}

// echo_of: how many leading bytes of a request its positive response echoes, SID included, and
// whether the second is a sub-function — a sub-function, a data identifier (a multi-DID read
// echoes its first one first), a sub-function and a routine identifier, a block sequence counter.
fn echo_of(sid u8) (int, bool) {
	return match sid {
		0x10, 0x11, 0x19, 0x27, 0x28, 0x29, 0x3E, 0x83, 0x85, 0x87 { 2, true }
		0x2C, 0x31 { 4, true }
		0x36 { 2, false }
		0x22, 0x24, 0x2E, 0x2F { 3, false }
		else { 1, false }
	}
}

// raw sends a service request and returns its validated positive-response PDU (including the
// response SID byte). A negative response becomes a NegativeResponse error; responsePending
// extends the wait by P2*; a PDU that answers another request is discarded and the wait goes on.
// What is already queued when the request goes out cannot be its answer, so it is drained first —
// the one defence against a duplicated answer to an IDENTICAL earlier request, which no echo can
// tell apart. On the CAN carriers (`recv(0)` polls what has arrived); DoIP's `recv(0)` reads
// nothing yet (#358), and TCP does not duplicate — only a late answer after a timeout remains. A 0x10 answer's timing is adopted here, whichever caller sent it.
pub fn (mut c Client) raw(req []u8) ![]u8 {
	if req.len == 0 {
		return error('empty UDS request')
	}
	mut discarded := 0
	for {
		c.ch.recv(0) or { break }
		discarded++
		if discarded >= max_drain {
			// the channel was never seen empty, so what follows could still be an old answer
			return error('UDS: ${discarded} PDUs already queued before 0x${req[0]:02X} — the channel is not quiet')
		}
	}
	c.ch.send(req)!
	sw := time.new_stopwatch()
	mut deadline := if c.timeout_ms < c.pending_budget_ms { i64(c.timeout_ms) } else { i64(c.pending_budget_ms) }
	mut pending := false
	for {
		left := deadline - sw.elapsed().milliseconds()
		if left <= 0 {
			if pending {
				return error('UDS: 0x${req[0]:02X} still pending after ${sw.elapsed().milliseconds()} ms')
			}
			return error(no_answer(req, discarded))
		}
		resp := c.ch.recv(int(left)) or {
			if pending {
				return error('UDS: 0x${req[0]:02X} still pending after ${sw.elapsed().milliseconds()} ms (${err.msg()})')
			}
			if discarded > 0 {
				return error('${err.msg()} (${no_answer(req, discarded)})')
			}
			return err
		}
		match answer_to(req, resp) {
			.positive {
				if req[0] == sid_diagnostic_session_control {
					c.adopt(resp)
				}
				return resp
			}
			.malformed {
				return error('malformed UDS response to 0x${req[0]:02X}: ${resp.hex()}')
			}
			.negative {
				return NegativeResponse{
					sid: resp[1]
					nrc: resp[2]
				}
			}
			.pending {
				// P2* from now, but never past the request's total allowance from the send — an
				// announced P2* of hours must not become one wait of hours
				pending = true
				now := sw.elapsed().milliseconds()
				wait := i64(c.p2_star_ms) + c.margin_ms
				deadline = if now + wait < c.pending_budget_ms { now + wait } else { i64(c.pending_budget_ms) }
			}
			.stale {
				discarded++
			}
		}
	}
	return error('unreachable')
}

// max_drain bounds the pre-send drain: a peer flooding the response id must not hold a request
// back forever — and a channel not seen empty is refused rather than trusted.
const max_drain = 64

fn no_answer(req []u8, discarded int) string {
	mut m := 'UDS: no answer to 0x${req[0]:02X}'
	if discarded > 0 {
		m += '; ${discarded} response(s) to other requests discarded'
	}
	return m
}

// SessionTiming is what a DiagnosticSessionControl answer says of the server's timing.
pub struct SessionTiming {
pub:
	p2_ms      int // P2server: until the first answer
	p2_star_ms int // P2*server: until the next answer after a responsePending
}

// session_timing reads the timing record of a 0x10 positive response
// (50 <session> <P2 hi> <P2 lo> <P2* hi> <P2* lo>; P2 in ms, P2* in units of 10 ms).
pub fn session_timing(resp []u8) ?SessionTiming {
	if resp.len < 6 || resp[0] != sid_diagnostic_session_control + positive_response_offset {
		return none
	}
	return SessionTiming{
		p2_ms:      int(u16(resp[2]) << 8 | u16(resp[3]))
		p2_star_ms: int(u16(resp[4]) << 8 | u16(resp[5])) * 10
	}
}

// DidWrite is a decoded WriteDataByIdentifier request: which identifier it targets and the
// value it carries. `data` may be EMPTY — `2E F1 90` with no payload is a well-formed request
// that clears the record, and a caller checking the length before the identifier would not
// see it at all.
pub struct DidWrite {
pub:
	did  u16
	data []u8
}

// written_did decodes a 0x2E request. Lives here rather than in a caller because reading UDS
// off the wire is this module's job: a second interpretation elsewhere is a second thing to
// get wrong, and the length-before-identifier version already was.
pub fn written_did(req []u8) ?DidWrite {
	if req.len < 3 || req[0] != sid_write_data_by_identifier {
		return none
	}
	return DidWrite{
		did:  u16(req[1]) << 8 | u16(req[2])
		data: req[3..].clone()
	}
}

// read_data_by_identifier (0x22) returns just the data record for `did`.
pub fn (mut c Client) read_data_by_identifier(did u16) ![]u8 {
	resp := c.raw([sid_read_data_by_identifier, u8(did >> 8), u8(did)])!
	// 0x62 <did_hi> <did_lo> <data...>
	if resp.len < 3 {
		return error('RDBI response too short (${resp.len} bytes)')
	}
	echo_did := (u16(resp[1]) << 8) | u16(resp[2])
	if echo_did != did {
		return error('RDBI echoed DID 0x${echo_did:04X}, expected 0x${did:04X}')
	}
	return resp[3..].clone()
}

// diagnostic_session (0x10) switches session and returns the session parameter
// record (e.g. P2 timings), if any.
pub fn (mut c Client) diagnostic_session(session u8) ![]u8 {
	resp := c.raw([sid_diagnostic_session_control, session])!
	return resp[1..].clone()
}

// adopt takes a 0x10 answer's timing: its P2* as given, its P2 only where it loosens `timeout_ms`
// (a 50 ms server P2 is below what a USB or network carrier adds).
fn (mut c Client) adopt(resp []u8) {
	t := session_timing(resp) or { return }
	if t.p2_star_ms > 0 {
		c.p2_star_ms = t.p2_star_ms
	}
	if t.p2_ms + c.margin_ms > c.timeout_ms {
		c.timeout_ms = t.p2_ms + c.margin_ms
	}
}

// tester_present (0x3E sub 0x00) keeps the session alive.
pub fn (mut c Client) tester_present() ! {
	c.raw([sid_tester_present, u8(0x00)])!
}

// write_data_by_identifier (0x2E) writes a data record to a DID.
pub fn (mut c Client) write_data_by_identifier(did u16, data []u8) ! {
	mut req := [sid_write_data_by_identifier, u8(did >> 8), u8(did)]
	req << data
	c.raw(req)! // positive response is 0x6E <did_hi> <did_lo>
}

// security_request_seed (0x27, odd sub-function) asks for the seed for `level`.
pub fn (mut c Client) security_request_seed(level u8) ![]u8 {
	resp := c.raw([sid_security_access, level])!
	// 0x67 <level> <seed...>
	if resp.len < 2 {
		return error('security seed response too short')
	}
	return resp[2..].clone()
}

// security_send_key (0x27, even sub-function = seed level + 1) sends the computed key.
pub fn (mut c Client) security_send_key(level u8, key []u8) ! {
	mut req := [sid_security_access, level]
	req << key
	c.raw(req)! // positive response is 0x67 <level>
}

// read_dtc_by_status_mask (0x19 sub 0x02 reportDTCByStatusMask) returns the DTC
// record (status-availability mask byte followed by DTC(3)+status(1) tuples).
pub fn (mut c Client) read_dtc_by_status_mask(mask u8) ![]u8 {
	resp := c.raw([sid_read_dtc_information, 0x02, mask])!
	// 0x59 0x02 <data...>
	if resp.len < 2 {
		return error('readDTC response too short')
	}
	return resp[2..].clone()
}

// security_key derives the key from a seed for the SIMULATED server's demo
// algorithm (key[i] = seed[i] XOR 0xFF). Real OEM algorithms differ — this is the
// shared secret between modules/uds' Server and a test that wants to unlock it.
pub fn security_key(seed []u8) []u8 {
	return seed.map(it ^ u8(0xFF))
}

// nrc_name maps a negative response code to its ISO 14229-1 name.
pub fn nrc_name(nrc u8) string {
	return match nrc {
		0x10 { 'generalReject' }
		0x11 { 'serviceNotSupported' }
		0x12 { 'subFunctionNotSupported' }
		0x13 { 'incorrectMessageLengthOrInvalidFormat' }
		0x14 { 'responseTooLong' }
		0x21 { 'busyRepeatRequest' }
		0x22 { 'conditionsNotCorrect' }
		0x24 { 'requestSequenceError' }
		0x25 { 'noResponseFromSubnetComponent' }
		0x26 { 'failurePreventsExecutionOfRequestedAction' }
		0x31 { 'requestOutOfRange' }
		0x33 { 'securityAccessDenied' }
		0x34 { 'authenticationRequired' }
		0x35 { 'invalidKey' }
		0x36 { 'exceededNumberOfAttempts' }
		0x37 { 'requiredTimeDelayNotExpired' }
		0x38 { 'secureDataTransmissionRequired' }
		0x39 { 'secureDataTransmissionNotAllowed' }
		0x3A { 'secureDataVerificationFailed' }
		0x3B...0x4F { 'reservedByExtendedDataLinkSecurityDocument' }
		0x50 { 'certificateVerificationFailedInvalidTimePeriod' }
		0x51 { 'certificateVerificationFailedInvalidSignature' }
		0x52 { 'certificateVerificationFailedInvalidChainOfTrust' }
		0x53 { 'certificateVerificationFailedInvalidType' }
		0x54 { 'certificateVerificationFailedInvalidFormat' }
		0x55 { 'certificateVerificationFailedInvalidContent' }
		0x56 { 'certificateVerificationFailedInvalidScope' }
		0x57 { 'certificateVerificationFailedInvalidCertificate' }
		0x58 { 'ownershipVerificationFailed' }
		0x59 { 'challengeCalculationFailed' }
		0x5A { 'settingAccessRightsFailed' }
		0x5B { 'sessionKeyCreationDerivationFailed' }
		0x5C { 'configurationDataUsageFailed' }
		0x5D { 'deAuthenticationFailed' }
		0x70 { 'uploadDownloadNotAccepted' }
		0x71 { 'transferDataSuspended' }
		0x72 { 'generalProgrammingFailure' }
		0x73 { 'wrongBlockSequenceCounter' }
		0x78 { 'requestCorrectlyReceived-ResponsePending' }
		0x7E { 'subFunctionNotSupportedInActiveSession' }
		0x7F { 'serviceNotSupportedInActiveSession' }
		0x81 { 'rpmTooHigh' }
		0x82 { 'rpmTooLow' }
		0x83 { 'engineIsRunning' }
		0x84 { 'engineIsNotRunning' }
		0x85 { 'engineRunTimeTooLow' }
		0x86 { 'temperatureTooHigh' }
		0x87 { 'temperatureTooLow' }
		0x88 { 'vehicleSpeedTooHigh' }
		0x89 { 'vehicleSpeedTooLow' }
		0x8A { 'throttlePedalTooHigh' }
		0x8B { 'throttlePedalTooLow' }
		0x8C { 'transmissionRangeNotInNeutral' }
		0x8D { 'transmissionRangeNotInGear' }
		0x8F { 'brakeSwitchesNotClosed' }
		0x90 { 'shifterLeverNotInPark' }
		0x91 { 'torqueConverterClutchLocked' }
		0x92 { 'voltageTooHigh' }
		0x93 { 'voltageTooLow' }
		0x94 { 'resourceTemporarilyNotAvailable' }
		else { 'unknown' }
	}
}
