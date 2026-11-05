// encode — a frame's bytes from signal values and back, by the LDF's encodings. LIN signals are
// little-endian: a scalar's least significant bit sits at its offset and the bits run upwards
// through the frame (bit k of the frame is bit k%8 of byte k/8); a byte array's byte j occupies
// the eight bits from offset + 8j. Bits no signal covers are recessive, 1.
module lindb

import math
import strings
import encoding.hex

// Value is what a caller sets a signal to: a raw value (`u64`), a physical one through the
// signal's physical_value ranges (`f64`), a logical value's text or an ascii/bcd array's
// characters (`string`), or a byte array's bytes (`[]u8`).
pub type Value = []u8 | f64 | string | u64

// SignalValue is one signal decoded from a frame. `raw` is the field (for a bcd array, the
// number its digits spell); `bytes` a byte array's bytes; `physical` the value through the
// physical range the raw value falls in; `text` the logical value's description, or the
// characters of an ascii array or digits of a bcd one; `unit` the physical range's unit.
pub struct SignalValue {
pub:
	name     string
	raw      u64
	bytes    []u8
	is_array bool
	physical ?f64
	text     string
	unit     string
}

fn get_bits(data []u8, offset int, width int) u64 {
	mut v := u64(0)
	for i in 0 .. width {
		bit := offset + i
		if (data[bit >> 3] >> u8(bit & 7)) & 1 == 1 {
			v |= u64(1) << u64(i)
		}
	}
	return v
}

fn set_bits(mut data []u8, offset int, width int, v u64) {
	for i in 0 .. width {
		bit := offset + i
		mask := u8(1) << u8(bit & 7)
		if (v >> u64(i)) & 1 == 1 {
			data[bit >> 3] |= mask
		} else {
			data[bit >> 3] &= ~mask
		}
	}
}

fn put(mut data []u8, s Signal, offset int, raw u64, bytes []u8) {
	if s.is_array {
		for j, b in bytes {
			set_bits(mut data, offset + 8 * j, 8, b)
		}
	} else {
		set_bits(mut data, offset, s.width, raw)
	}
}

// template is the frame's bytes with every mapped signal at its init value and every other bit
// recessive — but byte 0 of a frame an event-triggered frame carries, which is the frame's own
// protected id (LIN 2.2A §2.3.3.2; resolve keeps signals out of that byte).
pub fn (l &Ldf) template(f Frame) []u8 {
	mut data := []u8{len: f.length, init: 0xFF}
	if f.length > 0 && l.is_tied(f.name) {
		data[0] = protected_id(f.id)
	}
	for m in f.signals {
		s := l.signal(m.name) or { continue }
		put(mut data, s, m.offset, s.init, s.init_bytes)
	}
	return data
}

fn (l &Ldf) rules_of(s Signal) []EncRule {
	if s.encoding == '' {
		return []
	}
	e := l.encoding(s.encoding) or { return [] }
	return e.rules
}

// decode reads every signal of the frame that `data` holds whole; the first rule of the
// signal's encoding that the raw value satisfies gives its reading, in the file's order.
pub fn (l &Ldf) decode(f Frame, data []u8) []SignalValue {
	mut out := []SignalValue{}
	for m in f.signals {
		s := l.signal(m.name) or { continue }
		if m.offset + s.width > data.len * 8 {
			continue
		}
		rules := l.rules_of(s)
		if s.is_array {
			mut bytes := []u8{len: s.width / 8}
			for j in 0 .. bytes.len {
				bytes[j] = u8(get_bits(data, m.offset + 8 * j, 8))
			}
			mut text := ''
			mut raw := u64(0)
			for rule in rules {
				if rule.kind == .ascii && bytes.all(it < 0x80) {
					text = bytes.bytestr()
					break
				}
				if rule.kind == .bcd && bytes.all(it <= 9) {
					text = bytes.map(u8(`0`) + it).bytestr()
					raw = text.u64()
					break
				}
			}
			out << SignalValue{
				name:     s.name
				raw:      raw
				bytes:    bytes
				is_array: true
				text:     text
			}
			continue
		}
		raw := get_bits(data, m.offset, s.width)
		mut v := SignalValue{
			name: s.name
			raw:  raw
		}
		for rule in rules {
			if rule.kind == .logical && raw == rule.lo {
				v = SignalValue{
					...v
					text: rule.text
				}
				break
			}
			if rule.kind == .physical && raw >= rule.lo && raw <= rule.hi {
				v = SignalValue{
					...v
					physical: f64(raw) * rule.scale + rule.offset
					unit:     rule.text
				}
				break
			}
		}
		out << v
	}
	return out
}

