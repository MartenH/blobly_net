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
	assert vin.parts() == [Part{'text', '6 characters'}]
	assert vin.texts('ABC123'.bytes())! == ['ABC123']
	assert vin.encode(['ABC123'])! == 'ABC123'.bytes()
	if _ := vin.encode(['ABC']) {
		assert false // not the declared size
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
