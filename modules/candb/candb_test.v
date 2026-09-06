module candb

fn test_raw_extraction_le() {
	data := [u8(0xAB), 0, 0, 0, 0, 0, 0, 0]
	s := Signal{
		name:      'b'
		start_bit: 0
		length:    8
	}
	assert s.raw_value(data) == 0xAB
}

fn test_physical_factor_offset() {
	// CoolantTemp style: raw - 40 deg C
	s := Signal{
		name:      'temp'
		start_bit: 0
		length:    8
		offset:    -40
	}
	data := [u8(60), 0, 0, 0, 0, 0, 0, 0]
	assert s.physical(data) == 20.0
}

fn test_encode_decode_roundtrip() {
	// EngineSpeed style: 0.25 rpm/bit, 16 bits
	s := Signal{
		name:      'rpm'
		start_bit: 0
		length:    16
		factor:    0.25
	}
	mut data := []u8{len: 8}
	s.encode(mut data, 2000.0)
	assert s.physical(data) == 2000.0
}

fn test_signed_negative() {
	s := Signal{
		name:      's'
		start_bit: 0
		length:    8
		is_signed: true
	}
	mut data := []u8{len: 8}
	s.encode(mut data, -5.0)
	assert s.physical(data) == -5.0
}

// A signed signal's VAL_ table stores negative keys two's-complement (u64), so a raw enum key of
// -1 lands in `values` as 0xFF (for width 8). phys_from_raw must sign-extend it back to -1.0 (not
// 255), and raw_from_phys must round-trip -1.0 -> that same key — the generator enum-picker path.
fn test_signed_enum_raw_roundtrip() {
	s := Signal{
		name:      'gear'
		start_bit: 0
		length:    8
		is_signed: true
		factor:    1.0
	}
	key := u64(i64(-1)) & 0xFF // how apply_val stores VAL_ -1 for an 8-bit signed signal
	assert key == 0xFF
	assert s.phys_from_raw(key) == -1.0
	assert s.raw_from_phys(-1.0) == key
	// a scaled signed signal: factor 0.5, raw key -2 -> physical -1.0
	sc := Signal{
		name:      't'
		start_bit: 0
		length:    4
		is_signed: true
		factor:    0.5
	}
	k2 := u64(i64(-2)) & 0xF
	assert sc.phys_from_raw(k2) == -1.0
	assert sc.raw_from_phys(-1.0) == k2
}

fn test_cross_byte_boundary() {
	// start bit 12, length 8 spans bytes 1 and 2
	s := Signal{
		name:      'x'
		start_bit: 12
		length:    8
	}
	mut data := []u8{len: 8}
	s.encode(mut data, 0x5A)
	assert s.raw_value(data) == 0x5A
}

fn test_signals_dont_clobber_neighbours() {
	a := Signal{
		name:      'a'
		start_bit: 0
		length:    16
		factor:    0.25
	}
	b := Signal{
		name:      'b'
		start_bit: 16
		length:    12
		factor:    0.1
	}
	mut data := []u8{len: 8}
	a.encode(mut data, 1500.0)
	b.encode(mut data, 88.0)
	// encoding b must not disturb a
	assert a.physical(data) == 1500.0
	assert b.physical(data) == 88.0
}

fn test_big_endian_known_vector() {
	// Textbook Motorola: a 16-bit big-endian signal whose MSB is bit 7 (the MSB
	// of byte 0) spans bytes 0..1 as [hi, lo]. Bytes 0x12,0x34 -> 0x1234.
	s := Signal{
		name:       'be16'
		start_bit:  7
		length:     16
		byte_order: .big_endian
	}
	data := [u8(0x12), 0x34, 0, 0, 0, 0, 0, 0]
	assert s.raw_value(data) == 0x1234
}

fn test_big_endian_roundtrip() {
	s := Signal{
		name:       'be'
		start_bit:  7
		length:     16
		factor:     0.1
		byte_order: .big_endian
	}
	mut data := []u8{len: 8}
	s.encode(mut data, 1234.5)
	assert s.physical(data) == 1234.5
	// and the raw bytes are big-endian (hi byte first)
	assert data[0] == 0x30 && data[1] == 0x39 // 12345 = 0x3039
}