// encode is the frame's template with the given signals set. A value its signal cannot take is
// refused by name: a raw value wider than the signal, a physical value no range of its encoding
// reaches, a text no logical value names, a byte array of the wrong length.
pub fn (l &Ldf) encode(f Frame, values map[string]Value) ![]u8 {
	mut data := l.template(f)
	for name, v in values {
		mut mapped := ?Mapped(none)
		for m in f.signals {
			if m.name == name {
				mapped = m
			}
		}
		m := mapped or { return error('frame ${f.name} carries no signal ${name}') }
		s := l.signal(name) or { return error('frame ${f.name} carries no signal ${name}') }
		if s.is_array {
			bytes := l.array_bytes(s, v)!
			put(mut data, s, m.offset, 0, bytes)
		} else {
			raw := l.scalar_raw(s, v)!
			put(mut data, s, m.offset, raw, [])
		}
	}
	return data
}

fn fits(raw u64, width int) bool {
	return width >= 64 || raw >> u64(width) == 0
}

fn (l &Ldf) scalar_raw(s Signal, v Value) !u64 {
	rules := l.rules_of(s)
	match v {
		u64 {
			if !fits(v, s.width) {
				return error('signal ${s.name}: raw ${v} does not fit ${s.width} bits')
			}
			return v
		}
		f64 {
			if math.is_nan(v) || math.is_inf(v, 0) {
				return error('signal ${s.name}: ${v} is not a finite number')
			}
			for rule in rules {
				if rule.kind != .physical {
					continue
				}
				if rule.scale == 0 {
					if v == rule.offset && fits(rule.lo, s.width) {
						return rule.lo
					}
					continue
				}
				q := (v - rule.offset) / rule.scale
				if q < -0.5 || q > 1.8446744073709552e19 {
					continue
				}
				raw := u64(q + 0.5)
				if raw >= rule.lo && raw <= rule.hi && fits(raw, s.width) {
					return raw
				}
			}
			return error('signal ${s.name}: ${fmt_num(v)} is in no physical range of encoding ${if s.encoding == '' {
				'(none)'
			} else {
				s.encoding
			}}')
		}
		string {
			for rule in rules {
				if rule.kind == .logical && rule.text == v && fits(rule.lo, s.width) {
					return rule.lo
				}
			}
			return error('signal ${s.name}: no logical value "${v}" in encoding ${if s.encoding == '' {
				'(none)'
			} else {
				s.encoding
			}}')
		}
		[]u8 {
			return error('signal ${s.name} is a scalar, not a byte array')
		}
	}
}

fn (l &Ldf) array_bytes(s Signal, v Value) ![]u8 {
	n := s.width / 8
	rules := l.rules_of(s)
	match v {
		[]u8 {
			if v.len != n {
				return error('signal ${s.name}: ${v.len} bytes for a ${n}-byte array')
			}
			return v.clone()
		}
		string {
			for rule in rules {
				if rule.kind == .ascii {
					if v.len != n || !v.bytes().all(it < 0x80) {
						return error('signal ${s.name}: "${v}" is not ${n} ASCII characters')
					}
					return v.bytes()
				}
				if rule.kind == .bcd {
					if v == '' || v.len > n || !v.bytes().all(it.is_digit()) {
						return error('signal ${s.name}: "${v}" is not at most ${n} decimal digits')
					}
					padded := '0'.repeat(n - v.len) + v
					return padded.bytes().map(u8(it - `0`))
				}
			}
			return error('signal ${s.name}: a text needs an ascii or bcd encoding')
		}
		u64 {
			for rule in rules {
				if rule.kind == .bcd {
					return l.array_bytes(s, Value(v.str()))
				}
			}
			return error('signal ${s.name} is a byte array; give its bytes')
		}
		f64 {
			return error('signal ${s.name} is a byte array; give its bytes')
		}
	}
}

