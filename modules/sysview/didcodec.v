module sysview

import strconv
import encoding.hex

// didcodec.v — a DID's value to the texts a tester edits and back, by the description's layout:
// ONE codec, so what the Diagnostics panel shows of a value and what it writes are the same
// reading. `texts` decodes a value into one text per editable part, `encode` is its inverse, and
// `encode(texts(b)) == b` for every value of the declared size (didcodec_test.v).
//
// The parts: a laid-out DID (a live signal, a parameter, a parameter status) has one per field,
// each an integer in decimal (a signed one may be negative) or `0x` hex, a `bool` as true/false;
// a text DID has one, the text; fixed bytes and a DID the description cannot lay out have one,
// the bytes in hex.

// Part is one editable part of a DID's value: its label and what it holds.
pub struct Part {
pub:
	label string
	hint  string // what it accepts: `u16 0..360`, `18 characters`, `hex bytes`
}

// laid_out: the value is its fields, back to back.
fn (x DidDesc) laid_out() bool {
	return x.kind in [.signal, .param, .param_status] && x.fields.len > 0
		&& x.fields.all(it.width() > 0)
}

// parts are the value's editable parts, in order.
pub fn (x DidDesc) parts() []Part {
	if x.laid_out() {
		return x.fields.map(Part{
			label: it.name
			hint:  field_hint(it, x.limit(it), it.name in x.ranges)
		})
	}
	if x.kind == .ascii {
		return [Part{
			label: 'text'
			hint:  if x.size >= 0 { 'up to ${x.size} characters' } else { 'text' }
		}]
	}
	return [
		Part{
			label: 'bytes'
			hint:  if x.size >= 0 { '${x.size} bytes, hex' } else { 'hex' }
		},
	]
}

// texts decodes `data` into one text per part. An error when it is not the declared size: the
// caller shows the bytes.
pub fn (x DidDesc) texts(data []u8) ![]string {
	if x.size >= 0 && data.len != x.size {
		return error('${data.len} byte(s), the description says ${x.size}')
	}
	if x.laid_out() {
		mut out := []string{}
		mut at := 0
		for f in x.fields {
			w := f.width()
			out << field_value(f, data[at..at + w])
			at += w
		}
		return out
	}
	if x.kind == .ascii {
		// a fixed-size text is padded with NULs, which an edit field cannot hold: they are what
		// `encode` pads a shorter text with
		mut n := data.len
		for n > 0 && data[n - 1] == 0 {
			n--
		}
		return [data[..n].bytestr()]
	}
	return [hex_text(data)]
}

// encode is `texts`' inverse: the value the parts spell, refused (naming the part) when one is
// not what its field holds — not a number, outside the field's width, outside the description's
// range, or not the declared size.
pub fn (x DidDesc) encode(texts []string) ![]u8 {
	ps := x.parts()
	if texts.len != ps.len {
		return error('${texts.len} part(s) for ${ps.len}')
	}
	mut out := []u8{}
	if x.laid_out() {
		for i, f in x.fields {
			out << field_bytes(f, texts[i], x.limit(f), f.name in x.ranges) or {
				return error('${f.name}: ${err.msg()}')
			}
		}
	} else if x.kind == .ascii {
		out = texts[0].bytes()
		if x.size >= 0 && out.len < x.size {
			out << []u8{len: x.size - out.len} // NUL-padded to its size, as `texts` reads it
		}
	} else {
		out = parse_hex(texts[0]) or { return error('bytes: ${err.msg()}') }
	}
	if x.size >= 0 && out.len != x.size {
		return error('${out.len} byte(s), the description says ${x.size}')
	}
	return out
}

// limit is what a field may hold: its type's range, narrowed by the description's where it
// declares one — never widened, so a range past the field's width cannot let a value through
// that the bytes then truncate.
fn (x DidDesc) limit(f Field) Range {
	t := field_range(f)
	r := x.ranges[f.name] or { return t }
	return Range{
		min: if r.min > t.min { r.min } else { t.min }
		max: if r.max < t.max { r.max } else { t.max }
	}
}

