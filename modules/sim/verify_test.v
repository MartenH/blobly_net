module sim

import candb

fn vmsg() candb.Message {
	return candb.Message{
		name: 'Protected'
		id:   0x123
		dlc:  8
		signals: [
			candb.Signal{ name: 'AliveCounter', start_bit: 0, length: 4, byte_order: .little_endian, factor: 1 },
			candb.Signal{ name: 'Payload', start_bit: 8, length: 16, byte_order: .little_endian, factor: 1 },
			candb.Signal{ name: 'CRC', start_bit: 56, length: 8, byte_order: .little_endian, factor: 1 },
		]
	}
}

// A well-formed stream must pass: the verifier has to agree with the stamper, or every real
// frame reads as a fault and the feature is worse than useless.
fn test_a_correctly_protected_stream_passes() {
	m := vmsg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850', data_id: u32(42) }
	mut v := Verifier{ msg: m, e2e: e }
	for n in 0 .. 20 {
		mut d := []u8{len: 8}
		e.apply(m, mut d, n)
		assert v.check(d) == .ok, 'frame ${n} rejected a valid stream'
	}
	assert v.bad == 0
	assert v.seen == 20
}

// The counter wraps at its width, and a wrap is NOT a skip.
fn test_counter_wrap_is_not_a_violation() {
	m := vmsg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	mut v := Verifier{ msg: m, e2e: e }
	for n in 14 .. 19 { // 14, 15, 0, 1, 2 across a 4-bit wrap
		mut d := []u8{len: 8}
		e.apply(m, mut d, n)
		assert v.check(d) == .ok, 'wrap at n=${n} was reported as a violation'
	}
}

// The three faults this exists to catch. (Corrupted by hand here so the verifier does not
// depend on the fault injector living in the same branch.)
fn test_it_catches_what_fault_injection_produces() {
	m := vmsg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }

	// bad_crc
	mut v1 := Verifier{ msg: m, e2e: e }
	mut d1 := []u8{len: 8}
	e.apply(m, mut d1, 0)
	assert v1.check(d1) == .ok
	mut bad := []u8{len: 8}
	e.apply(m, mut bad, 1)
	bad[7] = ~bad[7] // corrupt the checksum field, as fault injection does
	assert v1.check(bad) == .bad_crc, 'a corrupted checksum must be caught'

	// a stalled counter
	mut v2 := Verifier{ msg: m, e2e: e }
	mut a := []u8{len: 8}
	e.apply(m, mut a, 5)
	assert v2.check(a) == .ok
	assert v2.check(a) == .stalled_ctr, 'a repeated counter must be caught'

	// a skipped counter
	mut v3 := Verifier{ msg: m, e2e: e }
	mut p := []u8{len: 8}
	e.apply(m, mut p, 1)
	assert v3.check(p) == .ok
	mut q := []u8{len: 8}
	e.apply(m, mut q, 4) // 1 -> 4
	assert v3.check(q) == .skipped_ctr
	assert v3.bad == 1
}

// A wrong checksum must not be read as a counter verdict: those bits are as likely to be
// corrupt as any others, so the checksum is judged first and alone.
fn test_a_bad_checksum_is_reported_before_the_counter() {
	m := vmsg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	mut v := Verifier{ msg: m, e2e: e }
	mut first := []u8{len: 8}
	e.apply(m, mut first, 0)
	assert v.check(first) == .ok

	// both wrong at once: counter repeated AND checksum corrupted
	mut both := []u8{len: 8}
	e.apply(m, mut both, 0)
	both[7] = ~both[7]
	assert v.check(both) == .bad_crc, 'the checksum verdict must win'
}

// The first frame has nothing to compare against, and must not be reported as a stall.
fn test_first_frame_is_never_a_counter_violation() {
	m := vmsg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	mut v := Verifier{ msg: m, e2e: e }
	mut d := []u8{len: 8}
	e.apply(m, mut d, 7) // arriving mid-stream, counter already at 7
	assert v.check(d) == .ok
	assert v.bad == 0
}
