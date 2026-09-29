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
// plus `margin_ms`. Both server values arrive in the 0x10 answer and are adopted there; the
// adoption only ever LOOSENS `timeout_ms`. However often the server says pending, one request is
// bounded by `pending_budget_ms` in all.
pub struct Client {
mut:
	ch isotp.Channel
pub mut:
	timeout_ms        int = 1000
	p2_star_ms        int = default_p2_star_ms
	margin_ms         int = 200
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
	pending  // responsePending (0x78): the server is still working on it
	stale    // not an answer to it — a late or duplicated answer to an earlier request
}

// answer_to classifies `resp` against `req`. A response names the request it answers — the SID a
// negative response echoes, and the sub-function or identifier a positive one echoes — and one
// that names another is STALE: on a real bus an answer can arrive twice (a CAN frame retransmitted
// after an error at its end is received again by a node that had already accepted it), and taken
// as the next request's answer it would answer the wrong question.
pub fn answer_to(req []u8, resp []u8) Answer {
	if req.len == 0 || resp.len == 0 {
		return .stale
	}
	if resp[0] == negative_response_sid {
		if resp.len < 3 || resp[1] != req[0] {
			return .stale
		}
		return if resp[2] == nrc_response_pending { Answer.pending } else { Answer.negative }
	}
	if resp[0] != req[0] + positive_response_offset {
		return .stale
	}
	// what the positive response echoes: a sub-function (without its suppress-positive-response
	// bit), a data identifier (a multi-DID read echoes its first one first), a sub-function and a
	// routine identifier, a block sequence counter — or nothing beyond the SID
	subfn := req[0] in [u8(0x10), 0x11, 0x19, 0x27, 0x28, 0x3E, 0x85, 0x31]
	echoed := match req[0] {
		0x10, 0x11, 0x19, 0x27, 0x28, 0x3E, 0x85, 0x36 { 2 }
		0x22, 0x2E { 3 }
		0x31 { 4 }
		else { 1 }
	}
	if resp.len < echoed {
		return .stale
	}
	for i in 1 .. echoed {
		if i >= req.len {
			break // a malformed request has nothing more to echo
		}
		want := if i == 1 && subfn { req[1] & 0x7F } else { req[i] }
		if resp[i] != want {
			return .stale
		}
	}
	return .positive
}

// raw sends a service request and returns its validated positive-response PDU (including the
// response SID byte). A negative response becomes a NegativeResponse error; responsePending
// extends the wait by P2*; a PDU that answers another request is discarded and the wait goes on.
pub fn (mut c Client) raw(req []u8) ![]u8 {
	if req.len == 0 {
		return error('empty UDS request')
	}
	c.ch.send(req)!
	sw := time.new_stopwatch()
	mut deadline := i64(c.timeout_ms)
	mut pending_from := i64(-1)
	mut discarded := 0
	for {
		left := deadline - sw.elapsed().milliseconds()
		if left <= 0 {
			return error(no_answer(req, discarded))
		}
		resp := c.ch.recv(int(left)) or {
			if discarded > 0 {
				return error('${err.msg()} (${no_answer(req, discarded)})')
			}
			return err
		}
		match answer_to(req, resp) {
			.positive {
				return resp
			}
			.negative {
				return NegativeResponse{
					sid: resp[1]
					nrc: resp[2]
				}
			}
			.pending {
				now := sw.elapsed().milliseconds()
				if pending_from < 0 {
					pending_from = now
				} else if now - pending_from >= c.pending_budget_ms {
					return error('UDS: 0x${req[0]:02X} still pending after ${c.pending_budget_ms} ms')
				}
				deadline = now + c.p2_star_ms + c.margin_ms
			}
			.stale {
				discarded++
			}
		}
	}
	return error('unreachable')
}

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
// The server's timing is adopted: its P2* as given, its P2 only where it loosens `timeout_ms`.
pub fn (mut c Client) diagnostic_session(session u8) ![]u8 {
	resp := c.raw([sid_diagnostic_session_control, session])!
	if t := session_timing(resp) {
		if t.p2_star_ms > 0 {
			c.p2_star_ms = t.p2_star_ms
		}
		if t.p2_ms + c.margin_ms > c.timeout_ms {
			c.timeout_ms = t.p2_ms + c.margin_ms
		}
	}
	return resp[1..].clone()
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
		else { 'unknown' }
	}
}
