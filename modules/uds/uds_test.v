module uds

import transport
import isotp

// MockChannel is an in-memory isotp.Channel: it records the last request and
// replays a queue of canned responses. Lets us unit-test the UDS protocol logic
// (response validation, negative responses, 0x78 pending retries) with no bus.
struct MockChannel {
pub:
	iface string = 'mock'
	tx_id u32
	rx_id u32
mut:
	last_req  []u8
	responses [][]u8
	idx       int
}

fn (mut m MockChannel) send(data []u8) ! {
	m.last_req = data.clone()
}

fn (mut m MockChannel) recv(timeout_ms int) ![]u8 {
	if m.idx >= m.responses.len {
		return error('timeout')
	}
	r := m.responses[m.idx]
	m.idx++
	return r
}

fn (mut m MockChannel) close() {}

fn (mut m MockChannel) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn client_with(responses [][]u8) (Client, &MockChannel) {
	mut m := &MockChannel{
		responses: responses
	}
	return new_client(m), m
}

fn test_read_data_by_identifier_ok() {
	mut c, m := client_with([[u8(0x62), 0xF1, 0x90, 0x41, 0x42, 0x43]])
	data := c.read_data_by_identifier(0xF190) or { panic(err) }
	assert data == [u8(0x41), 0x42, 0x43]
	// the request PDU must be 22 F1 90
	assert m.last_req == [u8(0x22), 0xF1, 0x90]
}

fn test_negative_response_surfaced() {
	mut c, _ := client_with([[u8(0x7F), 0x22, 0x31]])
	if _ := c.read_data_by_identifier(0xF190) {
		assert false, 'expected negative response'
	} else {
		// the IError is a NegativeResponse carrying the NRC
		assert err is NegativeResponse
		ne := err as NegativeResponse
		assert ne.sid == 0x22
		assert ne.nrc == 0x31
		assert err.code() == 0x31
	}
}

fn test_response_pending_is_retried() {
	// 0x78 (response pending) then the real positive response.
	mut c, _ := client_with([
		[u8(0x7F), 0x22, 0x78],
		[u8(0x7F), 0x22, 0x78],
		[u8(0x62), 0xF1, 0x90, 0xAA],
	])
	data := c.read_data_by_identifier(0xF190) or { panic(err) }
	assert data == [u8(0xAA)]
}

fn test_did_echo_mismatch_errors() {
	// server echoes the wrong DID (0xF191 instead of 0xF190)
	mut c, _ := client_with([[u8(0x62), 0xF1, 0x91, 0x00]])
	if _ := c.read_data_by_identifier(0xF190) {
		assert false, 'expected DID echo mismatch error'
	}
}

fn test_wrong_service_id_errors() {
	// positive response SID should be request+0x40; 0x99 is neither that nor 0x7F
	mut c, _ := client_with([[u8(0x99), 0x00]])
	if _ := c.diagnostic_session(0x01) {
		assert false, 'expected unexpected-SID error'
	}
}

fn test_session_and_tester_present() {
	mut c, _ := client_with([
		[u8(0x50), 0x01, 0x00, 0x32, 0x01, 0xF4], // session params
		[u8(0x7E), 0x00], // tester present ack
	])
	params := c.diagnostic_session(0x01) or { panic(err) }
	// returns everything after the 0x50 SID: echoed session + P2 timings
	assert params == [u8(0x01), 0x00, 0x32, 0x01, 0xF4]
	c.tester_present() or { panic(err) }
}

fn test_nrc_name() {
	assert nrc_name(0x31) == 'requestOutOfRange'
	assert nrc_name(0x11) == 'serviceNotSupported'
	assert nrc_name(0x78).contains('Pending')
}
