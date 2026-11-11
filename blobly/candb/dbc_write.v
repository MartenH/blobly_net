// dbc_write — the canonical DBC serializer: the write half the editor phase
// needs (docs/dbc_editor.md). Emits exactly the record subset the parser
// reads (BU_/BO_/SG_/CM_ SG_/VAL_/BA_: GenMsgCycleTime, the send attributes and
// GenSigStartValue of dbc_send.v, VFrameFormat, E2E) plus the standard
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
// `scope` is the object type it is defined for: BO_ (a message), or SG_ (a signal), whose values
// name their signal.
pub struct DbcAttr {
pub mut:
	name    string
	scope   string = 'BO_'
	typ     string
	default string
	values  []DbcAttrValue
}

pub struct DbcAttrValue {
pub:
	id     u32
	ext    bool
	value  string
	signal string // at SG_ scope, the signal it is stated on
}

// DbcExtras is what a caller may add to the canonical text: a network comment (`CM_ "…";`)
// and message attributes. The writer places them in the sections the format assigns, so no
// caller has to know its order.
pub struct DbcExtras {
pub mut:
	comment string
	attrs   []DbcAttr
}

// e2e_notes says every #271 E2E value the reader refused, one line each — the ONE place a
// malformed E2EDataId or E2ETimeout is said, whoever sends the message; the simulation only
// refuses to apply a declaration with a malformed Data ID.
pub fn (db Database) e2e_notes() []string {
	mut out := db.e2e_unread.clone()
	for m in db.messages {
		for d in m.e2e {
			at := d.where_in(m)
			if d.bad_data_id != '' {
				out << '${at}: E2EDataId ${d.bad_data_id} is not a Data ID — its E2E declaration is not applied, and a Save drops it'
			}
			if d.bad_timeout != '' {
				out << '${at}: E2ETimeout ${d.bad_timeout} is not a number of ms — not read, and a Save drops it'
			}
			if d.declared() {
				m.e2e_window(d) or { out << '${at}: ${err.msg()} — its E2E declaration is not applied' }
			}
		}
	}
	return out
}

// where_in names a declaration in a note: its message, and at SG_ scope the signal it sits on.
pub fn (d E2eDecl) where_in(m Message) string {
	return if d.signal == '' { m.name } else { '${m.name}.${d.signal}' }
}

// save_drops says what to_dbc leaves out of the file that the model read from it (the
// difference E2eDecl.as_saved makes), one line per malformed value.
pub fn (db Database) save_drops() []string {
	mut out := db.e2e_unread.map(it.replace(' — not applied, and a Save drops it', ' — not saved'))
	for m in db.messages {
		for d in m.e2e {
			at := d.where_in(m)
			if d.bad_data_id != '' {
				out << '${at}: E2EDataId ${d.bad_data_id} is not a Data ID — its E2E declaration is not saved'
			}
			if d.bad_timeout != '' {
				out << '${at}: E2ETimeout ${d.bad_timeout} is not a number of ms — not saved'
			}
		}
	}
	return out
}

// as_saved is the declaration a Save writes, which is what a reload reads back. A malformed
// value is never written as it was: under an INT definition it makes the file unreadable to
// every other tool (docs/dbc_attributes.md). A malformed E2EDataId takes the whole declaration
// with it — written without its id, a profile that needs none would be applied after the reload
// where it had been refused; a malformed E2ETimeout is left out on its own.
pub fn (d E2eDecl) as_saved() E2eDecl {
	if d.bad_data_id != '' {
		return E2eDecl{
			signal:      d.signal
			timeout_ms:  d.timeout_ms
			has_timeout: d.has_timeout
		}
	}
	return E2eDecl{
		...d
		bad_timeout: ''
	}
}

