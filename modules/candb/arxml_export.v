// arxml_export — what `cmd/arxml2dbc` writes for the two consumers that cannot read ARXML
// (#272): blobly_emb's build, and a user who needs to edit. blobly_net itself reads the
// ARXML natively; this export is an honest, PROVENANCE-STAMPED snapshot of it.
//
//   export_dbc    — `to_dbc` of the cluster, plus the E2E contract as DBC message attributes
//                   (#271's names: E2ECounterSignal / E2ECrcSignal / E2EProfile / E2EDataId)
//                   and a network comment saying which ARXML it came from, so a DBC found in a
//                   repo six months later can say whether anyone edited it since
//   frame_toml    — a `[[frame]]` fragment for blobly_emb's ecu.toml: tx mode and cadence,
//                   E2E positions, the SecOC layout with the key left to the user
//   e2e_signals   — the E2E offsets turned into the SIGNALS that sit there, which is the form
//                   both the attributes and `sim.E2e` take
//
// The DBC parser here (dbc.v) does not yet READ the attributes back — that is #271's rung;
// until it lands they survive a save through this app only as far as the parser carries them.
module candb

// ArxmlProvenance is what the exported DBC says about its origin.
pub struct ArxmlProvenance {
pub:
	source  string // the ARXML's file name
	sha256  string // of its bytes
	reader  string // blobly_net version that exported it
	cluster string
}

// E2eSignals names the counter and CRC SIGNALS of a protected message, derived from the E2E
// byte offsets and the message's layout.
pub struct E2eSignals {
pub:
	counter string
	crc     string
	profile string // blobly's CRC primitive for the AUTOSAR profile, '' if none is
	data_id u32
}

// e2e_profile_primitive maps an AUTOSAR E2E profile to the checksum blobly's simulation can
// compute (docs/simulation.md). Only the CRC algorithm is mapped — profile 1's header layout
// and counter rules are the file's, not ours — and a profile with a CRC this app lacks
// (profile 4/5/6/7 are CRC-16/32/64) maps to '' so nothing pretends.
pub fn e2e_profile_primitive(profile string) string {
	return match profile {
		'PROFILE_01', 'PROFILE_11' { 'crc8_j1850' }
		'PROFILE_02', 'PROFILE_22' { 'crc8_autosar' }
		else { '' }
	}
}

// e2e_signals resolves a frame's E2E declaration to the signals at its offsets, or none if
// the message is unprotected or no signal sits at an offset (a protected PDU whose CRC is not
// a declared signal is a real shape — the E2E library owns those bytes — and then the
// attribute form cannot express it, so nothing is invented).
pub fn (c ArxmlCluster) e2e_signals(m Message) ?E2eSignals {
	f := c.frames[m.name] or { return none }
	e := f.e2e or { return none }
	ci := m.signal_at(e.data_offset + e.crc_offset)
	ki := m.signal_at(e.data_offset + e.counter_offset)
	if ci < 0 || ki < 0 {
		return none
	}
	return E2eSignals{
		counter: m.signals[ki].name
		crc: m.signals[ci].name
		profile: e2e_profile_primitive(e.profile)
		data_id: e.data_id
	}
}

