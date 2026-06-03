// uds — a minimal UDS (ISO 14229) diagnostic client riding on ISO-TP
// (modules/isotp). Implements the handful of services we need first:
// DiagnosticSessionControl (0x10), ReadDataByIdentifier (0x22) and
// TesterPresent (0x3E), plus proper positive/negative-response handling
// (including 0x78 "response pending" retries). GUI-free and protocol-only.
//
// The Python SUT (sut/uds_server.py) is the verification oracle.
module uds

import isotp

// Request service ids.
pub const sid_diagnostic_session_control = u8(0x10)
pub const sid_ecu_reset = u8(0x11)
pub const sid_read_data_by_identifier = u8(0x22)
pub const sid_tester_present = u8(0x3E)

const positive_response_offset = u8(0x40)
const negative_response_sid = u8(0x7F)
const nrc_response_pending = u8(0x78)

// Client is a UDS tester over one ISO-TP channel (any platform backend).
pub struct Client {
mut:
	ch isotp.Channel
pub mut:
	timeout_ms int = 1000
}

pub fn new_client(ch isotp.Channel) Client {
	return Client{
		ch:         ch
		timeout_ms: 1000
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

// raw sends a service request and returns the validated positive-response PDU
// (including the response SID byte). Negative responses become a NegativeResponse
// error; 0x78 "response pending" is retried transparently.
pub fn (mut c Client) raw(req []u8) ![]u8 {
	if req.len == 0 {
		return error('empty UDS request')
	}
	c.ch.send(req)!
	for _ in 0 .. 6 {
		resp := c.ch.recv(c.timeout_ms)!
		if resp.len == 0 {
			return error('empty UDS response')
		}
		if resp[0] == negative_response_sid {
			nrc := if resp.len > 2 { resp[2] } else { u8(0) }
			if nrc == nrc_response_pending {
				continue // ECU is still working — wait for the real response
			}
			sid := if resp.len > 1 { resp[1] } else { u8(0) }
			return NegativeResponse{
				sid: sid
				nrc: nrc
			}
		}
		expected := req[0] + positive_response_offset
		if resp[0] != expected {
			return error('unexpected response SID 0x${resp[0]:02X} (wanted 0x${expected:02X})')
		}
		return resp
	}
	return error('UDS: too many "response pending" replies')
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

// tester_present (0x3E sub 0x00) keeps the session alive.
pub fn (mut c Client) tester_present() ! {
	c.raw([sid_tester_present, u8(0x00)])!
}

// nrc_name maps the common negative response codes to readable names.
pub fn nrc_name(nrc u8) string {
	return match nrc {
		0x10 { 'generalReject' }
		0x11 { 'serviceNotSupported' }
		0x12 { 'subFunctionNotSupported' }
		0x13 { 'incorrectMessageLengthOrInvalidFormat' }
		0x22 { 'conditionsNotCorrect' }
		0x31 { 'requestOutOfRange' }
		0x33 { 'securityAccessDenied' }
		0x35 { 'invalidKey' }
		0x78 { 'requestCorrectlyReceived-ResponsePending' }
		0x7F { 'serviceNotSupportedInActiveSession' }
		else { 'unknown' }
	}
}
