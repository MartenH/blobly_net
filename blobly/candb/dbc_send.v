// dbc_send — the DBC attributes that say when and with what a node sends a message: a message's
// GenMsgSendType, GenMsgCycleTimeFast, GenMsgNrOfRepetition, GenMsgDelayTime,
// GenMsgStartDelayTime and the BA_DEF_DEF_ of GenMsgCycleTime, and a signal's GenSigStartValue.
// Read after the whole file, because a DBC does not promise its records' order and an ENUM's
// index means nothing until its BA_DEF_ is known.
module candb

import strconv

// send_int_attrs are the message attributes this reader keeps as a whole number of ms (or a count).
const send_int_attrs = ['GenMsgCycleTimeFast', 'GenMsgNrOfRepetition', 'GenMsgDelayTime',
	'GenMsgStartDelayTime']

// send_type_choices is the GenMsgSendType enum the writer declares (Vector's), a choice the
// database uses that is not in it appended; its first entry is the definition's default.
const send_type_choices = ['cyclic', 'spontaneous', 'cyclicIfActive', 'spontaneousWithDelay',
	'cyclicAndSpontaneous', 'cyclicAndSpontaneousWithDelay', 'spontaneousWithRepetition',
	'cyclicIfActiveAndSpontaneousWD', 'cyclicIfActiveFast', 'cyclicWithRepeatOnDemand', 'none']

// SendAttrs collects the records while the file is read.
struct SendAttrs {
mut:
	lines         []string          // BA_ records of the message attributes, GenMsgSendType included
	defaults      map[string]string // BA_DEF_DEF_ values by attribute name, GenMsgCycleTime included
	choices       []string          // GenMsgSendType's ENUM as this file declares it
	start_lines   []string          // BA_ "GenSigStartValue" SG_ records
	start_default string            // its BA_DEF_DEF_ value
}

// attr_record is an attribute record (BA_, BA_DEF_, BA_DEF_DEF_) with every run of blanks outside
// its quoted strings made one space, as the record readers match it: CANdb++ writes
// `BA_DEF_ BO_  "GenMsgSendType" ENUM  "cyclic",...` and `BA_DEF_DEF_  "GenMsgCycleTime" 0;`.
// Any other line is returned as it is.
fn attr_record(line string) string {
	if !line.starts_with('BA_') || (!line.contains('  ') && !line.contains('\t')) {
		return line
	}
	mut b := []u8{cap: line.len}
	mut quoted := false
	for c in line {
		if c == `"` {
			quoted = !quoted
		} else if !quoted && (c == ` ` || c == `\t`) {
			if b.len > 0 && b[b.len - 1] == ` ` {
				continue
			}
			b << ` `
			continue
		}
		b << c
	}
	return b.bytestr()
}

// take keeps `line` when it is one of these records.
fn (mut c SendAttrs) take(line string) bool {
	if line.starts_with('BA_DEF_DEF_ "') {
		f := line.trim_right(';').fields()
		if f.len < 3 {
			return false
		}
		name := f[1].trim('"')
		value := f[2..].join(' ').trim_space()
		if name == 'GenSigStartValue' {
			c.start_default = value
			return true
		}
		if name == 'GenMsgCycleTime' || name == 'GenMsgSendType' || name in send_int_attrs {
			c.defaults[name] = value
			return true
		}
		return false
	}
	if line.starts_with('BA_DEF_ BO_ "GenMsgSendType"') {
		c.choices = frame_format_choices(line)
		return true
	}
	if line.starts_with('BA_ "GenSigStartValue"') {
		c.start_lines << line
		return true
	}
	if line.starts_with('BA_ "GenMsgSendType"') {
		c.lines << line
		return true
	}
	for a in send_int_attrs {
		if line.starts_with('BA_ "${a}"') {
			c.lines << line
			return true
		}
	}
	return false
}

