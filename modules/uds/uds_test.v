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
	waits     []int // the timeout each recv was given
	queued    int   // how many of `responses` were already queued before the request went out
}

fn (mut m MockChannel) send(data []u8) ! {
	m.last_req = data.clone()
}

fn (mut m MockChannel) recv(timeout_ms int) ![]u8 {
	if timeout_ms == 0 {
		// a drain: only what was queued before the send is there to take
		if m.idx < m.queued {
			m.idx++
			return m.responses[m.idx - 1]
		}
		return error('timeout')
	}
	m.waits << timeout_ms
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
	assert nrc_name(0x24) == 'requestSequenceError'
	assert nrc_name(0x72) == 'generalProgrammingFailure'
	assert nrc_name(0x7E) == 'subFunctionNotSupportedInActiveSession'
	assert nrc_name(0x31) == 'requestOutOfRange'
	assert nrc_name(0x11) == 'serviceNotSupported'
	assert nrc_name(0x78).contains('Pending')
}

fn test_answer_to_names_the_request_it_answers() {
	rdbi := [u8(0x22), 0xF1, 0x90]
	assert answer_to(rdbi, [u8(0x62), 0xF1, 0x90, 0x41]) == .positive
	assert answer_to(rdbi, [u8(0x62), 0xF1, 0x89, 0x41]) == .stale // another DID's answer
	assert answer_to(rdbi, [u8(0x7F), 0x22, 0x31]) == .negative
	assert answer_to(rdbi, [u8(0x7F), 0x11, 0x11]) == .stale // another service's refusal
	assert answer_to(rdbi, [u8(0x7F), 0x22, 0x78]) == .pending
	assert answer_to(rdbi, [u8(0x7F), 0x11, 0x78]) == .stale // pending for another service
	assert answer_to(rdbi, [u8(0x7F), 0x22]) == .malformed // a negative response without its NRC
	assert answer_to(rdbi, []u8{}) == .malformed
	// the in-process server echoes the suppress bit; tolerated
	assert answer_to([u8(0x10), 0x83], [u8(0x50), 0x83, 0, 0x32, 0x01, 0xF4]) == .positive
	// a sub-function is echoed without its suppress-positive-response bit
	assert answer_to([u8(0x10), 0x83], [u8(0x50), 0x03, 0, 0x32, 0x01, 0xF4]) == .positive
	assert answer_to([u8(0x10), 0x03], [u8(0x50), 0x01, 0, 0x32, 0x01, 0xF4]) == .stale
	assert answer_to([u8(0x31), 0x01, 0xFF, 0x00], [u8(0x71), 0x01, 0xFF, 0x00, 0x00]) == .positive
	assert answer_to([u8(0x31), 0x01, 0xFF, 0x00], [u8(0x71), 0x01, 0xFF, 0x01]) == .stale
	assert answer_to([u8(0x36), 0x02, 0xAA], [u8(0x76), 0x01]) == .stale // the previous block
}

// a duplicated answer to the previous request, still queued, is not taken for this one's
fn test_a_stale_answer_ahead_of_the_real_one_is_discarded() {
	mut c, _ := client_with([
		[u8(0x7F), 0x11, 0x11], // the previous request's refusal, received twice
		[u8(0x67), 0x01, 0xDE, 0xAD, 0xBE, 0xEF],
	])
	seed := c.security_request_seed(0x01) or { panic(err) }
	assert seed == [u8(0xDE), 0xAD, 0xBE, 0xEF]
}

fn test_only_stale_answers_is_no_answer_and_says_so() {
	mut c, _ := client_with([[u8(0x7F), 0x11, 0x11]])
	c.tester_present() or {
		assert err.msg().contains('1 response(s) to other requests discarded'), err.msg()
		return
	}
	assert false, 'a stale answer was accepted'
}

// after a responsePending the wait is the server's P2* (plus the margin), not the client's P2
fn test_response_pending_waits_p2_star() {
	mut c, m := client_with([
		[u8(0x7F), 0x22, 0x78],
		[u8(0x62), 0xF1, 0x90, 0xAA],
	])
	c.read_data_by_identifier(0xF190) or { panic(err) }
	assert m.waits.len == 2
	assert m.waits[0] <= c.timeout_ms
	assert m.waits[1] > c.timeout_ms && m.waits[1] <= c.p2_star_ms + c.margin_ms
}

// pending as often as the server likes, but bounded in all
fn test_response_pending_is_bounded_in_total() {
	mut c, _ := client_with([
		[u8(0x7F), 0x22, 0x78],
		[u8(0x7F), 0x22, 0x78],
		[u8(0x62), 0xF1, 0x90, 0xAA],
	])
	c.pending_budget_ms = 0
	c.p2_star_ms = 1_000_000
	c.read_data_by_identifier(0xF190) or {
		assert err.msg().contains('still pending'), err.msg()
		return
	}
	assert false, 'an unbounded pending was accepted'
}

fn test_session_timing_is_read_and_adopted() {
	t := session_timing([u8(0x50), 0x03, 0x07, 0xD0, 0x00, 0x64]) or { panic('no timing') }
	assert t.p2_ms == 2000 && t.p2_star_ms == 1000
	assert session_timing([u8(0x50), 0x03]) == none
	mut c, _ := client_with([[u8(0x50), 0x03, 0x07, 0xD0, 0x00, 0x64]])
	c.diagnostic_session(0x03) or { panic(err) }
	assert c.p2_star_ms == 1000 // the server's P2*, as given
	assert c.timeout_ms == 2000 + c.margin_ms // P2 adopted: it loosens the default
	mut d, _ := client_with([[u8(0x50), 0x03, 0x00, 0x32, 0x01, 0xF4]])
	d.diagnostic_session(0x03) or { panic(err) }
	assert d.timeout_ms == 1000 // a 50 ms P2 never tightens the client's
}

// an answer already queued when a request goes out cannot be its answer — the one defence against
// a duplicated answer to an IDENTICAL earlier request, which no echo can tell apart
fn test_what_is_queued_before_the_send_is_drained() {
	mut m := &MockChannel{
		responses: [
			[u8(0x62), 0xF1, 0x90, 0x01], // the previous identical read's answer, received twice
			[u8(0x62), 0xF1, 0x90, 0x02],
		]
		queued:    1
	}
	mut c := new_client(m)
	data := c.read_data_by_identifier(0xF190) or { panic(err) }
	assert data == [u8(0x02)]
}

fn test_a_session_switch_through_raw_adopts_its_timing() {
	mut c, _ := client_with([[u8(0x50), 0x02, 0x00, 0x32, 0x0B, 0xB8]])
	c.raw([u8(0x10), 0x02]) or { panic(err) }
	assert c.p2_star_ms == 30_000
}

fn test_a_malformed_response_is_an_error_not_a_stale_answer() {
	mut c, _ := client_with([[u8(0x7F), 0x3E]])
	c.tester_present() or {
		assert err.msg().contains('malformed'), err.msg()
		return
	}
	assert false, 'a malformed response was accepted'
}
