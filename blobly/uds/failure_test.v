module uds

import blobly.doip
import blobly.isotp
import blobly.transport

// FailingChannel answers each recv from `answers` (an error where `errs` has text at that index)
// and fails a send with `send_err` when set; a drain (recv(0)) finds nothing.
struct FailingChannel {
pub:
	iface string = 'mock'
	tx_id u32
	rx_id u32
mut:
	send_err    string
	not_written bool // the send error says nothing went out (transport.NotWritten)
	answers     [][]u8
	errs     []string
	idx      int
}

fn (mut m FailingChannel) send(_ []u8) ! {
	if m.send_err != '' {
		return if m.not_written { transport.not_written(m.send_err) } else { error(m.send_err) }
	}
}

fn (mut m FailingChannel) recv(timeout_ms int) ![]u8 {
	if timeout_ms == 0 || m.idx >= m.answers.len {
		return error('timeout')
	}
	m.idx++
	if m.idx - 1 < m.errs.len && m.errs[m.idx - 1] != '' {
		return error(m.errs[m.idx - 1])
	}
	return m.answers[m.idx - 1]
}

fn (mut m FailingChannel) close() {}

fn (mut m FailingChannel) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn failure(ch &FailingChannel, req []u8) (Failure, string) {
	mut c := new_client(ch)
	c.timeout_ms = 50
	c.raw(req) or { return failure_of(err), err.msg() }
	return Failure.refused, 'answered'
}

fn test_each_way_an_exchange_ends_is_told_apart() {
	mut k, mut msg := failure(&FailingChannel{
		answers: [[u8(0x7F), 0x22, 0x31]]
	}, [u8(0x22), 0xF1, 0x90])
	assert k == .negative
	// nothing at all: the carrier's own words, as before the type
	k, msg = failure(&FailingChannel{}, [u8(0x22), 0xF1, 0x90])
	assert k == .no_answer && msg == 'timeout'
	assert (NoAnswer{
		sid:   0x22
		cause: 'timeout'
	}).described() == 'UDS: no answer to 0x22 (timeout)'
	// only an answer to another request, then the deadline
	k, msg = failure(&FailingChannel{
		answers: [[u8(0x62), 0xF1, 0x91, 0x00]]
	}, [u8(0x22), 0xF1, 0x90])
	assert k == .no_answer && msg.contains('1 response(s) to other requests discarded')
	k, _ = failure(&FailingChannel{
		answers: [[u8(0x7F)]]
	}, [u8(0x22), 0xF1, 0x90])
	assert k == .undecodable
	// a frame lost mid-transfer is the carrier's, not the server's silence
	k, msg = failure(&FailingChannel{
		answers: [[]u8{}]
		errs:    ['ISO-TP: CF sequence gap — got SN 3, expected 2 (a frame was lost)']
	}, [u8(0x22), 0xF1, 0x90])
	assert k == .carrier && msg.starts_with('ISO-TP: CF sequence gap')
	k, msg = failure(&FailingChannel{
		send_err: 'bus is closed'
	}, [u8(0x3E), 0x00])
	assert k == .carrier && msg == 'bus is closed'
	// a multi-frame request whose Flow Control never came: nobody answered
	k, _ = failure(&FailingChannel{
		send_err: 'timeout'
	}, []u8{len: 20, init: 0x2E})
	assert k == .no_answer
	k, msg = failure(&FailingChannel{}, []u8{})
	assert k == .refused && msg == 'empty UDS request'
	// a send refused before anything went out is no failure of the carrier; a failed write is
	k, msg = failure(&FailingChannel{
		send_err: 'not written'
		not_written: true
	}, [u8(0x3E), 0x00])
	assert k == .refused && msg == 'not written'
	k, _ = failure(&FailingChannel{
		send_err: 'send: Network is down'
	}, [u8(0x3E), 0x00])
	assert k == .carrier
	// the DoIP connection gone, under the wait or under the send, and a negative ack that is not
	k, _ = failure(&FailingChannel{
		answers: [[]u8{}]
		errs:    ['${doip.doip_connection_lost}DoIP: connection closed mid-message']
	}, [u8(0x22), 0xF1, 0x90])
	assert k == .lost
	k, _ = failure(&FailingChannel{
		send_err: '${doip.doip_connection_lost}Broken pipe'
	}, [u8(0x3E), 0x00])
	assert k == .lost
	k, _ = failure(&FailingChannel{
		answers: [[]u8{}]
		errs:    ['DoIP: diagnostic message negative ack (0x03)']
	}, [u8(0x22), 0xF1, 0x90])
	assert k == .carrier
	// an answer begun and not finished in time is late, not lost
	k, _ = failure(&FailingChannel{
		answers: [[]u8{}]
		errs:    [isotp.stall_note]
	}, [u8(0x22), 0xF1, 0x90])
	assert k == .no_answer
	// a stop only the channel was told of
	k, _ = failure(&FailingChannel{
		answers: [[]u8{}]
		errs:    [isotp.abandoned_recv_note]
	}, [u8(0x22), 0xF1, 0x90])
	assert k == .abandoned
}

