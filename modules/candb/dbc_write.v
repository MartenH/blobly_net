// dbc_write — the canonical DBC serializer: the write half the editor phase
// needs (docs/dbc_editor.md). Emits exactly the record subset the parser
// reads (BU_/BO_/SG_/CM_ SG_/VAL_/BA_ GenMsgCycleTime) plus the standard
// preamble other tools expect, in CANONICAL deterministic order — messages by
// id, signals by start_bit then name, value tables by raw value — so a saved
// file is stable under reload and a git diff shows real changes only.
// Fixpoint law (dbc_write_test.v): to_dbc(parse_dbc(to_dbc(db))) == to_dbc(db).
module candb

// fmt_num renders a DBC number: integers without a decimal point, floats in
// V's shortest form — deterministic either way. Public because cmd/arxml2dbc's --dump must
// render a factor exactly as the DBC does, or the oracle diff reports rendering as reading.
pub fn fmt_num(f f64) string {
	if f == f64(i64(f)) {
		return '${i64(f)}'
	}
	return '${f}'
}

// dbc_str sanitizes a quoted DBC string: embedded double quotes and line
// breaks would break the single-line record format (the parser does not
// unescape), so quotes become single quotes and breaks become spaces rather
// than corrupting the file.
fn dbc_str(s string) string {
	return s.replace('"', "'").replace('\\', '/').replace('\r', ' ').replace('\n', ' ')
}

// sext sign-extends a width-sized raw pattern to i64 (mask/sign_bit derived
// from the signal width) — the value a signed enum key MEANS.
fn sext(k u64, mask u64, sign_bit u64) i64 {
	if k & sign_bit != 0 {
		return i64(k | ~mask)
	}
	return i64(k)
}

// raw_dbc_id renders the BO_/VAL_/CM_ id: extended (29-bit) ids carry the EFF
// high bit in DBC files, exactly as the parser strips it.
fn raw_dbc_id(m Message) u32 {
	return raw_id(m.id, m.ext)
}

fn raw_id(id u32, ext bool) u32 {
	if ext {
		return id | can_eff_flag
	}
	return id
}

// message_order is THE canonical message order: by id, a standard frame before an extended
// one sharing the numeric id (the frame KIND is part of identity — see lookup_frame), then by
// name. One comparator, because the writer, the ARXML export and its dump each need it and
// three copies had already lost the name tie-break between them.
pub fn message_order(a &Message, b &Message) int {
	if a.id != b.id {
		return if a.id < b.id { -1 } else { 1 }
	}
	if a.ext != b.ext {
		return if !a.ext { -1 } else { 1 }
	}
	return a.name.compare(b.name)
}

// DbcAttr is a message attribute the writer emits beside GenMsgCycleTime: its definition
// (`typ` is the BA_DEF_ type clause, 'STRING' or 'INT 0 65535'), its default (RENDERED, so
// '""' for an empty string and '0' for a number), and its per-message values (rendered too).
pub struct DbcAttr {
pub mut:
	name    string
	typ     string
	default string
	values  []DbcAttrValue
}

pub struct DbcAttrValue {
pub:
	id    u32
	ext   bool
	value string
}

// DbcExtras is what a caller may add to the canonical text: a network comment (`CM_ "…";`)
// and message attributes. The writer places them in the sections the format assigns, so no
// caller has to know its order.
pub struct DbcExtras {
pub mut:
	comment string
	attrs   []DbcAttr
}

// to_dbc renders the database as canonical DBC text.
pub fn (db Database) to_dbc() string {
	return db.to_dbc_with(DbcExtras{})
}

