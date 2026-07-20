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
	nodes    []string // ECU nodes declared by the DBC BU_ record
}

// lookup returns the message defined for `id`, if any (exact id match).
pub fn (db Database) lookup(id u32) ?Message {
	for m in db.messages {
		if m.id == id {
			return m
		}
	}
	return none
}

// j1939_pgn extracts the Parameter Group Number from a 29-bit J1939 id.
// Layout (MSB→LSB): priority(3) | EDP(1) | DP(1) | PF(8) | PS(8) | SA(8).
// For PDU1 (PF < 0xF0) the PS byte is a destination address and is NOT part
// of the PGN; for PDU2 (PF >= 0xF0) it is. Priority and source address are
// never part of the PGN.
pub fn j1939_pgn(id u32) u32 {
	pf := (id >> 16) & 0xFF
	mut pgn := (id >> 8) & 0x3FFFF // EDP+DP+PF+PS
	if pf < 0xF0 {
		pgn &= 0x3FF00 // PDU1: drop the destination-address byte
	}
	return pgn
}

// lookup_frame resolves a received frame to a message: exact id first, then —
// for extended (29-bit) frames only — a J1939 PGN match that ignores the
// priority and source-address bits. Real J1939 DBCs (e.g. the CSS/CANedge
// ones) encode prio+PGN+SA in the BO_ id, so live frames from a different
// source address never match exactly; the PGN is the stable key.
pub fn (db Database) lookup_frame(id u32, ext bool) ?Message {
	if m := db.lookup(id) {
		return m
	}
	if !ext {
		return none
	}
	pgn := j1939_pgn(id)
	for m in db.messages {
		if m.ext && j1939_pgn(m.id) == pgn {
			return m
		}
	}
	return none
}

// messages_from returns every message whose transmitter is `node` — i.e. the
// messages a simulated ECU named `node` is responsible for sending.
pub fn (db Database) messages_from(node string) []Message {
	return db.messages.filter(it.sender == node)
}

// load_dbc_file reads and parses a .dbc file from disk.
pub fn load_dbc_file(path string) !Database {
	return parse_dbc(os.read_file(path)!)!
}

// --- internal mutable builders (final Message/Signal are immutable) ----------

struct SigBuilder {
mut:
	name              string
	start_bit         int
	length            int
	factor            f64 = 1.0
	offset            f64
	minimum           f64
	maximum           f64
	unit              string
	desc              string
	values            map[u64]string
	is_signed         bool
	byte_order        ByteOrder
	is_multiplexor    bool
	is_multiplexed    bool
	multiplexor_value int
}

struct MsgBuilder {
mut:
	name     string
	id       u32
	ext      bool
	dlc      int
	sender   string
	cycle_ms int
	sigs     []SigBuilder
}

// CAN_EFF_FLAG marks an extended (29-bit) id in a DBC BO_ record.
const can_eff_flag = u32(0x8000_0000)
const can_eff_mask = u32(0x1FFF_FFFF)

// parse_dbc parses DBC text into a Database. Pure (no I/O) so it is directly
// unit-testable. Returns an error only on a structurally broken BO_/SG_ line.
pub fn parse_dbc(text string) !Database {
	mut msgs := []MsgBuilder{}
	// keyed by the RAW DBC id (EFF bit intact): auxiliary records (VAL_/CM_/
	// BA_) carry the same raw id as their BO_, and a standard and an extended
	// frame may share the numeric id — stripping here would attach one
	// frame's aux records to the other
	mut by_id := map[u32]int{} // raw DBC id -> index into msgs
	mut cur := -1 // index of the message SG_ lines attach to
	mut nodes := []string{}

	for raw_line in text.split_into_lines() {
		line := raw_line.trim_space()
		if line.starts_with('BO_ ') {
			mb := parse_bo(line)!
			raw := if mb.ext { mb.id | can_eff_flag } else { mb.id }
			by_id[raw] = msgs.len
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
		} else if line.starts_with('BU_:') {
			// BU_: NodeA NodeB …  — the declared ECU nodes
			nodes = line[4..].fields()
		} else if line.starts_with('BA_ "GenMsgCycleTime"') {
			apply_cycle_time(mut msgs, by_id, line)
		}
		// other records (BA_DEF_, blank, …) are ignored.
	}

	// emit immutable model
	mut out := []Message{cap: msgs.len}
	for mb in msgs {
		mut sigs := []Signal{cap: mb.sigs.len}
		for sb in mb.sigs {
			sigs << Signal{
				name:              sb.name
				start_bit:         sb.start_bit
				length:            sb.length
				factor:            sb.factor
				offset:            sb.offset
				minimum:           sb.minimum
				maximum:           sb.maximum
				unit:              sb.unit
				desc:              sb.desc
				values:            sb.values.clone()
				is_signed:         sb.is_signed
				byte_order:        sb.byte_order
				is_multiplexor:    sb.is_multiplexor
				is_multiplexed:    sb.is_multiplexed
				multiplexor_value: sb.multiplexor_value
			}
		}
		out << Message{
			name:     mb.name
			id:       mb.id
			ext:      mb.ext
			dlc:      mb.dlc
			sender:   mb.sender
			cycle_ms: mb.cycle_ms
			signals:  sigs
		}
	}
	return Database{
		messages: out
		nodes:    nodes
	}
}

// apply_cycle_time parses `BA_ "GenMsgCycleTime" BO_ <id> <ms>;` and records the
// period on the matching message (DBC convention for cyclic-message timing).
fn apply_cycle_time(mut msgs []MsgBuilder, by_id map[u32]int, line string) {
	f := line.replace(';', '').fields()
	// f: BA_ "GenMsgCycleTime" BO_ <id> <ms>
	if f.len < 5 || f[2] != 'BO_' {
		return
	}
	id := u32(f[3].u64()) // raw: by_id keys keep the EFF bit
	if idx := by_id[id] {
		msgs[idx].cycle_ms = f[4].int()
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
	ext := raw_id & can_eff_flag != 0
	id := if ext { raw_id & can_eff_mask } else { raw_id }
	return MsgBuilder{
		name:   f[2].trim_right(':')
		id:     id
		ext:    ext
		dlc:    f[3].int()
		sender: if f.len >= 5 { f[4] } else { '' }
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

	// Optional multiplexing marker between the name and ':' — 'M' (the switch),
	// 'm<N>' (multiplexed, selector N), or 'm<N>M' (extended: both).
	mut is_multiplexor := false
	mut is_multiplexed := false
	mut multiplexor_value := 0
	if hf.len > 2 {
		marker := hf[2]
		if marker == 'M' {
			is_multiplexor = true
		} else if marker.starts_with('m') {
			is_multiplexed = true
			multiplexor_value = marker[1..].trim_right('M').int()
			if marker.ends_with('M') {
				is_multiplexor = true
			}
		}
	}

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
		name:              name
		start_bit:         start
		length:            length
		factor:            factor
		offset:            offset
		minimum:           minimum
		maximum:           maximum
		unit:              unit
		is_signed:         is_signed
		byte_order:        byte_order
		is_multiplexor:    is_multiplexor
		is_multiplexed:    is_multiplexed
		multiplexor_value: multiplexor_value
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
	id := u32(f[0].u64()) // raw: by_id keys keep the EFF bit
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
	id := u32(f[0].u64()) // raw: by_id keys keep the EFF bit
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