fn test_pending_then_silence_or_a_failure_under_it() {
	k, _ := failure(&FailingChannel{
		answers: [[u8(0x7F), 0x31, 0x78]]
	}, [u8(0x31), 0x01, 0x02, 0x03])
	assert k == .pending
	k2, msg := failure(&FailingChannel{
		answers: [[u8(0x7F), 0x31, 0x78], []u8{}]
		errs:    ['', 'bus is closed']
	}, [u8(0x31), 0x01, 0x02, 0x03])
	assert k2 == .carrier && msg.contains('still pending') && msg.contains('bus is closed')
	k3, _ := failure(&FailingChannel{
		answers: [[u8(0x7F), 0x31, 0x78], []u8{}]
		errs:    ['', isotp.stall_note]
	}, [u8(0x31), 0x01, 0x02, 0x03])
	assert k3 == .pending
}

fn test_a_stop_is_abandoned_whichever_layer_noticed() {
	assert failure_of(error(abandoned_note)) == .abandoned
	assert failure_of(error(isotp.abandoned_note)) == .abandoned
	assert failure_of(error(isotp.abandoned_recv_note)) == .abandoned
	assert failure_of(error(doip.stopped_note)) == .abandoned
	// with the context a channel appends to it
	assert failure_of(error('${isotp.abandoned_recv_note} — after 1 orphan flow control frame(s)')) == .abandoned
	assert failure_of(error('anything else')) == .refused
}

fn test_an_all_zero_seed_says_unlocked() {
	assert already_unlocked([u8(0), 0, 0, 0])
	assert !already_unlocked([u8(0), 1])
	assert !already_unlocked([]u8{})
}

// a segmented send whose receiver never answered within the transfer's whole allowance is silence
fn test_a_spent_flow_control_allowance_is_no_answer() {
	mut ch := isotp.on_bus(transport.open('inproc:FAILURE_FC')!, 'inproc:FAILURE_FC', 0x700, 0x708,
		false)!
	ch.total_wait_ms = 20
	ch.fc_window_ms = 100
	mut c := new_client(ch)
	c.raw([u8(0x2E), 0xF1, 0x90, 1, 2, 3, 4, 5]) or {
		assert failure_of(err) == .no_answer, err.msg()
		return
	}
	assert false
}

struct Asks {
mut:
	n int
}

// a send that fails while a stop is asked of the client is the stop's, whatever the carrier said
fn test_a_send_failing_under_a_stop_is_abandoned() {
	mut c := new_client(&FailingChannel{
		send_err: 'cansub write timed out'
	})
	mut asks := &Asks{}
	c.stop_requested = fn [mut asks] () bool {
		asks.n++
		return asks.n > 1 // not before the send: during it
	}
	c.raw([u8(0x3E), 0x00]) or {
		assert failure_of(err) == .abandoned, err.msg()
		assert asks.n == 2
		return
	}
	assert false
}

// StoppedDrain is a carrier whose stop ends a read of what was queued before the request.
struct StoppedDrain {
pub:
	iface string = 'mock'
	tx_id u32
	rx_id u32
mut:
	sent int
}

fn (mut m StoppedDrain) send(_ []u8) ! {
	m.sent++
}

fn (mut m StoppedDrain) recv(_ int) ![]u8 {
	return error(doip.stopped_note)
}

fn (mut m StoppedDrain) close() {}

fn (mut m StoppedDrain) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn test_a_stop_during_the_pre_send_drain_is_the_stop() {
	mut ch := &StoppedDrain{}
	mut c := new_client(ch)
	c.raw([u8(0x22), 0xF1, 0x90]) or {
		assert failure_of(err) == .abandoned, err.msg()
		assert ch.sent == 0
		return
	}
	assert false, 'answered'
}