// to_dbc_with renders the database with extras spliced into their sections.
pub fn (db Database) to_dbc_with(x DbcExtras) string {
	mut b := []string{}
	b << 'VERSION ""'
	b << ''
	b << 'NS_ :'
	b << ''
	b << 'BS_:'
	b << ''
	mut nodes := db.nodes.clone()
	nodes.sort()
	b << 'BU_: ${nodes.join(' ')}'
	b << ''

	mut msgs := db.messages.clone()
	msgs.sort_with_compare(message_order)

	for m in msgs {
		sender := if m.sender == '' { 'Vector__XXX' } else { m.sender }
		b << 'BO_ ${raw_dbc_id(m)} ${m.name}: ${m.dlc} ${sender}'
		mut sigs := m.signals.clone()
		sigs.sort_with_compare(fn (a &Signal, sb &Signal) int {
			if a.start_bit != sb.start_bit {
				return if a.start_bit < sb.start_bit { -1 } else { 1 }
			}
			return a.name.compare(sb.name)
		})
		for s in sigs {
			mut mux := ''
			if s.is_multiplexed && s.is_multiplexor {
				mux = ' m${s.multiplexor_value}M'
			} else if s.is_multiplexed {
				mux = ' m${s.multiplexor_value}'
			} else if s.is_multiplexor {
				mux = ' M'
			}
			order := if s.byte_order == .little_endian { '1' } else { '0' }
			sign := if s.is_signed { '-' } else { '+' }
			// receivers sorted, so the text is canonical; none is the format's placeholder
			mut rcv := s.receivers.clone()
			rcv.sort()
			rcv_s := if rcv.len == 0 { 'Vector__XXX' } else { rcv.join(',') }
			b << ' SG_ ${s.name}${mux} : ${s.start_bit}|${s.length}@${order}${sign} (${fmt_num(s.factor)},${fmt_num(s.offset)}) [${fmt_num(s.minimum)}|${fmt_num(s.maximum)}] "${dbc_str(s.unit)}" ${rcv_s}'
		}
		b << ''
	}

	// BO_TX_BU_ — ADDITIONAL transmitters. The parser reads these, so a writer that omitted them
	// deleted real content on every save: a message the database said two nodes send would come
	// back saying one, and the rest-bus subtraction would stop withholding the ECU under test's
	// own frames. Emitted after the messages, which is where the format puts them.
	for m in msgs {
		if m.tx_nodes.len > 0 {
			b << 'BO_TX_BU_ ${raw_dbc_id(m)} : ${m.tx_nodes.join(',')};'
		}
	}

	// the network comment leads the CM_ section
	if x.comment != '' {
		b << 'CM_ "${dbc_str(x.comment)}";'
	}
	// signal comments (CM_ SG_), in message order then signal name
	for m in msgs {
		mut sigs := m.signals.clone()
		sigs.sort_with_compare(fn (a &Signal, sb &Signal) int {
			return a.name.compare(sb.name)
		})
		for s in sigs {
			if s.desc != '' {
				b << 'CM_ SG_ ${raw_dbc_id(m)} ${s.name} "${dbc_str(s.desc)}";'
			}
		}
	}

	// attributes: GenMsgCycleTime first, then the extras — every definition, then every
	// default, then every value, which is the order the format requires
	mut attrs := []DbcAttr{}
	mut cycle := DbcAttr{
		name:    'GenMsgCycleTime'
		default: '0'
	}
	// the declared range must cover every emitted value (a file must not
	// contradict its own attribute definition), and values are emitted
	// VERBATIM — clamping would silently change message timing and break
	// the round-trip contract
	mut max_cyc := 1_000_000
	for m in msgs {
		if m.cycle_ms > 0 {
			cycle.values << DbcAttrValue{m.id, m.ext, '${m.cycle_ms}'}
			if m.cycle_ms > max_cyc {
				max_cyc = m.cycle_ms
			}
		}
	}
	cycle.typ = 'INT 0 ${max_cyc}'
	if cycle.values.len > 0 {
		attrs << cycle
	}
	attrs << x.attrs
	for a in attrs {
		b << 'BA_DEF_ BO_ "${a.name}" ${a.typ};'
	}
	for a in attrs {
		b << 'BA_DEF_DEF_ "${a.name}" ${a.default};'
	}
	for a in attrs {
		for v in a.values {
			b << 'BA_ "${a.name}" BO_ ${raw_id(v.id, v.ext)} ${v.value};'
		}
	}

	// value tables, keys ascending
	for m in msgs {
		mut sigs := m.signals.clone()
		sigs.sort_with_compare(fn (a &Signal, sb &Signal) int {
			return a.name.compare(sb.name)
		})
		for s in sigs {
			if s.values.len == 0 {
				continue
			}
			// canonical key = the WIDTH-SIZED raw pattern (what raw_value
			// produces): normalize input keys to the width first — an editor
			// may hand us full-width u64(-1) — then, for signed signals,
			// SIGN-EXTEND FROM THE SIGNAL WIDTH to render (an 8-bit 255 IS
			// -1; a bare i64 cast of 255 would emit 255)
			mask := if s.length >= 64 { ~u64(0) } else { (u64(1) << s.length) - 1 }
			sign_bit := u64(1) << (s.length - 1)
			mut norm := map[u64]string{}
			for k, v in s.values {
				norm[k & mask] = v
			}
			mut keys := norm.keys()
			if s.is_signed {
				keys.sort_with_compare(fn [mask, sign_bit] (a &u64, b &u64) int {
					ia := sext(*a, mask, sign_bit)
					ib := sext(*b, mask, sign_bit)
					if ia == ib {
						return 0
					}
					return if ia < ib { -1 } else { 1 }
				})
			} else {
				keys.sort()
			}
			mut parts := []string{}
			for k in keys {
				kv := if s.is_signed { '${sext(k, mask, sign_bit)}' } else { '${k}' }
				parts << '${kv} "${dbc_str(norm[k])}"'
			}
			b << 'VAL_ ${raw_dbc_id(m)} ${s.name} ${parts.join(' ')} ;'
		}
	}

	return b.join('\n') + '\n'
}