// resolve sets what the records say on the messages and signals, a message's or signal's own
// record first and a BA_DEF_DEF_ for the rest, and returns a note per value it could not read.
fn (c SendAttrs) resolve(mut msgs []MsgBuilder, by_id map[u32]int) []string {
	mut notes := []string{}
	mut stated := map[string]bool{} // '<index> <attribute>': a message stated it
	for line in c.lines {
		f := line.trim_right(';').fields()
		// f: BA_ "<name>" BO_ <id> <value>
		if f.len < 5 || f[2] != 'BO_' {
			continue
		}
		idx := by_id[u32(f[3].u64())] or { continue }
		name := f[1].trim('"')
		value := f[4..].join(' ')
		stated['${idx} ${name}'] = true
		set_send_attr(mut msgs[idx], name, value, c.choices) or {
			notes << '${msgs[idx].name}: ${name} ${value} ${err.msg()}; not read, and a Save drops it'
		}
	}
	for name, value in c.defaults {
		for i, mut mb in msgs {
			if '${i} ${name}' in stated || (name == 'GenMsgCycleTime' && mb.cycle_stated) {
				continue
			}
			set_send_attr(mut mb, name, value, c.choices) or {
				notes << 'BA_DEF_DEF_ ${name} ${value} ${err.msg()}; not read'
				break
			}
		}
	}
	for line in c.start_lines {
		f := line.trim_right(';').fields()
		// f: BA_ "GenSigStartValue" SG_ <id> <signal> <value>
		if f.len < 6 || f[2] != 'SG_' {
			continue
		}
		mi := by_id[u32(f[3].u64())] or { continue }
		si := signal_index(msgs[mi], f[4]) or { continue }
		sb := msgs[mi].sigs[si]
		if raw := start_raw_of(sb.length, sb.is_signed, f[5]) {
			msgs[mi].sigs[si].start_raw = raw
			msgs[mi].sigs[si].has_start = true
		} else {
			notes << '${msgs[mi].name}.${sb.name}: GenSigStartValue ${f[5]} is not a raw value its ${sb.length} bits hold; not read, and a Save drops it'
		}
	}
	// the file-wide default, for every signal that states none
	if c.start_default != '' {
		mut misfits := 0
		if start_raw_of(64, true, c.start_default) == none {
			notes << 'BA_DEF_DEF_ GenSigStartValue ${c.start_default} is not a raw value; not read'
		} else {
			for mut mb in msgs {
				for mut sb in mb.sigs {
					if sb.has_start {
						continue
					}
					if raw := start_raw_of(sb.length, sb.is_signed, c.start_default) {
						sb.start_raw = raw
						sb.has_start = true
					} else {
						misfits++
					}
				}
			}
		}
		if misfits > 0 {
			notes << 'BA_DEF_DEF_ GenSigStartValue ${c.start_default} does not fit ${misfits} signal(s) that state none; they start at raw 0'
		}
	}
	return notes
}

// set_send_attr sets one message attribute from its value, or says why it is not one.
fn set_send_attr(mut mb MsgBuilder, name string, value string, choices []string) ! {
	if name == 'GenMsgSendType' {
		mb.send_type_name = enum_choice(value, choices)!
		return
	}
	n := attr_count(value) or { return error('is not a whole number') }
	match name {
		'GenMsgCycleTime' { mb.cycle_ms = n }
		'GenMsgCycleTimeFast' { mb.cycle_fast_ms = n }
		'GenMsgNrOfRepetition' { mb.repetitions = n }
		'GenMsgDelayTime' { mb.delay_ms = n }
		'GenMsgStartDelayTime' { mb.start_delay_ms = n }
		else {}
	}
}

// enum_choice is the choice an ENUM attribute's value names: the quoted choice, or its index in
// the file's own BA_DEF_.
fn enum_choice(value string, choices []string) !string {
	v := value.trim_space()
	if v.len >= 2 && v.starts_with('"') && v.ends_with('"') {
		return v[1..v.len - 1]
	}
	i := attr_count(v) or { return error('is neither a choice nor an index') }
	if choices.len == 0 {
		return error('is an index and the file declares no ENUM for it')
	}
	if i >= choices.len {
		return error('is past the ${choices.len} choices the file declares')
	}
	return choices[i]
}

// attr_count reads a whole, non-negative number an int holds ('100', or '100.0').
fn attr_count(text string) ?int {
	raw := start_raw_of(31, false, text)?
	return int(raw)
}