// field_range is everything a field's type holds (a u64's upper half is past an i64: its range
// is bounded by the unsigned parse, and a declared range is checked against it there).
fn field_range(f Field) Range {
	return match f.typ {
		'bool' { Range{0, 1} }
		'u8' { Range{0, 0xFF} }
		'u16' { Range{0, 0xFFFF} }
		'u32' { Range{0, i64(0xFFFF_FFFF)} }
		'i8' { Range{-i64(0x80), 0x7F} }
		'i16' { Range{-i64(0x8000), 0x7FFF} }
		'i32' { Range{-i64(0x8000_0000), 0x7FFF_FFFF} }
		'u64' { Range{0, max_i64} }
		else { Range{min_i64, max_i64} } // i64: bounded by the parse itself
	}
}

fn field_hint(f Field, r Range, declared bool) string {
	if f.typ == 'bool' {
		return 'bool'
	}
	if f.typ in ['u64', 'i64'] && !declared {
		return f.typ
	}
	return '${f.typ} ${r.min}..${r.max}'
}

// field_bytes is one field's big-endian bytes from its text, within `lim`.
// `declared`: the description gives this field a range. A u64 is checked against it only then —
// its type's own range is the unsigned parse, which no i64 bound can state, so no value of `lim`
// may stand for "unbounded" (max_i64 is a bound a description may declare).
fn field_bytes(f Field, text string, lim Range, declared bool) ![]u8 {
	t := text.trim_space()
	w := f.width()
	if w == 0 {
		return error('a ${f.typ} is not carried in a DID')
	}
	mut v := u64(0)
	if f.typ == 'bool' {
		v = match t.to_lower() {
			'true', '1' { u64(1) }
			'false', '0' { u64(0) }
			else { return error('"${t}" is not true or false') }
		}
	} else if f.typ == 'u64' {
		v = parse_unsigned(t)!
		if declared && ((lim.min > 0 && v < u64(lim.min)) || lim.max < 0 || v > u64(lim.max)) {
			return error('${v} is outside ${lim.min}..${lim.max}')
		}
	} else {
		n := parse_signed(t)!
		if n < lim.min || n > lim.max {
			return error('${n} is outside ${lim.min}..${lim.max}')
		}
		v = u64(n)
	}
	mut out := []u8{len: w}
	for i in 0 .. w {
		out[w - 1 - i] = u8(v >> (8 * i))
	}
	return out
}

// parse_signed reads a decimal integer, optionally negative, or `0x` hex.
fn parse_signed(t string) !i64 {
	if t.starts_with('0x') || t.starts_with('0X') {
		u := strconv.parse_uint(t[2..], 16, 64) or { return error('"${t}" is not a number') }
		if u > u64(max_i64) {
			return error('${t} is too large')
		}
		return i64(u)
	}
	return strconv.parse_int(t, 10, 64) or { error('"${t}" is not a number') }
}

fn parse_unsigned(t string) !u64 {
	if t.starts_with('0x') || t.starts_with('0X') {
		return strconv.parse_uint(t[2..], 16, 64) or { error('"${t}" is not a number') }
	}
	return strconv.parse_uint(t, 10, 64) or { error('"${t}" is not a non-negative number') }
}

// hex_text is bytes as spaced upper-case hex, as parse_hex reads them.
pub fn hex_text(b []u8) string {
	return b.map('${it:02X}').join(' ')
}

// parse_hex reads hex bytes, spaced or not (`01 2C`, `012C`, `0x012C`).
pub fn parse_hex(t string) ![]u8 {
	mut s := t.replace(' ', '')
	if s.starts_with('0x') || s.starts_with('0X') {
		s = s[2..]
	}
	if s.len % 2 != 0 {
		return error('"${t}" is not whole bytes')
	}
	return hex.decode(s) or { error('"${t}" is not hex') }
}
