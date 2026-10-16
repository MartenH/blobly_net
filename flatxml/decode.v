module flatxml

import strings

enum DecodeMode {
	text
	cdata // line endings only; `&` is literal
	attr  // entities, line endings, and whitespace read as spaces
}

@[inline]
fn needs_decode(raw string, cdata bool) bool {
	for c in raw {
		if c == `\r` || (c == `&` && !cdata) {
			return true
		}
	}
	return false
}

@[inline]
fn needs_attr_decode(raw string) bool {
	for c in raw {
		if c == `&` || c == `\r` || c == `\n` || c == `\t` {
			return true
		}
	}
	return false
}

// decode expands entity and character references and normalizes line endings. The parser has
// already checked every reference (`check_refs`), so a reference here is always well formed.
fn decode(raw string, mode DecodeMode) string {
	mut sb := strings.new_builder(raw.len)
	mut i := 0
	for i < raw.len {
		c := raw[i]
		if c == `\r` {
			sb.write_u8(if mode == .attr { ` ` } else { `\n` })
			i++
			if i < raw.len && raw[i] == `\n` {
				i++
			}
			continue
		}
		if mode == .attr && (c == `\n` || c == `\t`) {
			sb.write_u8(` `)
			i++
			continue
		}
		if c == `&` && mode != .cdata {
			mut semi := i + 1
			for raw[semi] != `;` {
				semi++
			}
			cp := ref_value(raw.str, i + 1, semi) or { 0xFFFD }
			if cp < 0x80 {
				sb.write_u8(u8(cp))
			} else {
				sb.write_rune(rune(cp))
			}
			i = semi + 1
			continue
		}
		sb.write_u8(c)
		i++
	}
	return sb.str()
}

// ref_value is the code point of the reference between `&` and `;` (s[a..b]): one of the five
// predefined entities, `#ddd` or `#xhh`.
fn ref_value(s &u8, a int, b int) ?u32 {
	n := b - a
	if n <= 0 {
		return none
	}
	unsafe {
		if s[a] == `#` {
			mut v := u64(0)
			if n > 1 && s[a + 1] == `x` {
				if n == 2 {
					return none
				}
				for k in a + 2 .. b {
					d := hex_digit(s[k]) or { return none }
					v = v * 16 + d
					if v > 0x10FFFF {
						return none
					}
				}
			} else {
				if n == 1 {
					return none
				}
				for k in a + 1 .. b {
					c := s[k]
					if c < `0` || c > `9` {
						return none
					}
					v = v * 10 + u64(c - `0`)
					if v > 0x10FFFF {
						return none
					}
				}
			}
			// XML 1.0 Char: no NUL, no other C0 controls but tab/LF/CR, no surrogates, no FFFE/FFFF
			if v == 0 || (v < 0x20 && v != 0x9 && v != 0xA && v != 0xD)
				|| (v >= 0xD800 && v <= 0xDFFF) || v == 0xFFFE || v == 0xFFFF {
				return none
			}
			return u32(v)
		}
		if n == 2 && s[a + 1] == `t` {
			if s[a] == `l` {
				return `<`
			}
			if s[a] == `g` {
				return `>`
			}
		}
		if n == 3 && s[a] == `a` && s[a + 1] == `m` && s[a + 2] == `p` {
			return `&`
		}
		if n == 4 && C.memcmp(s + a, c'apos', 4) == 0 {
			return `'`
		}
		if n == 4 && C.memcmp(s + a, c'quot', 4) == 0 {
			return `"`
		}
	}
	return none
}

@[inline]
fn hex_digit(c u8) ?u64 {
	if c >= `0` && c <= `9` {
		return u64(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return u64(c - `a` + 10)
	}
	if c >= `A` && c <= `F` {
		return u64(c - `A` + 10)
	}
	return none
}
