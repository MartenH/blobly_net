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
