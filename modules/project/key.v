module project

// compose_key joins parts into a key that is INJECTIVE: distinct inputs cannot produce the same
// string. A plain `a|b` join is not, whenever a part may contain the separator — and here they
// may, because channel names and interface addresses are free text in the editor. `A|x` on `y`
// and `A` on `x|y` would otherwise share a key, and these keys decide which DoIP entity is torn
// down, which diagnostic target a request goes to, and which tap a generator transmits through.
//
// Length-prefixing each part removes the ambiguity without escaping or forbidding characters:
// the reader knows where every part ends before it starts reading it.
pub fn compose_key(parts ...string) string {
	mut out := []string{cap: parts.len}
	for p in parts {
		out << '${p.len}:${p}'
	}
	return out.join('|')
}

// decompose_key reads a key back into the parts compose_key was given.
//
// THE INVERSE EXISTS BECAUSE THE KEY IS INJECTIVE, which is the whole point of the
// length-prefixing: a reader knows where each part ends before it starts reading it, so no part
// needs escaping and none can be confused with a separator inside another. Written as the inverse
// rather than as a `split('|')` for exactly that reason — a part containing `|` round-trips.
//
// `none` for anything this function did not produce: a truncated key, a bad length, a length that
// runs past the end. A caller reading a key from its own map cannot hit that, but a caller
// reading one from a file or a message can, and a silent partial answer there is worse than no
// answer at all.
pub fn decompose_key(key string) ?[]string {
	mut out := []string{}
	mut i := 0
	for i < key.len {
		mut colon := -1
		for j := i; j < key.len; j++ {
			if key[j] == `:` {
				colon = j
				break
			}
		}
		if colon < 0 {
			return none
		}
		digits := key[i..colon]
		if digits == '' || !is_all_digits(digits) {
			return none
		}
		n := digits.int()
		// AND THE DIGITS MUST BE WHAT THAT NUMBER LOOKS LIKE. `.int()` wraps rather than failing, so
		// `4294967296:` read as a length of ZERO and the rest of the key then parsed happily — a
		// value compose_key could never have written, accepted (codex round 9 on #142). The round
		// trip rejects that and a leading zero in one rule, since compose_key writes neither.
		if n.str() != digits {
			return none
		}
		start := colon + 1
		// BOUNDED BEFORE IT IS ADDED. `start + n` is i32 arithmetic, so a length prefix near the
		// top of the range — `2147483640:x` — wraps NEGATIVE and slips past a `start + n > key.len`
		// test, after which the slice panics. This function's contract is that it refuses what
		// compose_key never wrote, and a panic is not a refusal (self-review).
		if n < 0 || n > key.len - start {
			return none
		}
		out << key[start..start + n]
		i = start + n
		if i == key.len {
			break
		}
		if key[i] != `|` {
			return none
		}
		i++
		// A separator PROMISES another part. `2:ab|` would otherwise read as one part and stop,
		// which is a partial answer to a key compose_key never wrote — and this function's
		// contract is that it refuses those rather than guessing at them.
		if i >= key.len {
			return none
		}
	}
	return out
}