// export_dbc renders the cluster as DBC text: the canonical `to_dbc` output with the
// provenance comment and the E2E attributes spliced into their sections. Attribute
// definitions go before every attribute value, as the format requires.
pub fn (c ArxmlCluster) export_dbc(p ArxmlProvenance, report ArxmlReport) string {
	base := c.db.to_dbc()
	lines := base.trim_right('\n').split('\n')

	mut dropped := 0
	for _, n in report.ignored {
		dropped += n
	}
	prov := 'arxml2dbc: source=${p.source} sha256=${p.sha256} reader=${p.reader} cluster=${p.cluster} dropped=${dropped} unresolved=${report.unresolved.len}'
	comment := 'CM_ "${dbc_str(prov)}";'

	// the E2E contract, one attribute set per protected message
	mut msgs := c.db.messages.clone()
	msgs.sort_with_compare(fn (a &Message, b &Message) int {
		if a.id != b.id {
			return if a.id < b.id { -1 } else { 1 }
		}
		return if !a.ext && b.ext {
			-1
		} else if a.ext && !b.ext { 1 } else { 0 }
	})
	mut ba := []string{}
	for m in msgs {
		s := c.e2e_signals(m) or { continue }
		ba << 'BA_ "E2ECounterSignal" BO_ ${raw_dbc_id(m)} "${dbc_str(s.counter)}";'
		ba << 'BA_ "E2ECrcSignal" BO_ ${raw_dbc_id(m)} "${dbc_str(s.crc)}";'
		ba << 'BA_ "E2EProfile" BO_ ${raw_dbc_id(m)} "${dbc_str(s.profile)}";'
		ba << 'BA_ "E2EDataId" BO_ ${raw_dbc_id(m)} ${s.data_id};'
	}
	mut defs := []string{}
	mut defaults := []string{}
	if ba.len > 0 {
		defs << 'BA_DEF_ BO_ "E2ECounterSignal" STRING;'
		defs << 'BA_DEF_ BO_ "E2ECrcSignal" STRING;'
		defs << 'BA_DEF_ BO_ "E2EProfile" STRING;'
		defs << 'BA_DEF_ BO_ "E2EDataId" INT 0 65535;'
		defaults << 'BA_DEF_DEF_ "E2ECounterSignal" "";'
		defaults << 'BA_DEF_DEF_ "E2ECrcSignal" "";'
		defaults << 'BA_DEF_DEF_ "E2EProfile" "";'
		defaults << 'BA_DEF_DEF_ "E2EDataId" 0;'
	}

	// splice: the comment goes with the CM_ records (before the first CM_ SG_, else before the
	// attribute block, else before the value tables, else at the end); the attribute lines
	// join the existing GenMsgCycleTime block in definition / default / value order
	mut out := []string{cap: lines.len + ba.len + defs.len + defaults.len + 2}
	mut comment_done := false
	mut defs_done := false
	mut defaults_done := false
	mut values_done := false
	for l in lines {
		if !comment_done && (l.starts_with('CM_ ') || l.starts_with('BA_DEF_') || l.starts_with('VAL_ ')) {
			out << comment
			comment_done = true
		}
		if !defs_done && (l.starts_with('BA_DEF_DEF_') || l.starts_with('BA_ ') || l.starts_with('VAL_ ')) {
			out << defs
			defs_done = true
		}
		if !defaults_done && (l.starts_with('BA_ ') || l.starts_with('VAL_ ')) {
			out << defaults
			defaults_done = true
		}
		if !values_done && l.starts_with('VAL_ ') {
			out << ba
			values_done = true
		}
		out << l
	}
	if !comment_done {
		out << comment
	}
	if !defs_done {
		out << defs
	}
	if !defaults_done {
		out << defaults
	}
	if !values_done {
		out << ba
	}
	return out.join('\n') + '\n'
}

// frame_toml renders a `[[frame]]` fragment in blobly_emb's ecu.toml dialect for the frames
// `ecu` sends and receives ('' = every frame, as sent). What the system description does not
// carry is written as a comment rather than invented: the receive deadline is ECU
// configuration (ComTimeout), and the SecOC key is nobody's to export.
pub fn (c ArxmlCluster) frame_toml(ecu string) string {
	mut b := []string{}
	b << '# generated by arxml2dbc from cluster ${c.name} — import beside your hand-written'
	b << '# ecu.toml; a regeneration overwrites THIS file only'
	mut msgs := c.db.messages.clone()
	msgs.sort_with_compare(fn (a &Message, b &Message) int {
		if a.id != b.id {
			return if a.id < b.id { -1 } else { 1 }
		}
		return if !a.ext && b.ext {
			-1
		} else if a.ext && !b.ext { 1 } else { 0 }
	})
	for m in msgs {
		f := c.frames[m.name] or { continue }
		sends := ecu == '' || m.sender == ecu || ecu in m.tx_nodes
		receives := ecu != '' && ecu in f.receivers
		if !sends && !receives {
			continue
		}
		b << ''
		b << '[[frame]]'
		b << 'name = "${m.name}"'
		b << 'bus  = "${c.name}"'
		if sends {
			mode := if f.tx_mode == '' { 'cyclic' } else { f.tx_mode }
			mut tx := 'mode = "${mode}"'
			if f.cycle_ms > 0 {
				tx += ', cycle_ms = ${f.cycle_ms}'
			}
			if f.min_delay_ms > 0 {
				tx += ', min_delay_ms = ${f.min_delay_ms}'
			}
			if f.tx_mode == '' {
				b << '# no transmission mode in the system description; cyclic assumed'
			}
			b << 'tx   = { ${tx} }'
		}
		if receives {
			b << '# rx timeout is ECU configuration (ComTimeout), not in the system description'
			b << 'rx   = { timeout_ms = ${if f.cycle_ms > 0 { 3 * f.cycle_ms } else { 0 }} }'
		}
		if e := f.e2e {
			b << 'e2e  = { data_id = 0x${e.data_id:X}, crc_pos = ${e.crc_byte}, counter_pos = ${e.counter_byte} }  # ${e.profile}'
		}
		if s := f.secoc {
			b << '# SecOC: the key is not in the system description — fill it in and uncomment'
			b << '# secoc = { key = "…", data_id = 0x${s.data_id:X}, fresh_pos = ${s.fresh_byte}, mac_pos = ${s.mac_byte}, mac_len = ${s.mac_len} }'
		}
	}
	return b.join('\n') + '\n'
}

// report_lines renders the honesty rules' findings for a terminal, one line each.
pub fn (r ArxmlReport) lines() []string {
	mut out := []string{}
	for u in r.unresolved {
		out << 'unresolved reference: ${u}'
	}
	mut kinds := r.ignored.keys()
	kinds.sort()
	for k in kinds {
		out << 'ignored: ${r.ignored[k]} × ${k}'
	}
	for n in r.notes {
		out << 'note: ${n}'
	}
	return out
}
