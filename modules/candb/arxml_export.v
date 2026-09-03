// arxml_export — what `cmd/arxml2dbc` writes for the two consumers that cannot read ARXML
// (#272): blobly_emb's build, and a user who needs to edit. blobly_net itself reads the
// ARXML natively; this export is an honest, PROVENANCE-STAMPED snapshot of it.
//
//   export_dbc    — `to_dbc_with` of the cluster: the E2E contract as DBC message attributes
//                   (#271's names: E2ECounterSignal / E2ECrcSignal / E2EProfile / E2EDataId)
//                   and a network comment saying which ARXML it came from, so a DBC found in a
//                   repo six months later can say whether anyone edited it since
//   frame_toml    — a `[[frame]]` fragment for blobly_emb's ecu.toml: tx mode and cadence,
//                   E2E positions, the SecOC layout with the key left to the user
//   e2e_signals   — the E2E offsets turned into the SIGNALS that sit there, which is the form
//                   both the attributes and `sim.E2e` take
//
// The DBC parser here (dbc.v) does not yet READ the attributes or the comment back — that is
// #271's rung. Until it lands, opening an export in the DBC editor and saving it drops both:
// the editor is for a DBC you own, and the provenance line is what tells the two apart.
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
// compute (`e2e_profiles`, docs/simulation.md). Only the CRC algorithm is mapped — profile
// 1's header layout and counter rules are the file's, not ours — and a profile with a CRC
// this app lacks (profile 4/5/6/7 are CRC-16/32/64) maps to '' so nothing pretends.
pub fn e2e_profile_primitive(profile string) string {
	return match profile {
		'PROFILE_01', 'PROFILE_11' { 'crc8_j1850' }
		'PROFILE_02', 'PROFILE_22' { 'crc8_autosar' }
		else { '' }
	}
}

// e2e_signals resolves a frame's E2E declaration to the signals at its offsets, or none if
// the message is unprotected, the profile has a fixed header this reader does not model, or
// no signal sits at an offset (a protected PDU whose CRC is not a declared signal is a real
// shape — the E2E library owns those bytes — and then the attribute form cannot express it,
// so nothing is invented).
pub fn (c ArxmlCluster) e2e_signals(m Message) ?E2eSignals {
	f := c.frame_of(m) or { return none }
	e := f.e2e or { return none }
	if !e.has_crc_counter || !e.single_data_id() {
		return none
	}
	profile := e2e_profile_primitive(e.profile)
	if profile == '' {
		return none // a checksum this app cannot compute is not a contract it can export
	}
	// the signal must BE the field, not merely contain the offset: an offset inside an
	// ordinary multi-bit signal would name an application signal as the CRC
	ci := m.signal_at(e.crc_bit())
	ki := m.signal_at(e.counter_bit())
	if ci < 0 || ki < 0 || ci == ki {
		return none
	}
	if !is_e2e_field(m.signals[ci], e.crc_bit(), 8) || !is_e2e_field(m.signals[ki], e.counter_bit(), 4) {
		return none
	}
	return E2eSignals{
		counter: m.signals[ki].name
		crc: m.signals[ci].name
		profile: profile
		data_id: e.data_id
	}
}

// is_e2e_field: a little-endian signal starting exactly at the field's bit and no wider than
// the field (profile 1/2: an 8-bit CRC, a 4-bit counter in the low nibble).
fn is_e2e_field(s Signal, bit int, width int) bool {
	return s.byte_order == .little_endian && s.start_bit == bit && s.length <= width
}

// single_data_id reports whether the protection uses ONE data id, whole: profile 1's
// ALTERNATING-8-BIT switches between two per counter parity, and LOWER-8-BIT / LOWER-12-BIT
// feed part of the id into the CRC — neither the DBC attributes nor blobly_emb's
// `[[frame]].e2e` can state either, so the export names the mode instead of exporting a
// contract that rejects valid traffic. An unset mode is profile 1's default, ALL-16-BIT.
pub fn (e ArxmlE2e) single_data_id() bool {
	return e.data_ids.len <= 1 && (e.data_id_mode == '' || e.data_id_mode == 'ALL-16-BIT')
}

