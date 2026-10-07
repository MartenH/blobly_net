module sysview

import rand

fn param_did() DidDesc {
	return DidDesc{
		id:     0x0110
		kind:   .param
		name:   'SteerLimit'
		size:   2
		fields: [Field{'deg', 'u16'}]
		ranges: {
			'deg': Range{0, 360}
		}
	}
}

fn test_a_parameter_encodes_and_decodes_by_its_layout() {
	x := param_did()
	assert x.parts() == [Part{'deg', 'u16 0..360'}]
	assert x.texts([u8(0x01), 0x68])! == ['360']
	assert x.encode(['300'])! == [u8(0x01), 0x2C]
	assert x.encode(['0x64'])! == [u8(0x00), 0x64]
	assert x.encode([' 100 '])! == [u8(0x00), 0x64]
}

fn test_a_value_outside_the_range_or_the_width_is_refused_by_name() {
	x := param_did()
	if _ := x.encode(['361']) {
		assert false
	} else {
		assert err.msg() == 'deg: 361 is outside 0..360'
	}
	if _ := x.encode(['-1']) {
		assert false
	} else {
		assert err.msg().contains('outside')
	}
	if _ := x.encode(['ten']) {
		assert false
	} else {
		assert err.msg() == 'deg: "ten" is not a number'
	}
	if _ := x.encode([]) {
		assert false
	}
	// with no range, the width bounds it
	y := DidDesc{
		kind:   .signal
		size:   1
		fields: [Field{'v', 'u8'}]
	}
	assert y.encode(['255'])! == [u8(0xFF)]
	if _ := y.encode(['256']) {
		assert false
	}
}

// A declared range narrows the field's own, never widens it: a u8 said to reach 300 still holds
// 255, rather than 300 passing and its low byte being written.
fn test_a_range_narrows_the_width_never_widens_it() {
	x := DidDesc{
		kind:   .param
		size:   1
		fields: [Field{'x', 'u8'}]
		ranges: {
			'x': Range{-5, 300}
		}
	}
	assert x.parts()[0].hint == 'u8 0..255'
	assert x.encode(['255'])! == [u8(0xFF)]
	if _ := x.encode(['300']) {
		assert false
	}
	if _ := x.encode(['-1']) {
		assert false
	}
	// a u64 field with a range is held to it; without one, the whole unsigned width
	y := DidDesc{
		kind:   .param
		size:   8
		fields: [Field{'n', 'u64'}]
		ranges: {
			'n': Range{10, 1000}
		}
	}
	assert y.encode(['1000'])! == [u8(0), 0, 0, 0, 0, 0, 0x03, 0xE8]
	if _ := y.encode(['1001']) {
		assert false
	}
	if _ := y.encode(['9']) {
		assert false
	}
	// a declared bound of exactly max_i64 is a bound, not "unbounded"
	m := DidDesc{
		kind:   .param
		size:   8
		fields: [Field{'n', 'u64'}]
		ranges: {
			'n': Range{0, max_i64}
		}
	}
	assert m.encode(['9223372036854775807'])! == [u8(0x7F), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
		0xFF]
	if _ := m.encode(['9223372036854775808']) {
		assert false
	}
	z := DidDesc{
		kind:   .param
		size:   8
		fields: [Field{'n', 'u64'}]
	}
	assert z.encode(['18446744073709551615'])! == [u8(0xFF), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
		0xFF]
}

fn test_signed_fields_and_several_of_them() {
	x := DidDesc{
		kind:   .param
		size:   7
		fields: [Field{'a', 'i16'}, Field{'b', 'u32'}, Field{'on', 'bool'}]
	}
	assert x.parts().map(it.label) == ['a', 'b', 'on']
	b := x.encode(['-2', '70000', 'true'])!
	assert b == [u8(0xFF), 0xFE, 0x00, 0x01, 0x11, 0x70, 0x01]
	assert x.texts(b)! == ['-2', '70000', 'true']
	if _ := x.encode(['-32769', '0', 'false']) {
		assert false
	}
	if _ := x.encode(['0', '0', 'maybe']) {
		assert false
	}
}