// --- the dump: one line per fact, the form `sut/ldf_oracle.py` prints ------------------------

fn opt_ms(v ?f64) string {
	if x := v {
		return fmt_num(x)
	}
	return '-'
}

fn hex_bytes(b []u8) string {
	return b.map('${it:02X}').join('')
}

// dump is the model as one line per fact, in a stable order: header, nodes, signals, encodings,
// frames (by id) with their signals (by offset) and templates, event-triggered and sporadic
// frames, schedules in file order. A value not read prints `-`.
pub fn (l &Ldf) dump() string {
	mut b := strings.new_builder(4096)
	speed := if v := l.speed_bps { '${v}' } else { '-' }
	b.writeln('header protocol=${or_dash(l.protocol_version)} language=${or_dash(l.language_version)} speed_bps=${speed} channel=${or_dash(l.channel)}')
	b.writeln('master ${or_dash(l.master.name)} time_base_ms=${opt_ms(l.master.time_base_ms)} jitter_ms=${opt_ms(l.master.jitter_ms)}')
	b.writeln('slaves ${l.slaves.join(',')}')
	mut nodes := l.nodes.clone()
	nodes.sort(a.name < b.name)
	for n in nodes {
		cnad := if v := n.configured_nad { '0x${v:02X}' } else { '-' }
		inad := if v := n.initial() { '0x${v:02X}' } else { '-' }
		prod := if p := n.product {
			'0x${p.supplier:04X},0x${p.function:04X},${if v := p.variant { '${v}' } else { '-' }}'
		} else {
			'-'
		}
		frames := n.configurable_frames.map(fn (c ConfigurableFrame) string {
			return if id := c.message_id { '${c.name}=0x${id:04X}' } else { c.name }
		}).join(',')
		b.writeln('node ${n.name} protocol=${or_dash(n.protocol)} configured_nad=${cnad} initial_nad=${inad} product=${prod} response_error=${or_dash(n.response_error)} fault_state=${n.fault_state_signals.join(',')} p2_min_ms=${fmt_num(n.p2_min())} st_min_ms=${fmt_num(n.st_min())} n_as_ms=${fmt_num(n.n_as_timeout())} n_cr_ms=${fmt_num(n.n_cr_timeout())} frames=${frames}')
	}
	mut sigs := l.signals.clone()
	sigs.sort(a.name < b.name)
	for s in sigs {
		init := if s.is_array {
			'{' + s.init_bytes.map('${it}').join(',') + '}'
		} else {
			'${s.init}'
		}
		b.writeln('signal ${s.name} width=${s.width} init=${init} publisher=${or_dash(s.publisher)} subscribers=${s.subscribers.join(',')} encoding=${or_dash(s.encoding)}')
	}
	mut encs := l.encodings.clone()
	encs.sort(a.name < b.name)
	for e in encs {
		for r in e.rules {
			match r.kind {
				.logical {
					b.writeln('encoding ${e.name} logical value=${r.lo} text=${r.text}')
				}
				.physical {
					b.writeln('encoding ${e.name} physical min=${r.lo} max=${r.hi} scale=${fmt_num(r.scale)} offset=${fmt_num(r.offset)} unit=${r.text}')
				}
				.bcd {
					b.writeln('encoding ${e.name} bcd')
				}
				.ascii {
					b.writeln('encoding ${e.name} ascii')
				}
			}
		}
	}
	mut frames := l.frames.clone()
	frames.sort(a.id < b.id)
	for f in frames {
		cs := if c := l.checksum_model_for(f.id) { '${c}' } else { '-' }
		kind := if f.kind == .diagnostic { 'diag-frame' } else { 'frame' }
		b.writeln('${kind} ${f.name} id=0x${f.id:02X} publisher=${or_dash(f.publisher)} len=${f.length} checksum=${cs}')
		mut maps := f.signals.clone()
		maps.sort(a.offset < b.offset)
		for m in maps {
			s := l.signal(m.name) or { continue }
			b.writeln('frame-signal ${f.name} ${m.name} offset=${m.offset} width=${s.width}')
		}
		b.writeln('template ${f.name} ${hex_bytes(l.template(f))}')
	}
	for e in l.event_frames {
		cs := if c := l.checksum_model_for(e.id) { '${c}' } else { '-' }
		b.writeln('event ${e.name} id=0x${e.id:02X} table=${or_dash(e.table)} frames=${e.frames.join(',')} checksum=${cs}')
	}
	for s in l.sporadic_frames {
		b.writeln('sporadic ${s.name} frames=${s.frames.join(',')}')
	}
	for s in l.schedules {
		for i, slot in s.slots {
			what := if slot.kind == .command {
				'command ${slot.command}'
			} else {
				'${slot.kind} ${slot.frame}'
			}
			b.writeln('schedule ${s.name} ${i} ${what} delay_ms=${fmt_num(slot.delay_ms)}')
		}
	}
	return b.str()
}