// ecus lists every ECU the cluster names as a sender or a receiver, sorted — what `--ecu`
// may name.
pub fn (c ArxmlCluster) ecus() []string {
	mut out := []string{}
	for m in c.db.messages {
		for e in m.senders() {
			if e !in out {
				out << e
			}
		}
		if f := c.frame_of(m) {
			for e in f.receivers {
				if e !in out {
					out << e
				}
			}
		}
	}
	out.sort()
	return out
}

// Vector's VFrameFormat attribute: the enum INDEX is what a BA_ carries, and 14/15 are the
// CAN-FD entries. Emitted only when the cluster has an FD frame, because the format is the
// one thing that distinguishes an FD frame of eight bytes or fewer from a classic one.
const vframe_format_enum = 'ENUM "StandardCAN","ExtendedCAN","reserved","J1939PG","reserved","reserved","reserved","reserved","reserved","reserved","reserved","reserved","reserved","reserved","StandardCAN_FD","ExtendedCAN_FD"'

// export_dbc renders the cluster as DBC text through the canonical writer, with the
// provenance comment, the frame format and the E2E attributes as extras the writer places.
pub fn (c ArxmlCluster) export_dbc(p ArxmlProvenance, report ArxmlReport) string {
	mut dropped := 0
	for _, n in report.ignored {
		dropped += n
	}
	mut counter := DbcAttr{
		name: 'E2ECounterSignal'
		typ: 'STRING'
		default: '""'
	}
	mut crc := DbcAttr{
		name: 'E2ECrcSignal'
		typ: 'STRING'
		default: '""'
	}
	mut profile := DbcAttr{
		name: 'E2EProfile'
		typ: 'STRING'
		default: '""'
	}
	mut data_id := DbcAttr{
		name: 'E2EDataId'
		default: '0'
	}
	// the declared range must cover every emitted value (a file must not contradict its own
	// attribute definition): 16 bits is the common case, a profile-4 id needs 32
	mut max_id := u32(65535)
	mut fmt := DbcAttr{
		name: 'VFrameFormat'
		typ: vframe_format_enum
		default: '0'
	}
	mut msgs := c.db.messages.clone()
	msgs.sort_with_compare(message_order)
	mut any_fd := false
	for _, f in c.frames {
		any_fd = any_fd || f.fd
	}
	for m in msgs {
		// once the attribute exists every frame states its format — the default is
		// StandardCAN, which an extended classic frame would otherwise inherit
		if any_fd {
			fd := (c.frame_of(m) or { ArxmlFrame{} }).fd
			fmt.values << DbcAttrValue{m.id, m.ext, match true {
				fd && m.ext { '15' }
				fd { '14' }
				m.ext { '1' }
				else { '0' }
			}}
		}
		s := c.e2e_signals(m) or { continue }
		counter.values << DbcAttrValue{m.id, m.ext, '"${dbc_str(s.counter)}"'}
		crc.values << DbcAttrValue{m.id, m.ext, '"${dbc_str(s.crc)}"'}
		profile.values << DbcAttrValue{m.id, m.ext, '"${dbc_str(s.profile)}"'}
		data_id.values << DbcAttrValue{m.id, m.ext, '${s.data_id}'}
		if s.data_id > max_id {
			max_id = s.data_id
		}
	}
	data_id.typ = 'INT 0 ${max_id}'
	mut x := DbcExtras{
		comment: 'arxml2dbc: source=${p.source} sha256=${p.sha256} reader=${p.reader} cluster=${p.cluster} dropped=${dropped} unresolved=${report.unresolved.len}'
	}
	if fmt.values.len > 0 {
		x.attrs << fmt
	}
	if counter.values.len > 0 {
		x.attrs << [counter, crc, profile, data_id]
	}
	return c.db.to_dbc_with(x)
}