// start_raw_of reads a GenSigStartValue for a signal of `length` bits: a whole number (a decimal
// spelling of one too, '3.0') its width holds, as the field's bits — a negative one only for a
// signed signal, as its two's complement.
fn start_raw_of(length int, signed bool, text string) ?u64 {
	if length <= 0 || length > 64 {
		return none
	}
	mut digits := text.trim_space()
	neg := digits.starts_with('-')
	if neg || digits.starts_with('+') {
		digits = digits[1..]
	}
	if i := digits.index('.') {
		frac := digits[i + 1..]
		if !frac.bytes().all(it == `0`) {
			return none
		}
		digits = digits[..i]
	}
	if digits == '' || !digits.bytes().all(it.is_digit()) {
		return none
	}
	v := strconv.parse_uint(digits, 10, 64) or { return none }
	mask := if length >= 64 { ~u64(0) } else { (u64(1) << length) - 1 }
	if neg && v != 0 {
		if !signed || v > u64(1) << (length - 1) {
			return none
		}
		return (~v + 1) & mask
	}
	if v > mask {
		return none
	}
	return v
}

// send_type_enum is the GenMsgSendType definition the writer declares for `used`, the choices
// the database's messages name.
fn send_type_enum(used []string) []string {
	mut out := send_type_choices.clone()
	mut extra := used.filter(it != '' && it !in out)
	extra.sort()
	for e in extra {
		if e !in out {
			out << e
		}
	}
	return out
}

// send_type_attr is GenMsgSendType as the writer declares it, none where no message names one. A
// message naming the default choice, or none, is left to the default.
fn send_type_attr(msgs []Message) ?DbcAttr {
	used := msgs.map(it.send_type_name)
	if used.all(it == '') {
		return none
	}
	choices := send_type_enum(used)
	mut a := DbcAttr{
		name:    'GenMsgSendType'
		typ:     'ENUM ' + choices.map('"${it}"').join(',')
		default: '"${choices[0]}"'
	}
	for m in msgs {
		if m.send_type_name != '' && m.send_type_name != choices[0] {
			a.values << DbcAttrValue{m.id, m.ext, '${choices.index(m.send_type_name)}'}
		}
	}
	return a
}

// send_int_attr is one of send_int_attrs as the writer declares it, none where no message has it.
fn send_int_attr(msgs []Message, name string) ?DbcAttr {
	mut a := DbcAttr{
		name:    name
		default: '0'
	}
	mut most := 65535
	for m in msgs {
		v := match name {
			'GenMsgCycleTimeFast' { m.cycle_fast_ms }
			'GenMsgNrOfRepetition' { m.repetitions }
			'GenMsgDelayTime' { m.delay_ms }
			else { m.start_delay_ms }
		}
		if v > 0 {
			a.values << DbcAttrValue{m.id, m.ext, '${v}'}
			if v > most {
				most = v
			}
		}
	}
	if a.values.len == 0 {
		return none
	}
	a.typ = 'INT 0 ${most}'
	return a
}

// start_value_lines is GenSigStartValue as the writer declares it: its definition, a default of 0
// and a record per signal starting elsewhere, nothing where no signal states one. Signed values
// are written signed.
fn start_value_lines(msgs []Message) ?[]string {
	mut vals := []string{}
	mut lo := i64(0)
	mut hi := u64(0)
	mut any := false
	for m in msgs {
		mut sigs := m.signals.clone()
		sigs.sort_with_compare(fn (a &Signal, b &Signal) int {
			return a.name.compare(b.name)
		})
		for s in sigs {
			if !s.has_start {
				continue
			}
			any = true
			mask := if s.length >= 64 { ~u64(0) } else { (u64(1) << s.length) - 1 }
			raw := s.start_raw & mask
			if raw == 0 {
				continue
			}
			mut text := '${raw}'
			if s.is_signed && s.length > 0 && raw & (u64(1) << (s.length - 1)) != 0 {
				v := sext(raw, mask, u64(1) << (s.length - 1))
				text = '${v}'
				if v < lo {
					lo = v
				}
			} else if raw > hi {
				hi = raw
			}
			vals << 'BA_ "GenSigStartValue" SG_ ${raw_dbc_id(m)} ${s.name} ${text};'
		}
	}
	if !any {
		return none
	}
	if hi < 65535 {
		hi = 65535
	}
	mut out := ['BA_DEF_ SG_ "GenSigStartValue" INT ${lo} ${hi};', 'BA_DEF_DEF_ "GenSigStartValue" 0;']
	out << vals
	return out
}
