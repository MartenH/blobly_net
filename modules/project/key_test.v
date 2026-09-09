module project

// The property, not the format: two different (name, interface) pairs must never collide. Both
// values are free text in the editor, so a `|` in either is legal input.
fn test_a_separator_in_a_part_cannot_forge_another_key() {
	assert compose_key('A|x', 'y') != compose_key('A', 'x|y')
	assert compose_key('', 'a|b') != compose_key('a', 'b')
	assert compose_key('a|b', '') != compose_key('a', 'b')
}

fn test_equal_inputs_give_equal_keys() {
	assert compose_key('CAN1', 'vcan0') == compose_key('CAN1', 'vcan0')
	assert compose_key('CAN1', 'vcan0') != compose_key('CAN2', 'vcan0')
	assert compose_key('CAN1', 'vcan0') != compose_key('CAN1', 'vcan1')
}

fn test_empty_parts_are_distinguishable() {
	assert compose_key('', 'vcan0') != compose_key('vcan0', '')
	assert compose_key('') != compose_key('', '')
}

// A brute-force check of the property over inputs that contain the separator, the prefix
// character and the empty string — the shapes a hand-rolled join gets wrong.
fn test_no_collisions_across_awkward_inputs() {
	parts := ['', 'a', 'b', '|', 'a|', '|a', 'a|b', '1:a', '2:ab', ':', '10:x']
	mut seen := map[string]string{}
	for l in parts {
		for r in parts {
			k := compose_key(l, r)
			pair := '${l}␟${r}'
			if prev := seen[k] {
				assert prev == pair, 'collision: ${prev} and ${pair} both key to ${k}'
			}
			seen[k] = pair
		}
	}
	assert seen.len == parts.len * parts.len
}

fn test_decompose_is_the_inverse_of_compose() {
	cases := [
		['A', 'x'],
		['', ''],
		['A|x', 'y'],
		['A', 'x|y'],
		['1:2', '3:4'],
		['', 'vcan0'],
		['Powertrain', 'pcan:PCAN_USBBUS1@250000'],
	]
	for c in cases {
		k := compose_key(...c)
		got := decompose_key(k) or {
			assert false, 'compose_key(${c}) = "${k}" did not decompose'
			return
		}
		assert got == c, '${c} -> "${k}" -> ${got}'
	}
}

// THE PROPERTY THE KEY EXISTS FOR, from the other side: two different splittings of the same
// characters compose to different keys, so decomposing each returns its own parts.
fn test_a_separator_inside_a_part_round_trips() {
	a := compose_key('A|x', 'y')
	b := compose_key('A', 'x|y')
	assert a != b
	da := decompose_key(a) or {
		assert false, 'a did not decompose'
		return
	}
	db := decompose_key(b) or {
		assert false, 'b did not decompose'
		return
	}
	assert da == ['A|x', 'y']
	assert db == ['A', 'x|y']
}

fn test_decompose_refuses_what_compose_never_wrote() {
	// `2147483640:x` is the overflow case: added to `start` it wraps negative, so a bounds test
	// written as `start + n > key.len` passes and the slice panics instead of refusing.
	for bad in ['x', '3:ab', 'a:bc', '2:ab!3:cde', '-1:x', '2:ab|', '|2:ab', '2147483640:x',
		'2147483647:x', '9999999999:x',
		// An overflowing prefix followed straight by a separator: `.int()` wraps to 0 and the
		// rest parses happily, so this read as ['', 'x'] — a value compose_key never wrote.
		'4294967296:|1:x', '01:x', '1:x|007:abcdefg'] {
		if got := decompose_key(bad) {
			assert false, '"${bad}" decomposed to ${got}'
		}
	}
}

fn test_decompose_of_empty_is_no_parts() {
	got := decompose_key('') or {
		assert false, 'the empty key is what compose_key() with no parts writes'
		return
	}
	assert got == []
}