// frame_toml renders a `[[frame]]` fragment in blobly_emb's ecu.toml dialect for the frames
// `ecu` sends and receives ('' = every frame, as sent). What the system description does not
// carry is written as a comment rather than invented: the receive deadline is ECU
// configuration (ComTimeout), the SecOC key is nobody's to export, and a layout this reader
// cannot state in bytes is named rather than approximated.
pub fn (c ArxmlCluster) frame_toml(ecu string) string {
	mut b := []string{}
	b << '# generated by arxml2dbc from cluster ${c.name} — import beside your hand-written'
	b << '# ecu.toml; a regeneration overwrites THIS file only'
	mut any_fd := false
	for _, f in c.frames {
		any_fd = any_fd || f.fd
	}
	// the bus line is the user's ([bus.<name>] is theirs to declare); what the cluster says
	// about it is stated here, since FD is a BUS property in ecu.toml and a frame's format
	// would otherwise leave with the DBC only
	data := if c.fd_baudrate > 0 { ', data_baudrate = ${c.fd_baudrate}' } else { '' }
	b << '# [bus.${c.name}]  baudrate = ${c.baudrate}${data}, fd = ${any_fd}'
	mut msgs := c.db.messages.clone()
	msgs.sort_with_compare(message_order)
	for m in msgs {
		f := c.frame_of(m) or { continue }
		sends := ecu == '' || ecu in m.senders()
		receives := ecu != '' && ecu in f.receivers
		if !sends && !receives {
			continue
		}
		b << ''
		b << '[[frame]]'
		b << 'name = "${m.name}"'
		b << 'bus  = "${c.name}"'
		if f.fd {
			b << '# CAN-FD frame (${m.dlc} bytes)'
		}
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
			// the deadline is the ECU's ComTimeout, which the system description does not
			// carry — left for the user, with the cadence beside it, rather than a number
			// derived from the cadence that would fail earlier or later than the real one
			cadence := if f.cycle_ms > 0 {
				"the sender's cycle is ${f.cycle_ms} ms"
			} else {
				'no cycle declared'
			}
			b << "# rx   = { timeout_ms = ? }  # set from the ECU's ComTimeout (${cadence})"
		}
		if e := f.e2e {
			// the SAME contract the DBC attributes carry (e2e_signals): a protection the
			// export cannot state exactly is named, never approximated into an entry
			if _ := c.e2e_signals(m) {
				b << 'e2e  = { data_id = 0x${e.data_id:X}, crc_pos = ${e.crc_byte()}, counter_pos = ${e.counter_byte()} }  # ${e.profile}'
			} else if !e.single_data_id() {
				ids := e.data_ids.map('0x${it:X}').join(', ')
				b << '# E2E ${e.profile} with ${e.data_id_mode} data ids (${ids}): this data-id mode is not expressible here'
			} else if e.has_crc_counter {
				b << '# E2E ${e.profile} (data_id 0x${e.data_id:X}, CRC at byte ${e.crc_byte()}, counter at byte ${e.counter_byte()}): not exported — the offsets do not land on dedicated CRC/counter signals, or the checksum is not one blobly computes'
			} else {
				b << '# E2E ${e.profile} (data_id 0x${e.data_id:X}, header at bit ${e.pdu_offset + e.data_offset + e.offset}): a fixed-header profile blobly_emb does not implement'
			}
		}
		if s := f.secoc {
			if s.byte_aligned {
				b << '# SecOC: the key is not in the system description — fill it in and uncomment'
				b << '# secoc = { key = "…", data_id = 0x${s.data_id:X}, fresh_pos = ${s.fresh_byte}, mac_pos = ${s.mac_byte}, mac_len = ${s.mac_len} }'
			} else {
				b << '# SecOC (data_id 0x${s.data_id:X}): a ${s.freshness_tx_len}-bit freshness and a ${s.auth_info_tx_len}-bit MAC at bit ${s.mac_bit}, which byte positions cannot express'
			}
		}
	}
	return b.join('\n') + '\n'
}