fn or_dash(s string) string {
	return if s == '' { '-' } else { s }
}

// query answers one request in the line form `sut/ldf_oracle.py` diffs:
// `encode|<frame>|<signal>=<kind>:<value>|...` (kind raw, phys, text, or bytes as hex) answers
// `<request> -> <hex>` or `-> error`; `decode|<frame>|<hex>` answers
// `decode <frame> <hex> -> <signal values>`. In a value, `\|`, `\=` and `\\` stand for the
// character itself.
pub fn (l &Ldf) query(request string) string {
	parts := split_escaped(request, `|`)
	if parts.len < 3 || parts[0] !in ['encode', 'decode'] {
		return '${request} -> bad request'
	}
	f := l.frame(parts[1]) or { return '${request} -> no frame' }
	if parts[0] == 'decode' {
		data := hex.decode(parts[2]) or { return '${request} -> bad request' }
		return 'decode ${f.name} ${parts[2]} -> ${l.decode(f, data).map(it.str()).join(' ')}'
	}
	mut values := map[string]Value{}
	for p in parts[2..] {
		pair := split_escaped(p, `=`)
		if pair.len < 2 {
			return '${request} -> bad request'
		}
		name := unescape(pair[0])
		rest := pair[1..].join('=')
		kind := rest.all_before(':')
		v := unescape(rest.all_after(':'))
		values[name] = match kind {
			'raw' { Value(parse_uint(v) or { return '${request} -> bad request' }) }
			'phys' { Value(parse_number(v) or { return '${request} -> bad request' }) }
			'bytes' { Value(hex.decode(v) or { return '${request} -> bad request' }) }
			'text' { Value(v) }
			else { return '${request} -> bad request' }
		}
	}
	bytes := l.encode(f, values) or { return '${request} -> error' }
	return '${request} -> ${hex_bytes(bytes)}'
}

// split_escaped splits at every `sep` no backslash escapes, keeping the escapes in the parts.
fn split_escaped(s string, sep u8) []string {
	mut out := []string{}
	mut start := 0
	mut i := 0
	for i < s.len {
		if s[i] == `\\` {
			i += 2
			continue
		}
		if s[i] == sep {
			out << s[start..i]
			start = i + 1
		}
		i++
	}
	out << s[start..]
	return out
}

// str is a decoded value as the dump and the oracle print it.
pub fn (v SignalValue) str() string {
	mut s := '${v.name}='
	if v.is_array {
		s += 'bytes:${hex_bytes(v.bytes)}'
	} else {
		s += 'raw:${v.raw}'
	}
	if p := v.physical {
		s += ' phys:${fmt_num(p)}'
		if v.unit != '' {
			s += ' unit:${v.unit}'
		}
	}
	if v.text != '' {
		s += ' text:${v.text}'
	}
	return s
}
