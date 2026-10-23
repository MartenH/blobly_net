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
	c.state(Waits{
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
		if _ := c.state(Waits{
			timeout_ms:        bad.timeout_ms
			p2_star_ms:        bad.p2_star_ms
			margin_ms:         bad.margin_ms
			pending_budget_ms: bad.pending_budget_ms
		})
		{
			assert false, 'state took ${bad}'
		}
		assert c.timing() == before
		assert c.stated == default_timing
	}
	ok := Timing{
		timeout_ms:        1
		p2_star_ms:        0
		margin_ms:         0
		pending_budget_ms: max_timing_ms
	}
	assert timing_refusal(ok) == none
	c.state(Waits{
		timeout_ms:        1
		p2_star_ms:        0
		margin_ms:         0
		pending_budget_ms: max_timing_ms
	})!
	assert c.timing() == ok
}

// a 0x10 answer still adopts its P2* over a stated one, and lengthens a stated first wait its P2
// needs more than
fn test_a_session_answer_adopts_over_stated_timing() {
	mut c, _ := client_with([[u8(0x50), 0x03, 0x00, 0x32, 0x01, 0xF4]])
	c.state(Waits{
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
fn test_carry_from_loosens_p2_star_only() {
	mut old := Client{}
	old.state(Waits{
		timeout_ms:        300
		p2_star_ms:        50
		margin_ms:         40
		pending_budget_ms: 9000
	})!
	mut fresh := Client{}
	fresh.carry_from(&old)
	assert fresh.timing() == Timing{
		timeout_ms:        300
		p2_star_ms:        default_p2_star_ms
		margin_ms:         40
		pending_budget_ms: 9000
	}
	old.p2_star_ms = 20_000
	fresh.carry_from(&old)
	assert fresh.p2_star_ms == 20_000
}

// a new connection to the same ECU keeps what was learned of it; another ECU starts from what the
// host stated
fn test_another_ecu_starts_again_from_what_was_stated() {
	mut c, _ := client_with([[u8(0x50), 0x03, 0x00, 0x32, 0x00, 0x01]]) // P2 50 ms, P2* 10 ms
	c.set_did_size(0xF190, 17)
	c.diagnostic_session(0x03)!
	c.state(Waits{ margin_ms: 20 })! // after the session: its P2* is adopted, not stated
	c.did_lens[0xF18C] = 7 // learned from the ECU, as a snapshot read does
	assert c.timing() == Timing{
		...default_timing
		timeout_ms: 1050
		p2_star_ms: 10
		margin_ms:  20
	}
	mut fresh := Client{}
	fresh.carry_from(&c)
	assert fresh.did_lens == {
		u16(0xF190): 17
		0xF18C:      7
	}
	c.another_ecu()
	assert c.timing() == Timing{
		...default_timing
		margin_ms: 20
	}
	assert c.did_lens == {
		u16(0xF190): 17
	}
	fresh.another_ecu()
	assert fresh.timing() == c.timing() && fresh.did_lens == c.did_lens, 'a carried client forgot what was stated'
}

// a 0x10 answer never lengthens the first wait past what a host may state
fn test_an_adopted_wait_stays_within_what_may_be_stated() {
	mut c, _ := client_with([[u8(0x50), 0x03, 0xFF, 0xFF, 0x01, 0xF4]]) // P2 65535 ms
	c.state(Waits{ margin_ms: max_timing_ms })!
	c.diagnostic_session(0x03)!
	assert c.timeout_ms == max_timing_ms
	c.state(Waits{ margin_ms: 0 })!
}