// A signed signal the full 64 bits wide: the raw pattern IS the i64, so all-ones is -1 and not
// 1.8e19 — the sign-extension below 64 bits shifts by the width, which would be a shift by 64.
fn test_signed_64_bit() {
	s := Signal{
		name:      'Wide'
		start_bit: 0
		length:    64
		is_signed: true
	}
	assert s.phys_from_raw(~u64(0)) == -1.0
	assert s.phys_from_raw(u64(1) << 63) == -9223372036854775808.0
	assert s.phys_from_raw(5) == 5.0
	assert s.raw_from_phys(-1.0) == ~u64(0)
	assert s.raw_from_phys(5.0) == 5
	mut data := []u8{len: 8}
	s.encode(mut data, -2.0)
	assert s.physical(data) == -2.0
	// and UNSIGNED 64 bits wide: the top half of the domain encodes as itself, not as INT64_MIN
	u := Signal{
		name:      'WideU'
		start_bit: 0
		length:    64
		is_signed: false
	}
	assert u.phys_from_raw(~u64(0)) == 18446744073709551615.0
	assert u.raw_from_phys(1.0e19) == u64(10000000000000000000)
	assert u.raw_from_phys(1.0e19) != u.raw_from_phys(1.8e19)
	assert u.phys_from_raw(u.raw_from_phys(1.0e19)) == 1.0e19
	// the ENDPOINTS: f64 rounds 2^64-1 up to 2^64 and 2^63-1 up to 2^63, which cast to 0 and to
	// the sign bit — the opposite endpoint. Clamped instead (round 31)
	assert u.raw_from_phys(18446744073709551615.0) == ~u64(0)
	assert u.raw_from_phys(u.phys_from_raw(~u64(0))) == ~u64(0)
	assert s.raw_from_phys(9223372036854775807.0) == u64(9223372036854775807)
	assert s.raw_from_phys(s.phys_from_raw(u64(9223372036854775807))) == u64(9223372036854775807)
	assert s.raw_from_phys(-9223372036854775808.0) == u64(1) << 63
	assert s.raw_from_phys(-1.0e19) == u64(1) << 63 // below the minimum clamps to it
	assert s.raw_from_phys(1.0e19) == u64(9223372036854775807) // above the maximum clamps to it
	n8 := Signal{
		name:      'N8'
		length:    8
		is_signed: true
	}
	assert n8.raw_from_phys(127.0) == 127 && n8.raw_from_phys(200.0) == 127
	assert n8.raw_from_phys(-128.0) == 128 && n8.raw_from_phys(-300.0) == 128
	u8s := Signal{
		name:   'U8'
		length: 8
	}
	assert u8s.raw_from_phys(255.0) == 255 && u8s.raw_from_phys(300.0) == 255
}

fn test_big_endian_signed() {
	s := Signal{
		name:       'bes'
		start_bit:  7
		length:     16
		is_signed:  true
		byte_order: .big_endian
	}
	mut data := []u8{len: 8}
	s.encode(mut data, -1000.0)
	assert s.physical(data) == -1000.0
}

fn test_big_endian_owns() {
	// MSB at bit 7, length 16 -> occupies all of byte 0 (bits 0..7) and byte 1.
	s := Signal{
		name:       'be'
		start_bit:  7
		length:     16
		byte_order: .big_endian
	}
	assert s.owns(7) // MSB
	assert s.owns(0) // LSB of byte 0
	assert s.owns(15) // MSB of byte 1
	assert s.owns(8) // LSB of byte 1
	assert !s.owns(16) // byte 2 — outside
}

fn test_signal_at() {
	m := Message{
		name:    'PT'
		id:      0x100
		dlc:     8
		signals: [
			Signal{
				name:      'a'
				start_bit: 0
				length:    16
			},
			Signal{
				name:      'b'
				start_bit: 16
				length:    8
			},
		]
	}
	assert m.signal_at(5) == 0
	assert m.signal_at(20) == 1
	assert m.signal_at(40) == -1
}
