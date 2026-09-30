module sim

import candb

// AUTOSAR E2E Profile 1, pinned by vectors from an INDEPENDENT implementation — autosar-e2e
// 1.0.0 (sut/e2e_oracle.py regenerates them) — on blobly_emb overspeed's BrakeStatus layout:
// payload E8 03 5A 00, the CRC in byte 4, the counter in byte 5's low nibble, Data ID 0x1244
// (distinct bytes, so ALT's choice of byte shows), counters 0..14.
const p01_vectors = {
	'both': [u8(0xE8), 0xF5, 0xD2, 0xCF, 0x9C, 0x81, 0xA6, 0xBB, 0x00, 0x1D, 0x3A, 0x27, 0x74,
		0x69, 0x4E]
	'low':  [u8(0x92), 0x8F, 0xA8, 0xB5, 0xE6, 0xFB, 0xDC, 0xC1, 0x7A, 0x67, 0x40, 0x5D, 0x0E,
		0x13, 0x34]
	'alt':  [u8(0x92), 0x42, 0xA8, 0x78, 0xE6, 0x36, 0xDC, 0x0C, 0x7A, 0xAA, 0x40, 0x90, 0x0E,
		0xDE, 0x34]
}

fn brake_status() candb.Message {
	return candb.Message{
		name:    'BrakeStatus'
		id:      0x301
		dlc:     6
		signals: [
			candb.Signal{
				name:       'BrakePressure'
				start_bit:  0
				length:     16
				byte_order: .little_endian
				factor:     1
			},
			candb.Signal{
				name:       'Pad'
				start_bit:  16
				length:     8
				byte_order: .little_endian
				factor:     1
			},
			candb.Signal{
				name:       'BrakeCrc'
				start_bit:  32
				length:     8
				byte_order: .little_endian
				factor:     1
			},
			candb.Signal{
				name:       'BrakeCounter'
				start_bit:  40
				length:     4
				byte_order: .little_endian
				factor:     1
			},
		]
	}
}

fn p01_e2e(mode string) E2e {
	return E2e{
		counter:      'BrakeCounter'
		crc:          'BrakeCrc'
		profile:      p01
		data_id:      u32(0x1244)
		data_id_mode: mode
	}
}

fn test_p01_matches_the_reference_in_every_supported_mode() {
	m := brake_status()
	for mode, want in p01_vectors {
		e := p01_e2e(mode)
		for n in 0 .. 15 {
			mut d := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
			e.apply(m, mut d, n)
			assert d[5] & 0x0F == u8(n)
			assert d[4] == want[n], '${mode} counter ${n}: 0x${d[4]:02X}, the reference says 0x${want[n]:02X}'
		}
	}
	// 'both' is the default mode
	mut a := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
	p01_e2e('').apply(m, mut a, 3)
	assert a[4] == p01_vectors['both'][3]
}

fn test_p01_counter_runs_0_to_14() {
	m := brake_status()
	e := p01_e2e('both')
	for n, want in {
		14: 14
		15: 0
		16: 1
		29: 14
		30: 0
	} {
		mut d := []u8{len: 6}
		e.apply(m, mut d, n)
		assert int(d[5] & 0x0F) == want, 'send ${n}'
	}
}

fn test_p01_verifier_accepts_its_own_frames_and_catches_the_rest() {
	m := brake_status()
	mut v := Verifier{
		msg: m
		e2e: p01_e2e('alt')
	}
	for n in 0 .. 40 { // across two wraps: 14 -> 0 is the next counter, not a skip
		mut d := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
		v.e2e.apply(m, mut d, n)
		assert v.check(d) == .ok, 'frame ${n}'
	}
	mut bad := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
	v.e2e.apply(m, mut bad, 40)
	bad[0] ^= 0x01
	assert v.check(bad) == .bad_crc
	// 15 is never a Profile 1 counter: a frame carrying it, correctly checksummed, is a skip
	mut fifteen := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x0F]
	sig := m.signals[2]
	fifteen[4] = v.e2e.checksum(m, sig, fifteen)
	assert v.check(fifteen) == .skipped_ctr
}

fn test_p01_refuses_what_it_cannot_stamp() {
	m := brake_status()
	assert p01_problem(m, p01_e2e('both')) == none
	mut e := p01_e2e('both')
	e.data_id = none
	assert (p01_problem(m, e) or { '' }).contains('needs a data_id')
	e = p01_e2e('both')
	e.data_id = u32(0x10000)
	assert (p01_problem(m, e) or { '' }).contains('16 bits')
	assert (p01_problem(m, p01_e2e('nibble')) or { '' }).contains('not both, low or alt')
	e = p01_e2e('both')
	e.crc = 'BrakePressure' // 16 bits
	assert (p01_problem(m, e) or { '' }).contains('one whole byte')
	e = p01_e2e('both')
	e.counter = 'Pad' // 8 bits
	assert (p01_problem(m, e) or { '' }).contains('4-bit counter')
	// a primitive is not Profile 1's to judge
	assert p01_problem(m, E2e{ crc: 'BrakePressure', profile: 'crc8_j1850' }) == none
}
