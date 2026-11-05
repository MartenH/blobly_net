// edit — what a panel needs to change a simulated node's signal: which frames the row publishes,
// and a value typed as the panel shows one.
module lin

import strconv
import blobly.lindb

// simulated_frames is the LDF's unconditional frames this row's simulated nodes publish, by name:
// the frames whose signals set_signal changes.
pub fn (r &Row) simulated_frames() []string {
	l := r.ldf or { return [] }
	return l.frames.filter(it.kind == .unconditional && r.sets(l, it)).map(it.name)
}

// sets is whether set_signal changes what this row publishes in frame f: a frame of the master
// node it simulates (only a master simulates it), or of a slave node it simulates.
fn (r &Row) sets(l lindb.Ldf, f lindb.Frame) bool {
	if f.publisher == l.master.name {
		return l.master.name in r.spec.simulate
	}
	return f.publisher in r.spec.simulate
}

// value_of_text is a signal value as typed: `raw:N`, `phys:X`, `text:...` and `bytes:01 02` as a
// decoded value is shown, or bare — a number is physical where the signal's encoding has a
// physical range and raw otherwise, anything else the text of a logical value or an ascii array.
pub fn value_of_text(ldf ?lindb.Ldf, signal string, text string) !lindb.Value {
	t := text.trim_space()
	if t == '' {
		return error('no value for ${signal}')
	}
	if t.starts_with('raw:') {
		return lindb.Value(raw_of(signal, t[4..])!)
	}
	if t.starts_with('phys:') {
		return lindb.Value(num_of(signal, t[5..])!)
	}
	if t.len >= 2 && t.starts_with('"') && t.ends_with('"') {
		return lindb.Value(t[1..t.len - 1])
	}
	if t.starts_with('text:') {
		return lindb.Value(t[5..])
	}
	if t.starts_with('bytes:') {
		mut out := []u8{}
		for part in t[6..].split(' ').filter(it != '') {
			if part.len > 2 || !part.bytes().all(it.is_hex_digit()) {
				return error('${signal}: `${part}` is not a byte in hex')
			}
			out << u8(strconv.parse_uint(part, 16, 8) or { 0 })
		}
		return lindb.Value(out)
	}
	if x := ldf {
		if sg := x.signal(signal) {
			if sg.is_array && t.contains(' ') == false && t.len > 2 && !is_number(t) {
				// a word for a byte array: its characters, as an ascii array takes them
				return lindb.Value(t)
			}
			if sg.is_array {
				parts := t.split(' ').filter(it != '')
				if parts.all(it.len <= 2 && it.bytes().all(it.is_hex_digit())) {
					return lindb.Value(parts.map(u8(strconv.parse_uint(it, 16, 8) or { 0 })))
				}
			}
		}
	}
	if t.starts_with('0x') || t.starts_with('0X') {
		return lindb.Value(raw_of(signal, t)!)
	}
	// a physical value as shown, its unit after it
	num := if has_physical(ldf, signal) && t.contains(' ') { t.all_before(' ') } else { t }
	if is_number(num) {
		if has_physical(ldf, signal) {
			return lindb.Value(num_of(signal, num)!)
		}
		return lindb.Value(raw_of(signal, num)!)
	}
	return lindb.Value(t)
}

// is_number is whether t is a decimal number or a 0x hex one: digits, a sign, a point, an
// exponent — not nan or inf.
fn is_number(t string) bool {
	if t.starts_with('0x') || t.starts_with('0X') {
		return t.len > 2 && t[2..].bytes().all(it.is_hex_digit())
	}
	if t == '' || !t.bytes().all(it.is_digit() || it in [`.`, `-`, `+`, `e`, `E`]) {
		return false
	}
	strconv.atof64(t) or { return false }
	return true
}

fn raw_of(signal string, t string) !u64 {
	s := t.trim_space()
	if s.starts_with('0x') || s.starts_with('0X') {
		return strconv.parse_uint(s[2..], 16, 64) or {
			error('${signal}: `${s}` is not a raw value')
		}
	}
	return strconv.parse_uint(s, 10, 64) or { error('${signal}: `${s}` is not a raw value') }
}

fn num_of(signal string, t string) !f64 {
	s := t.trim_space()
	return strconv.atof64(s) or { error('${signal}: `${s}` is not a number') }
}

// signal_text is a decoded signal as a panel shows it in one cell: `name=` its value_text.
pub fn signal_text(v lindb.SignalValue) string {
	return '${v.name}=${value_text(v)}'
}

// value_text is a decoded signal's value: the logical value's text, else the physical value and
// its unit, else a byte array's bytes in hex (an ascii or bcd one's text, quoted), else the raw
// value.
pub fn value_text(v lindb.SignalValue) string {
	if v.is_array {
		if v.text != '' {
			return '"${v.text}"'
		}
		return v.bytes.map('${it:02X}').join(' ')
	}
	if v.text != '' {
		return v.text
	}
	if p := v.physical {
		unit := if v.unit != '' { ' ${v.unit}' } else { '' }
		return '${lindb.fmt_num(p)}${unit}'
	}
	return '${v.raw}'
}
