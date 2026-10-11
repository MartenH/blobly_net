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