fn test_text_and_bytes() {
	vin := DidDesc{
		kind: .ascii
		size: 6
	}
	assert vin.parts() == [Part{'text', 'up to 6 characters'}]
	assert vin.texts('ABC123'.bytes())! == ['ABC123']
	assert vin.encode(['ABC123'])! == 'ABC123'.bytes()
	// shorter: NUL-padded to the size, and a padded text reads back without its NULs
	assert vin.encode(['ABC'])! == [u8(`A`), `B`, `C`, 0, 0, 0]
	assert vin.texts([u8(`A`), `B`, `C`, 0, 0, 0])! == ['ABC']
	if _ := vin.encode(['ABC1234']) {
		assert false // longer than the size
	}
	raw := DidDesc{
		kind: .bytes
		size: 4
	}
	assert raw.texts([u8(0), 1, 0xAB, 0xFF])! == ['00 01 AB FF']
	assert raw.encode(['0001abff'])! == [u8(0), 1, 0xAB, 0xFF]
	assert raw.encode(['0x0001ABFF'])! == [u8(0), 1, 0xAB, 0xFF]
	if _ := raw.encode(['00 01 AB']) {
		assert false
	}
	if _ := raw.encode(['0G 00 00 00']) {
		assert false
	}
	// unsized: whatever the bytes are
	free := DidDesc{
		kind: .unknown
	}
	assert free.encode(['01 02 03'])! == [u8(1), 2, 3]
	if _ := free.texts([u8(1)]) {
	} else {
		assert false
	}
}

fn test_a_value_of_another_size_is_not_decoded() {
	x := param_did()
	if _ := x.texts([u8(1)]) {
		assert false
	} else {
		assert err.msg() == '1 byte(s), the description says 2'
	}
}

// The round trip, over every layout the description makes: encode(texts(b)) == b for random
// values of the declared size (a bool byte canonical, 0 or 1 — what the field means).
fn test_encode_is_the_inverse_of_texts() {
	layouts := [
		param_did(),
		DidDesc{
			kind:   .param
			size:   15
			fields: [Field{'a', 'i8'}, Field{'b', 'i16'}, Field{'c', 'i32'}, Field{'d', 'u32'},
				Field{'e', 'u16'}, Field{'f', 'u8'}, Field{'g', 'bool'}]
		},
		DidDesc{
			kind:   .signal
			size:   8
			fields: [Field{'x', 'u64'}]
		},
		DidDesc{
			kind:   .signal
			size:   8
			fields: [Field{'x', 'i64'}]
		},
		DidDesc{
			kind:   .param_status
			size:   2
			fields: [Field{'P', 'u8'}, Field{'Q', 'u8'}]
		},
		DidDesc{
			kind: .ascii
			size: 5
		},
		DidDesc{
			kind: .bytes
			size: 3
		},
	]
	for x in layouts {
		for _ in 0 .. 500 {
			mut b := []u8{len: x.size}
			for i in 0 .. b.len {
				b[i] = u8(rand.intn(256) or { 0 })
			}
			if x.kind == .ascii {
				b = b.map(u8(0x20 + it % 0x5F)) // printable: a text DID holds text
				if b.len > 2 && rand.intn(2) or { 0 } == 1 {
					b[b.len - 1] = 0 // NUL-padded
					b[b.len - 2] = 0
				}
			}
			if x.size == 2 && x.kind == .param {
				n := rand.intn(361) or { 0 } // within SteerLimit's range
				b = [u8(n >> 8), u8(n)]
			}
			if x.fields.len > 0 && x.fields.last().typ == 'bool' {
				b[b.len - 1] &= 1
			}
			ts := x.texts(b)!
			assert x.encode(ts)! == b, '${x.fields} ${b} -> ${ts}'
		}
	}
}

// The rendering reads through the codec too: a NUL-padded text shows without its padding.
fn test_decode_did_renders_through_the_codec() {
	d := EcuDesc{
		dids: [DidDesc{
			id:   0xF190
			kind: .ascii
			size: 6
		}]
	}
	assert d.decode_did(0xF190, [u8(`A`), `B`, 0, 0, 0, 0]) == '"AB"'
	assert d.decode_did(0xF190, [u8(`A`)]) == '' // not its size
}

// A text DID takes printable ASCII only: UTF-8 is not ASCII, and a control character could not be
// read back as typed.
fn test_a_text_did_refuses_what_is_not_printable_ascii() {
	x := DidDesc{
		kind: .ascii
		size: 4
	}
	if _ := x.encode(['café']) {
		assert false
	} else {
		assert err.msg() == 'text: character 4 is not printable ASCII (0xC3)'
	}
	if _ := x.encode(['a\tb']) {
		assert false
	}
	assert x.encode(['~ !A'])! == '~ !A'.bytes()
}