// saved is the database as a Save leaves it — the model the editor keeps once the file is
// written, so it holds what the file now says and a later Save has nothing more to report.
pub fn (mut db Database) saved() {
	for mut m in db.messages {
		m.e2e = m.e2e.map(it.as_saved()).filter(it.states_anything())
	}
	db.e2e_unread = []
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
	// EVERY NODE THE FILE REFERENCES IS DECLARED: a sender, an additional transmitter or a signal
	// receiver the editor removed from the node list would otherwise be written on its BO_ or
	// SG_ line and be missing from BU_ — a file the parser reads and other tools refuse (#273
	// round 39). The placeholder is not a node.
	for m in db.messages {
		for n in m.senders() {
			if n !in nodes {
				nodes << n
			}
		}
		for s in m.signals {
			for n in s.receivers {
				if n != '' && n != 'Vector__XXX' && n !in nodes {
					nodes << n
				}
			}
		}
	}
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
			// receivers as the parser reads them — no empties, no placeholder, no repeats — and
			// sorted, so the text is canonical and a parse of it is a fixpoint; none is the
			// format's placeholder. A programmatic Signal (the editor, the ARXML reader) is
			// not bound by the parser's normalisation, so the writer applies it (round 44)
			mut rcv := []string{}
			for n in s.receivers {
				if n != '' && n != 'Vector__XXX' && n !in rcv {
					rcv << n
				}
			}
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
	// Written as `apply_tx_bu` reads them — no empty name, no repeat — so a programmatic Message
	// round-trips as a fixpoint like a parsed one does (round 46). The order is kept: the parser
	// keeps the file's, so declaration order is already canonical here
	for m in msgs {
		mut tx := []string{}
		for n in m.tx_nodes {
			if n != '' && n !in tx {
				tx << n
			}
		}
		if tx.len > 0 {
			b << 'BO_TX_BU_ ${raw_dbc_id(m)} : ${tx.join(',')};'
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
			cycle.values << DbcAttrValue{m.id, m.ext, '${m.cycle_ms}', ''}
			if m.cycle_ms > max_cyc {
				max_cyc = m.cycle_ms
			}
		}
	}
	cycle.typ = 'INT 0 ${max_cyc}'
	if cycle.values.len > 0 {
		attrs << cycle
	}
	// the other send attributes (dbc_send.v), from the model, so a Save keeps what the parser read
	if a := send_type_attr(msgs) {
		attrs << a
	}
	for name in send_int_attrs {
		if a := send_int_attr(msgs, name) {
			attrs << a
		}
	}
	// VFrameFormat, from the model — so a DBC-editor Save keeps a J1939 declaration (which the
	// `verify:` self-sent notice depends on, codex on #289) and a message's stated frame format.
	//
	// NOT WHEN THE CALLER SUPPLIES ITS OWN. arxml_export passes its own VFrameFormat as an extra,
	// stating every frame of a cluster that carries an FD one, and two emitters of one attribute
	// would write two BA_DEF_ lines for it.
	if !x.attrs.any(it.name == 'VFrameFormat') {
		mut fmt := DbcAttr{
			name:    'VFrameFormat'
			typ:     vframe_format_enum
			default: '"StandardCAN"' // an ENUM's default is the quoted choice; its values are indices
		}
		// EVERY EXTENDED FRAME, not only the J1939 ones. The definition's default is
		// "StandardCAN", so emitting an override for the J1939 frames alone leaves an ordinary
		// 29-bit message inheriting a format that contradicts its own BO_ id — the ARXML exporter
		// states a value for every frame for exactly this reason (codex on #289). A standard
		// frame stating nothing needs no override: the default is already what it is.
		for m in msgs {
			if m.j1939 {
				fmt.values << DbcAttrValue{m.id, m.ext, '3', ''} // J1939PG
			} else if m.format.is_fd() {
				fmt.values << DbcAttrValue{m.id, m.ext, if m.ext { '15' } else { '14' }, ''} // *CAN_FD
			} else if m.ext {
				fmt.values << DbcAttrValue{m.id, m.ext, '1', ''} // ExtendedCAN
			}
		}
		// Only when something actually needs saying: a database stating no format and holding
		// standard frames only gains nothing from the definition. A standard frame stated classic
		// is the definition's default, which then states every frame that has no value — a
		// message stating nothing beside stated ones reads back as its id's classic format.
		if fmt.values.len > 0 || msgs.any(it.format != .unstated) {
			attrs << fmt
		}
	}
	// CANFD_BRS, from the model, for the CAN-FD messages: whether each switches its bit rate.
	// Not when the caller supplies its own, as above.
	if !x.attrs.any(it.name == 'CANFD_BRS') && msgs.any(it.format.is_fd()) {
		mut brs := DbcAttr{
			name:    'CANFD_BRS'
			typ:     canfd_brs_enum
			default: '"1"'
		}
		for m in msgs {
			if m.format.is_fd() {
				brs.values << DbcAttrValue{m.id, m.ext, if m.format == .fd_brs { '1' } else { '0' }, ''}
			}
		}
		attrs << brs
	}
	// The E2E contract, from the model (#271) — so an editor Save keeps what the parser read.
	// NOT WHEN THE CALLER SUPPLIES ITS OWN, as for VFrameFormat: arxml_export passes them as
	// extras, and two emitters of one attribute would write two definitions.
	// at BO_ scope for a whole-payload declaration, at SG_ scope on the signal a group's sits on
	// (#615): one definition per scope the file uses, a default per name
	if !x.attrs.any(it.name.starts_with('E2E')) && msgs.any(it.e2e_states_anything()) {
		for scope in ['BO_', 'SG_'] {
			attrs << e2e_attrs(msgs, scope)
		}
	}
	attrs << x.attrs
	// a signal's start value: [definition, default, values…]
	starts := start_value_lines(msgs) or { []string{} }
	for a in attrs {
		b << 'BA_DEF_ ${a.scope} "${a.name}" ${a.typ};'
	}
	if starts.len > 0 {
		b << starts[0]
	}
	mut defaulted := map[string]bool{}
	for a in attrs {
		if a.name !in defaulted {
			defaulted[a.name] = true
			b << 'BA_DEF_DEF_ "${a.name}" ${a.default};'
		}
	}
	if starts.len > 0 {
		b << starts[1]
	}
	for a in attrs {
		for v in a.values {
			if a.scope == 'SG_' {
				b << 'BA_ "${a.name}" SG_ ${raw_id(v.id, v.ext)} ${v.signal} ${v.value};'
			} else {
				b << 'BA_ "${a.name}" BO_ ${raw_id(v.id, v.ext)} ${v.value};'
			}
		}
	}
	if starts.len > 2 {
		b << starts[2..]
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

	// signal groups, by name within a message
	for m in msgs {
		mut groups := m.groups.clone()
		groups.sort_with_compare(fn (a &SignalGroup, g &SignalGroup) int {
			return a.name.compare(g.name)
		})
		for g in groups {
			b << 'SIG_GROUP_ ${raw_dbc_id(m)} ${g.name} ${g.repetitions} : ${g.signals.join(' ')};'
		}
	}

	return b.join('\n') + '\n'
}

// e2e_attrs is the E2E attributes of the declarations at `scope` (BO_: a message's whole-payload
// one; SG_: those of its signal groups, stated on the signal each sits on), as a Save keeps them
// (as_saved, the one rule save_drops reports); none where nothing at that scope is stated.
fn e2e_attrs(msgs []Message, scope string) []DbcAttr {
	mut ctr := DbcAttr{
		name:    'E2ECounterSignal'
		scope:   scope
		typ:     'STRING'
		default: '""'
	}
	mut crc := DbcAttr{
		name:    'E2ECrcSignal'
		scope:   scope
		typ:     'STRING'
		default: '""'
	}
	mut prof := DbcAttr{
		name:    'E2EProfile'
		scope:   scope
		typ:     'STRING'
		default: '""'
	}
	mut did := DbcAttr{
		name:    'E2EDataId'
		scope:   scope
		default: '0'
	}
	mut tmo := DbcAttr{
		name:    'E2ETimeout'
		scope:   scope
		default: '0'
	}
	mut max_id := u32(65535)
	mut max_tmo := u32(65535)
	for m in msgs {
		mut decls := m.e2e.filter((it.signal == '') == (scope == 'BO_'))
		decls.sort_with_compare(fn (a &E2eDecl, b &E2eDecl) int {
			return a.signal.compare(b.signal)
		})
		for d0 in decls {
			d := d0.as_saved()
			sg := d.signal
			if d.counter != '' {
				ctr.values << DbcAttrValue{m.id, m.ext, '"${dbc_str(d.counter)}"', sg}
			}
			if d.crc != '' {
				crc.values << DbcAttrValue{m.id, m.ext, '"${dbc_str(d.crc)}"', sg}
			}
			if d.profile != '' {
				prof.values << DbcAttrValue{m.id, m.ext, '"${dbc_str(profile_to_dbc(d.profile))}"', sg}
			}
			if d.has_data_id {
				did.values << DbcAttrValue{m.id, m.ext, '${d.data_id}', sg}
				if d.data_id > max_id {
					max_id = d.data_id
				}
			}
			if d.has_timeout {
				tmo.values << DbcAttrValue{m.id, m.ext, '${d.timeout_ms}', sg}
				if d.timeout_ms > max_tmo {
					max_tmo = d.timeout_ms
				}
			}
		}
	}
	tmo.typ = 'INT 0 ${max_tmo}'
	did.typ = 'INT 0 ${max_id}'
	return [ctr, crc, prof, did, tmo].filter(it.values.len > 0)
}
