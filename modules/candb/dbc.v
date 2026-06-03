// dbc — a pragmatic parser for the DBC (CAN database) file format, producing the
// candb Message/Signal model the rest of the tester decodes against. This is the
// Phase 5 replacement for the hand-coded `sampledb` catalog: load real .dbc files
// instead of describing layouts in V.
//
// Supported today (the subset our messages need + the common cases):
//   BO_  <id> <Name>: <dlc> <transmitter>            — message definition
//   SG_  <Name> [mux] : <start>|<len>@<order><sign> (<factor>,<offset>)
//                       [<min>|<max>] "<unit>" <receivers>   — signal definition
//   VAL_ <id> <Signal> <int> "label" <int> "label" … ;       — value table (enum)
//   CM_ SG_ <id> <Signal> "comment" ;                        — signal description
// @order: 1 = Intel/little-endian, 0 = Motorola/big-endian.  sign: + unsigned, - signed.
// Multiplexor markers (M / m<n>) are tolerated but not yet modelled. Other DBC
// records (BU_, BA_, network attrs, …) are ignored.
module candb

import os

// Database is a parsed set of CAN messages with id lookup.
pub struct Database {
pub:
	messages []Message
}

// lookup returns the message defined for `id`, if any.
pub fn (db Database) lookup(id u32) ?Message {
	for m in db.messages {
		if m.id == id {
			return m
		}
	}
	return none
}

// load_dbc_file reads and parses a .dbc file from disk.
pub fn load_dbc_file(path string) !Database {
	return parse_dbc(os.read_file(path)!)!
}

// --- internal mutable builders (final Message/Signal are immutable) ----------

struct SigBuilder {
mut:
	name       string
	start_bit  int
	length     int
	factor     f64 = 1.0
	offset     f64
	minimum    f64
	maximum    f64
	unit       string
	desc       string
	values     map[u64]string
	is_signed  bool
	byte_order ByteOrder
}

struct MsgBuilder {
mut:
	name string
	id   u32
	dlc  int
	sigs []SigBuilder
}

// CAN_EFF_FLAG marks an extended (29-bit) id in a DBC BO_ record.
const can_eff_flag = u32(0x8000_0000)
const can_eff_mask = u32(0x1FFF_FFFF)

// parse_dbc parses DBC text into a Database. Pure (no I/O) so it is directly
// unit-testable. Returns an error only on a structurally broken BO_/SG_ line.
pub fn parse_dbc(text string) !Database {
	mut msgs := []MsgBuilder{}
	mut by_id := map[u32]int{} // message id -> index into msgs
	mut cur := -1              // index of the message SG_ lines attach to

	for raw_line in text.split_into_lines() {
		line := raw_line.trim_space()
		if line.starts_with('BO_ ') {
			mb := parse_bo(line)!
			by_id[mb.id] = msgs.len
			cur = msgs.len
			msgs << mb
		} else if line.starts_with('SG_ ') {
			if cur < 0 {
				return error('SG_ line with no preceding BO_: ${line}')
			}
			msgs[cur].sigs << parse_sg(line)!
		} else if line.starts_with('VAL_ ') {
			apply_val(mut msgs, by_id, line)
		} else if line.starts_with('CM_ SG_ ') {
			apply_cm_sg(mut msgs, by_id, line)
		}
		// every other record type (BU_, BA_, blank, …) is ignored; SG_ always
		// follows its BO_ and VAL_/CM_ resolve by id, so no message-close bookkeeping
		// is needed.
	}

	// emit immutable model
	mut out := []Message{cap: msgs.len}
	for mb in msgs {
		mut sigs := []Signal{cap: mb.sigs.len}
		for sb in mb.sigs {
			sigs << Signal{
				name:       sb.name
				start_bit:  sb.start_bit
				length:     sb.length
				factor:     sb.factor
				offset:     sb.offset
				minimum:    sb.minimum
				maximum:    sb.maximum
				unit:       sb.unit
				desc:       sb.desc
				values:     sb.values.clone()
				is_signed:  sb.is_signed
				byte_order: sb.byte_order
			}
		}
		out << Message{
			name:    mb.name
			id:      mb.id
			dlc:     mb.dlc
			signals: sigs
		}
	}
	return Database{
		messages: out
	}
}

// parse_bo parses:  BO_ <id> <Name>: <dlc> <transmitter>
fn parse_bo(line string) !MsgBuilder {
	f := line.fields()
	if f.len < 4 {
		return error('malformed BO_: ${line}')
	}
	raw_id := u32(f[1].u64())
	// DBC tags extended ids with the high bit; strip it for the real id.
	id := if raw_id & can_eff_flag != 0 { raw_id & can_eff_mask } else { raw_id }
	return MsgBuilder{
		name: f[2].trim_right(':')
		id:   id
		dlc:  f[3].int()
	}
}

