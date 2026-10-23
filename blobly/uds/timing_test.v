module uds

import blobly.transport

// TimingChannel answers each request from `answers` in order and records how long each recv was
// given; past them it is silent.
struct TimingChannel {
pub:
	iface string = 'timing'
	tx_id u32
	rx_id u32
mut:
	answers [][]u8
	waits   []int
}

fn (mut m TimingChannel) send(_ []u8) ! {}

fn (mut m TimingChannel) recv(timeout_ms int) ![]u8 {
	if timeout_ms == 0 {
		return error('timeout') // the pre-send drain: nothing queued
	}
	m.waits << timeout_ms
	if m.answers.len == 0 {
		return error('timeout')
	}
	r := m.answers[0]
	m.answers.delete(0)
	return r
}

fn (mut m TimingChannel) close() {}

fn (mut m TimingChannel) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn client_with(answers [][]u8) (Client, &TimingChannel) {
	mut m := &TimingChannel{
		answers: answers
	}
	return new_client(m), m
}

fn test_the_default_timing_reads_as_the_client_waits() {
	c := Client{}
	assert c.timing() == Timing{
		timeout_ms:        1000
		p2_star_ms:        default_p2_star_ms
		margin_ms:         1000
		pending_budget_ms: 120_000
	}
}

// what is stated bounds the next request: the first wait, and after a responsePending P2* plus the
// margin, never past the allowance
fn test_stated_timing_bounds_the_waits() {
	mut c, m := client_with([
		[u8(0x7F), 0x22, 0x78],
		[u8(0x62), 0xF1, 0x90, 0xAA],
	])
	c.set_timing(Timing{
		timeout_ms:        200
		p2_star_ms:        30
		margin_ms:         20
		pending_budget_ms: 5000
	})!
	c.read_data_by_identifier(0xF190)!
	assert m.waits.len == 2
	assert m.waits[0] <= 200
	assert m.waits[1] <= 50
}

// a timing out of range changes nothing: none of its fields is taken
fn test_a_timing_out_of_range_is_refused_whole() {
	mut c := Client{}
	before := c.timing()
	for bad in [
		Timing{
			...before
			timeout_ms:        0
			pending_budget_ms: 50
		},
		Timing{
			...before
			pending_budget_ms: 0
		},
		Timing{
			...before
			p2_star_ms: -1
		},
		Timing{
			...before
			margin_ms: -1
		},
		Timing{
			...before
			timeout_ms: max_timing_ms + 1
		},
		Timing{
			...before
			margin_ms: max_timing_ms + 1
		},
	] {
		if _ := c.set_timing(bad) {
			assert false, 'set_timing took ${bad}'
		}
		assert c.timing() == before
	}
	ok := Timing{
		timeout_ms:        1
		p2_star_ms:        0
		margin_ms:         0
		pending_budget_ms: max_timing_ms
	}
	assert timing_refusal(ok) == none
	c.set_timing(ok)!
	assert c.timing() == ok
}

// a 0x10 answer still adopts its P2* over a stated one, and lengthens a stated first wait its P2
// needs more than
fn test_a_session_answer_adopts_over_stated_timing() {
	mut c, _ := client_with([[u8(0x50), 0x03, 0x00, 0x32, 0x01, 0xF4]])
	c.set_timing(Timing{
		timeout_ms:        20
		p2_star_ms:        100
		margin_ms:         10
		pending_budget_ms: 1000
	})!
	c.diagnostic_session(0x03)!
	assert c.timing() == Timing{
		timeout_ms:        60
		p2_star_ms:        5000
		margin_ms:         10
		pending_budget_ms: 1000
	}
}

// a new connection's client takes the old one's waits, P2* only where it loosens the default
fn test_carry_timing_loosens_p2_star_only() {
	mut old := Client{}
	old.set_timing(Timing{
		timeout_ms:        300
		p2_star_ms:        50
		margin_ms:         40
		pending_budget_ms: 9000
	})!
	mut fresh := Client{}
	fresh.carry_timing(old)
	assert fresh.timing() == Timing{
		timeout_ms:        300
		p2_star_ms:        default_p2_star_ms
		margin_ms:         40
		pending_budget_ms: 9000
	}
	old.p2_star_ms = 20_000
	fresh.carry_timing(old)
	assert fresh.p2_star_ms == 20_000
}
