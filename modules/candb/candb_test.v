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