// parse_sg parses:
//   SG_ <Name> [M|m<n>] : <start>|<len>@<order><sign> (<f>,<o>) [<min>|<max>] "<unit>" <rx>
fn parse_sg(line string) !SigBuilder {
	colon := line.index(':') or { return error('SG_ without ":" : ${line}') }
	head := line[..colon].trim_space() // "SG_ Name" or "SG_ Name m0"
	body := line[colon + 1..].trim_space()

	hf := head.fields()
	if hf.len < 2 {
		return error('SG_ missing name: ${line}')
	}
	name := hf[1]

	// unit is quoted and may contain spaces; split the body at the first quote.
	q1 := index_byte_from(body, `"`, 0) or { return error('SG_ missing unit quotes: ${line}') }
	q2 := index_byte_from(body, `"`, q1 + 1) or { return error('SG_ unterminated unit: ${line}') }
	unit := body[q1 + 1..q2]
	pre := body[..q1].trim_space() // "<start>|<len>@<order><sign> (f,o) [min|max]"

	pf := pre.fields()
	if pf.len < 2 {
		return error('SG_ malformed layout: ${line}')
	}

	// bit spec:  start|len@order sign
	bitspec := pf[0]
	bar := index_byte_from(bitspec, `|`, 0) or { return error('SG_ bad bit spec: ${line}') }
	at := index_byte_from(bitspec, `@`, 0) or { return error('SG_ bad bit spec: ${line}') }
	start := bitspec[..bar].int()
	length := bitspec[bar + 1..at].int()
	order_sign := bitspec[at + 1..] // e.g. "1+"
	if order_sign.len < 2 {
		return error('SG_ bad order/sign: ${line}')
	}
	byte_order := if order_sign[0] == `1` { ByteOrder.little_endian } else { ByteOrder.big_endian }
	is_signed := order_sign[1] == `-`

	// (factor,offset)
	fo := pf[1].trim('()').split(',')
	factor := if fo.len > 0 { fo[0].f64() } else { 1.0 }
	offset := if fo.len > 1 { fo[1].f64() } else { 0.0 }

	// [min|max] — optional
	mut minimum := 0.0
	mut maximum := 0.0
	if pf.len > 2 {
		mm := pf[2].trim('[]').split('|')
		if mm.len > 1 {
			minimum = mm[0].f64()
			maximum = mm[1].f64()
		}
	}

	return SigBuilder{
		name:       name
		start_bit:  start
		length:     length
		factor:     factor
		offset:     offset
		minimum:    minimum
		maximum:    maximum
		unit:       unit
		is_signed:  is_signed
		byte_order: byte_order
	}
}

// apply_val parses a VAL_ table and attaches it to the named signal.
//   VAL_ <id> <Signal> <int> "label" <int> "label" … ;
fn apply_val(mut msgs []MsgBuilder, by_id map[u32]int, line string) {
	body := line.trim_string_left('VAL_').trim_space().trim_right(';').trim_space()
	f := body.fields()
	if f.len < 2 {
		return
	}
	id := u32(f[0].u64()) & can_eff_mask
	sig_name := f[1]
	mi := by_id[id] or { return }
	si := signal_index(msgs[mi], sig_name) or { return }
	// remaining tokens alternate <int> "<label>"; labels can hold spaces, so
	// scan the raw remainder after the signal name for value/quoted-label pairs.
	name_at := index_str_from(body, sig_name, 0) or { return }
	rest := body[name_at + sig_name.len..]
	mut vals := map[u64]string{}
	mut i := 0
	for i < rest.len {
		for i < rest.len && rest[i] == ` ` {
			i++
		}
		mut num := ''
		for i < rest.len && (rest[i] == `-` || (rest[i] >= `0` && rest[i] <= `9`)) {
			num += rest[i].ascii_str()
			i++
		}
		q := index_byte_from(rest, `"`, i) or { break }
		qe := index_byte_from(rest, `"`, q + 1) or { break }
		label := rest[q + 1..qe]
		if num.len > 0 {
			vals[u64(num.i64())] = label
		}
		i = qe + 1
	}
	msgs[mi].sigs[si].values = vals.move()
}

// apply_cm_sg parses a signal comment and stores it as the signal's desc.
//   CM_ SG_ <id> <Signal> "comment" ;
fn apply_cm_sg(mut msgs []MsgBuilder, by_id map[u32]int, line string) {
	rest := line.trim_string_left('CM_ SG_').trim_space()
	f := rest.fields()
	if f.len < 2 {
		return
	}
	id := u32(f[0].u64()) & can_eff_mask
	sig_name := f[1]
	q1 := index_byte_from(line, `"`, 0) or { return }
	q2 := index_byte_from(line, `"`, q1 + 1) or { return }
	comment := line[q1 + 1..q2]
	mi := by_id[id] or { return }
	si := signal_index(msgs[mi], sig_name) or { return }
	msgs[mi].sigs[si].desc = comment
}

fn signal_index(mb MsgBuilder, name string) ?int {
	for i, s in mb.sigs {
		if s.name == name {
			return i
		}
	}
	return none
}

// index_byte_from returns the index of byte `c` at or after `from`, or none.
fn index_byte_from(s string, c u8, from int) ?int {
	mut i := if from < 0 { 0 } else { from }
	for i < s.len {
		if s[i] == c {
			return i
		}
		i++
	}
	return none
}

// index_str_from returns the index of substring `sub` at or after `from`, or none.
fn index_str_from(s string, sub string, from int) ?int {
	if sub.len == 0 || s.len < sub.len {
		return none
	}
	mut i := if from < 0 { 0 } else { from }
	for i <= s.len - sub.len {
		if s[i..i + sub.len] == sub {
			return i
		}
		i++
	}
	return none
}
