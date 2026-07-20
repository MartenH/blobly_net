// dbc_write — the canonical DBC serializer: the write half the editor phase
// needs (docs/dbc_editor.md). Emits exactly the record subset the parser
// reads (BU_/BO_/SG_/CM_ SG_/VAL_/BA_ GenMsgCycleTime) plus the standard
// preamble other tools expect, in CANONICAL deterministic order — messages by
// id, signals by start_bit then name, value tables by raw value — so a saved
// file is stable under reload and a git diff shows real changes only.
// Fixpoint law (dbc_write_test.v): to_dbc(parse_dbc(to_dbc(db))) == to_dbc(db).
module candb

// fmt_num renders a DBC number: integers without a decimal point, floats in
// V's shortest form — deterministic either way.
fn fmt_num(f f64) string {
	if f == f64(i64(f)) {
		return '${i64(f)}'
	}
	return '${f}'
}

// dbc_str sanitizes a quoted DBC string: embedded double quotes would break
// the record format (the parser does not unescape), so they become single
// quotes rather than corrupting the file.
fn dbc_str(s string) string {
	return s.replace('"', "'")
}

// raw_dbc_id renders the BO_/VAL_/CM_ id: extended (29-bit) ids carry the EFF
// high bit in DBC files, exactly as the parser strips it.
fn raw_dbc_id(m Message) u32 {
	if m.ext {
		return m.id | can_eff_flag
	}
	return m.id
}

// to_dbc renders the database as canonical DBC text.
pub fn (db Database) to_dbc() string {
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
	msgs.sort_with_compare(fn (a &Message, mb &Message) int {
		if a.id != mb.id {
			return if a.id < mb.id { -1 } else { 1 }
		}
		return a.name.compare(mb.name)
	})

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
			b << ' SG_ ${s.name}${mux} : ${s.start_bit}|${s.length}@${order}${sign} (${fmt_num(s.factor)},${fmt_num(s.offset)}) [${fmt_num(s.minimum)}|${fmt_num(s.maximum)}] "${dbc_str(s.unit)}" Vector__XXX'
		}
		b << ''
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

	// GenMsgCycleTime: declare the attribute once, then per-message values
	mut any_cycle := false
	for m in msgs {
		if m.cycle_ms > 0 {
			any_cycle = true
		}
	}
	if any_cycle {
		b << 'BA_DEF_ BO_ "GenMsgCycleTime" INT 0 65535;'
		b << 'BA_DEF_DEF_ "GenMsgCycleTime" 0;'
		for m in msgs {
			if m.cycle_ms > 0 {
				b << 'BA_ "GenMsgCycleTime" BO_ ${raw_dbc_id(m)} ${m.cycle_ms};'
			}
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
			mut keys := s.values.keys()
			keys.sort()
			mut parts := []string{}
			for k in keys {
				parts << '${k} "${dbc_str(s.values[k])}"'
			}
			b << 'VAL_ ${raw_dbc_id(m)} ${s.name} ${parts.join(' ')} ;'
		}
	}

	return b.join('\n') + '\n'
}
