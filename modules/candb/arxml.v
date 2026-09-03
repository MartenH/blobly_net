// arxml — read an AUTOSAR 4.x system description (.arxml) into the candb model (#272).
//
// An ARXML is what an OEM hands an AUTOSAR ECU supplier, and often there is no DBC at all —
// or the DBC is a lossy export with the protection and timing stripped. So this is a SECOND
// database front end beside dbc.v: it produces the same `Database` the DBC parser does, one
// per CAN cluster, plus what a DBC has no home for (`ArxmlFrame`): the TX mode and timing of
// the PDU, its receivers, and the E2E and SecOC layout. It is an EXTRACTOR into the model
// that already exists, deliberately not a model of ARXML — the schema is enormous and a
// reader that mirrored it would be maintained forever.
//
// The walk (System Template, 4.x element names — 3.x renamed half of them and is not shipped
// any more):
//
//   CAN-CLUSTER → CAN-PHYSICAL-CHANNEL → CAN-FRAME-TRIGGERING (id, addressing mode, FD)
//     → FRAME-REF → CAN-FRAME (length) → PDU-TO-FRAME-MAPPING (PDU offset)
//       → PDU-REF → I-SIGNAL-I-PDU (timing) → I-SIGNAL-TO-I-PDU-MAPPING (start, byte order)
//         → I-SIGNAL-REF → I-SIGNAL (length, base type) → SYSTEM-SIGNAL (description)
//           → COMPU-METHOD (factor/offset, enums), UNIT, DATA-CONSTR (range)
//     → FRAME-PORT-REF → ECU-INSTANCE (sender / receivers, by port direction)
//   END-TO-END-PROTECTION-SET → per protected I-SIGNAL-I-PDU: profile, data id, offsets
//   SECURED-I-PDU → freshness and MAC layout, then PAYLOAD-REF → the authentic I-SIGNAL-I-PDU
//
// Everything cross-references by package path (`/Pkg/Sub/Name`, in a `*-REF` element whose
// DEST names the target kind), so the reader first indexes every identifiable element (one
// with a SHORT-NAME) by its path and then follows references through that index.
//
// Read only; no schema validation. Two honesty rules instead, both in `ArxmlReport`:
//   1. a reference that does not resolve is REPORTED, by referrer and target — a dangling REF
//      is how an extract silently yields a frame with no signals;
//   2. what was ignored is COUNTED by element kind (container PDUs, LIN clusters, ...) — an
//      importer that quietly drops a PDU is worse than one that refuses.
//
// Bit numbering: an ARXML START-POSITION is the LSB for MOST-SIGNIFICANT-BYTE-LAST (Intel)
// and the MSB for MOST-SIGNIFICANT-BYTE-FIRST (Motorola), in byte-wise LSB-0 numbering —
// the same convention the DBC `@1` / `@0` start bit uses, and what `Signal.start_bit`
// holds, so the number is carried across as is (plus the PDU's own offset in the frame).
// cantools agrees (sut/ diffs the two — see docs/simulation.md and cmd/arxml2dbc).
module candb

import encoding.xml
import os

// ArxmlE2e is the AUTOSAR end-to-end protection declared for one PDU. Offsets are in BITS
// from the start of the protected data window, as the file states them; `crc_byte` and
// `counter_byte` are the same offsets in whole bytes from the start of the PDU, which is
// what blobly_emb's `[[frame]].e2e` and #271's attributes take.
pub struct ArxmlE2e {
pub:
	profile        string // END-TO-END-PROFILE CATEGORY: PROFILE_01, PROFILE_02, PROFILE_05 …
	data_id        u32
	data_ids       []u32 // every declared DATA-ID (profile 1 may alternate between two)
	data_id_mode   string // DATA-ID-MODE (ALL-16-BIT, LOWER-12-BIT, LOWER-8-BIT, ALTERNATING-8-BIT) or ''
	crc_offset     int // bits, within the data window
	counter_offset int // bits, within the data window
	data_offset    int // bits, where the protected window starts in the PDU
	data_length    int // bits
	crc_byte       int // (data_offset + crc_offset) / 8
	counter_byte   int // (data_offset + counter_offset) / 8
}

// ArxmlSecOc is the SecOC layout of a SECURED-I-PDU. The secured PDU is the authentic PDU
// followed by the transmitted part of the freshness value and then the truncated MAC —
// `fresh_byte`, `mac_byte` and `mac_len` derive that from the declared lengths in the form
// blobly_emb's `[[frame]].secoc` takes. The key is never in an ARXML.
pub struct ArxmlSecOc {
pub:
	data_id          u32
	freshness_len    int // FRESHNESS-VALUE-LENGTH, bits, the full counter
	freshness_tx_len int // FRESHNESS-VALUE-TX-LENGTH, bits actually on the wire
	auth_info_tx_len int // AUTH-INFO-TX-LENGTH, bits of MAC on the wire
	authentic_len    int // bytes of the authentic (payload) PDU
	fresh_byte       int // byte offset of the freshness value
	mac_byte         int // byte offset of the MAC
	mac_len          int // bytes of MAC, rounded up
}

// ArxmlFrame is what the system description says about a message that a DBC has no field for.
pub struct ArxmlFrame {
pub:
	pdu          string // the I-SIGNAL-I-PDU short name behind the frame (or the secured PDU's)
	pdu_kind     string // DEST of the PDU behind the frame: I-SIGNAL-I-PDU, SECURED-I-PDU, N-PDU, NM-PDU …
	tx_mode      string // 'cyclic' | 'event' | 'mixed' | '' — from the transmission-mode timing
	cycle_ms     int
	min_delay_ms int
	fd           bool // CAN-FRAME-TX-BEHAVIOR / RX-BEHAVIOR = CAN-FD
	receivers    []string // ECUs with an IN frame port on the triggering
	e2e          ?ArxmlE2e
	secoc        ?ArxmlSecOc
}

// ArxmlCluster is one CAN cluster: the bus, its Database, and the per-message extras.
pub struct ArxmlCluster {
pub:
	name        string
	baudrate    int
	fd_baudrate int
	db          Database
	frames      map[string]ArxmlFrame // keyed by message name
}

// ArxmlReport carries the two honesty rules' output.
pub struct ArxmlReport {
pub mut:
	unresolved []string // "<referrer> <TAG> -> <target> (<DEST>)"
	ignored    map[string]int // element kind -> how many were seen and not extracted
	notes      []string // things extracted PARTIALLY, one line each
}

// Arxml is a parsed system description.
pub struct Arxml {
pub:
	clusters []ArxmlCluster
	report   ArxmlReport
}

// cluster selects a CAN cluster by name; '' means "the only one", and is refused when there
// are several — naming the choices — rather than picking the first, because a bus chosen
// silently is a database applied to the wrong wire.
pub fn (a Arxml) cluster(name string) !ArxmlCluster {
	if a.clusters.len == 0 {
		return error('no CAN cluster in the file')
	}
	if name == '' {
		if a.clusters.len > 1 {
			return error('${a.clusters.len} CAN clusters (${a.clusters.map(it.name).join(', ')}): name one')
		}
		return a.clusters[0]
	}
	for c in a.clusters {
		if c.name == name {
			return c
		}
	}
	return error('no CAN cluster "${name}" (have ${a.clusters.map(it.name).join(', ')})')
}

// load_arxml_file reads and parses a .arxml from disk.
pub fn load_arxml_file(path string) !Arxml {
	return parse_arxml(os.read_file(path)!)!
}

// parse_arxml parses ARXML text. Pure (no I/O) so it is directly unit-testable.
pub fn parse_arxml(text string) !Arxml {
	doc := xml.XMLDocument.from_string(text) or { return error('not XML: ${err}') }
	if doc.root.name != 'AUTOSAR' {
		return error('root element is <${doc.root.name}>, not <AUTOSAR>')
	}
	ns := doc.root.attributes['xmlns'] or { '' }
	if ns != '' && !ns.contains('autosar.org/schema/r4') {
		// 3.x (autosar.org/3.x.y) renames half the elements this walk names, so nothing
		// below would match — say so rather than returning an empty database
		return error('AUTOSAR schema ${ns} is not 4.x')
	}
	mut r := &ArxmlReader{}
	r.index_node(doc.root, '')
	r.count_ignored()
	r.load_e2e()
	r.load_pdu_groups()
	mut clusters := []ArxmlCluster{}
	for path in r.kinds['CAN-CLUSTER'] {
		clusters << r.load_cluster(path)
	}
	return Arxml{
		clusters: clusters
		report: r.report
	}
}

// --- the walk ----------------------------------------------------------------------------

// Element kinds seen in a file and deliberately not extracted. Counted whether or not a frame
// leads to them: the report is about the FILE, so a reader of it knows what the export lacks.
const arxml_ignored_kinds = [
	'MULTIPLEXED-I-PDU',
	'CONTAINER-I-PDU',
	'N-PDU',
	'NM-PDU',
	'DCM-I-PDU',
	'USER-DEFINED-I-PDU',
	'GENERAL-PURPOSE-I-PDU',
	'GENERAL-PURPOSE-PDU',
	'I-SIGNAL-GROUP',
	'LIN-CLUSTER',
	'FLEXRAY-CLUSTER',
	'ETHERNET-CLUSTER',
	'END-TO-END-PROTECTION-VARIABLE-PROTOTYPE',
	'SO-AD-ROUTING-GROUP',
	'SOCKET-CONNECTION-BUNDLE',
]

struct ArxmlReader {
mut:
	by_path map[string]xml.XMLNode // every identifiable element, by AUTOSAR path
	kind_of map[string]string // path -> element name
	kinds   map[string][]string // element name -> paths, in document order
	e2e     map[string]ArxmlE2e // protected I-SIGNAL-I-PDU path -> its protection
	pdu_out map[string][]string // I-SIGNAL-I-PDU path -> ECUs whose OUT I-PDU group carries it
	pdu_in  map[string][]string // ... and whose IN group does
	report  ArxmlReport
}

// index_node registers every element that has a SHORT-NAME under the path its ancestors
// build. An element without one (a container such as ELEMENTS or FRAME-TRIGGERINGS) passes
// its parent's path down unchanged.
fn (mut r ArxmlReader) index_node(n xml.XMLNode, parent string) {
	mut path := parent
	if sn := child(n, 'SHORT-NAME') {
		path = '${parent}/${el_text(sn)}'
		r.by_path[path] = n
		r.kind_of[path] = n.name
		r.kinds[n.name] << path
	}
	for c in n.children {
		if c is xml.XMLNode {
			r.index_node(c, path)
		}
	}
}

fn (mut r ArxmlReader) count_ignored() {
	for k in arxml_ignored_kinds {
		if paths := r.kinds[k] {
			if paths.len > 0 {
				r.report.ignored[k] = paths.len
			}
		}
	}
}

// deref follows a `*-REF` child of `n` named `tag` and returns the target, recording a
// dangling one against `from` (the referrer's path, for the report).
fn (mut r ArxmlReader) deref(n xml.XMLNode, tag string, from string) ?xml.XMLNode {
	ref := child(n, tag) or { return none }
	return r.deref_node(ref, from)
}

fn (mut r ArxmlReader) deref_node(ref xml.XMLNode, from string) ?xml.XMLNode {
	target := el_text(ref)
	if t := r.by_path[target] {
		return t
	}
	dest := ref.attributes['DEST'] or { '?' }
	r.report.unresolved << '${from} ${ref.name} -> ${target} (${dest})'
	return none
}

fn (r ArxmlReader) path_of(n xml.XMLNode, fallback string) string {
	// cheap identity for report lines: the SHORT-NAME, since a node does not know its path
	if sn := child(n, 'SHORT-NAME') {
		return '${fallback}/${el_text(sn)}'
	}
	return fallback
}

// ecu_of climbs a port path (/ECUs/ECU_A/Conn/PortOut) to the ECU-INSTANCE that owns it.
fn (r ArxmlReader) ecu_of(port_path string) ?string {
	mut p := port_path
	for p.len > 0 {
		if k := r.kind_of[p] {
			if k == 'ECU-INSTANCE' {
				return p.all_after_last('/')
			}
		}
		i := p.last_index('/') or { return none }
		p = p[..i]
	}
	return none
}

// load_pdu_groups reads the SECOND way a system description says who sends and who listens:
// each ECU-INSTANCE's ASSOCIATED-COM-I-PDU-GROUP-REFS name I-SIGNAL-I-PDU-GROUPs with a
// COMMUNICATION-DIRECTION and the I-SIGNAL-I-PDUs in them (groups may contain groups). The
// first way is the FRAME-PORTs on the frame triggering; a file may carry either or both, and
// cantools reads only this one, so both are read and unioned.
fn (mut r ArxmlReader) load_pdu_groups() {
	for ecu_path in r.kinds['ECU-INSTANCE'] {
		ecu := r.by_path[ecu_path] or { continue }
		name := ecu_path.all_after_last('/')
		for gref in ecu.get_elements_by_tag('ASSOCIATED-COM-I-PDU-GROUP-REF') {
			group := r.deref_node(gref, ecu_path) or { continue }
			r.collect_pdu_group(group, el_text(gref), name, '', 0)
		}
	}
}

fn (mut r ArxmlReader) collect_pdu_group(group xml.XMLNode, group_path string, ecu string, dir_in string, depth int) {
	if depth > 8 {
		r.report.notes << '${group_path}: I-PDU groups nested deeper than 8, stopped'
		return
	}
	mut dir := child_text(group, 'COMMUNICATION-DIRECTION')
	if dir == '' {
		dir = dir_in
	}
	for pref in group.get_elements_by_tag('I-SIGNAL-I-PDU-REF') {
		target := el_text(pref)
		if target !in r.by_path {
			r.deref_node(pref, group_path)
			continue
		}
		if dir == 'OUT' {
			if ecu !in r.pdu_out[target] {
				r.pdu_out[target] << ecu
			}
		} else if dir == 'IN' {
			if ecu !in r.pdu_in[target] {
				r.pdu_in[target] << ecu
			}
		}
	}
	for cref in group.get_elements_by_tag('CONTAINED-I-SIGNAL-I-PDU-GROUP-REF') {
		sub := r.deref_node(cref, group_path) or { continue }
		r.collect_pdu_group(sub, el_text(cref), ecu, dir, depth + 1)
	}
}

// load_e2e collects every END-TO-END-PROTECTION into a map keyed by the protected PDU's path,
// so a frame can ask "is my PDU protected?" in one lookup.
fn (mut r ArxmlReader) load_e2e() {
	for set_path in r.kinds['END-TO-END-PROTECTION-SET'] {
		set := r.by_path[set_path] or { continue }
		for prot in set.get_elements_by_tag('END-TO-END-PROTECTION') {
			prot_path := r.path_of(prot, set_path)
			profile := child(prot, 'END-TO-END-PROFILE') or {
				r.report.notes << '${prot_path}: END-TO-END-PROTECTION without an END-TO-END-PROFILE, skipped'
				continue
			}
			mut ids := []u32{}
			for d in profile.get_elements_by_tag('DATA-ID') {
				ids << u32(parse_int(el_text(d)))
			}
			category := child_text(profile, 'CATEGORY')
			crc_off := parse_int(child_text(profile, 'CRC-OFFSET'))
			ctr_off := parse_int(child_text(profile, 'COUNTER-OFFSET'))
			mode := child_text(profile, 'DATA-ID-MODE')
			for tgt in prot.get_elements_by_tag('END-TO-END-PROTECTION-I-SIGNAL-I-PDU') {
				ref := child(tgt, 'I-SIGNAL-I-PDU-REF') or { continue }
				pdu_path := el_text(ref)
				if pdu_path !in r.by_path {
					r.deref_node(ref, prot_path)
					continue
				}
				d_off := parse_int(child_text(tgt, 'DATA-OFFSET'))
				d_len := parse_int(child_text(tgt, 'DATA-LENGTH'))
				if pdu_path in r.e2e {
					r.report.notes << '${pdu_path}: protected by more than one END-TO-END-PROTECTION, the first is kept'
					continue
				}
				r.e2e[pdu_path] = ArxmlE2e{
					profile: category
					data_id: if ids.len > 0 { ids[0] } else { 0 }
					data_ids: ids
					data_id_mode: mode
					crc_offset: crc_off
					counter_offset: ctr_off
					data_offset: d_off
					data_length: d_len
					crc_byte: (d_off + crc_off) / 8
					counter_byte: (d_off + ctr_off) / 8
				}
			}
		}
	}
}

fn (mut r ArxmlReader) load_cluster(path string) ArxmlCluster {
	cl := r.by_path[path] or { return ArxmlCluster{} }
	name := path.all_after_last('/')
	baud := parse_int(first_text(cl, 'BAUDRATE'))
	fd_baud := parse_int(first_text(cl, 'CAN-FD-BAUDRATE'))
	mut msgs := []Message{}
	mut frames := map[string]ArxmlFrame{}
	mut nodes := []string{}
	for ft in cl.get_elements_by_tag('CAN-FRAME-TRIGGERING') {
		ft_path := r.path_of(ft, path)
		frame := r.deref(ft, 'FRAME-REF', ft_path) or {
			if child(ft, 'FRAME-REF') == none {
				r.report.notes << '${ft_path}: CAN-FRAME-TRIGGERING without a FRAME-REF, skipped'
			}
			continue
		}
		fname := child_text(frame, 'SHORT-NAME')
		id := u32(parse_int(child_text(ft, 'IDENTIFIER')))
		ext := child_text(ft, 'CAN-ADDRESSING-MODE') == 'EXTENDED'
		fd := child_text(ft, 'CAN-FRAME-TX-BEHAVIOR') == 'CAN-FD' || child_text(ft, 'CAN-FRAME-RX-BEHAVIOR') == 'CAN-FD'
		dlc := parse_int(child_text(frame, 'FRAME-LENGTH'))

		// who sends, who listens: the frame ports on the triggering, by direction
		mut sender := ''
		mut tx_nodes := []string{}
		mut receivers := []string{}
		for pref in ft.get_elements_by_tag('FRAME-PORT-REF') {
			port := r.deref_node(pref, ft_path) or { continue }
			ecu := r.ecu_of(el_text(pref)) or { continue }
			if ecu !in nodes {
				nodes << ecu
			}
			if child_text(port, 'COMMUNICATION-DIRECTION') == 'OUT' {
				if sender == '' {
					sender = ecu
				} else if ecu != sender && ecu !in tx_nodes {
					tx_nodes << ecu
				}
			} else if ecu !in receivers {
				receivers << ecu
			}
		}

		// the PDU behind the frame
		mut sigs := []Signal{}
		mut info := ArxmlFrame{
			fd: fd
			receivers: receivers
		}
		for pm in frame.get_elements_by_tag('PDU-TO-FRAME-MAPPING') {
			pref := child(pm, 'PDU-REF') or { continue }
			pdu_path := el_text(pref)
			pdu := r.deref_node(pref, r.path_of(pm, '/' + fname)) or { continue }
			pdu_off := parse_int(child_text(pm, 'START-POSITION'))
			kind := pref.attributes['DEST'] or { pdu.name }
			info = ArxmlFrame{
				...info
				pdu: child_text(pdu, 'SHORT-NAME')
				pdu_kind: kind
			}
			mut sig_pdu := pdu
			mut sig_pdu_path := pdu_path
			if kind == 'SECURED-I-PDU' {
				info = ArxmlFrame{
					...info
					secoc: r.load_secoc(pdu, pdu_path)
				}
				// the authentic PDU is behind PAYLOAD-REF -> PDU-TRIGGERING -> I-PDU-REF
				trig := r.deref(pdu, 'PAYLOAD-REF', pdu_path) or { continue }
				iref := child(trig, 'I-PDU-REF') or {
					r.report.notes << '${pdu_path}: PAYLOAD-REF target has no I-PDU-REF, no signals'
					continue
				}
				sig_pdu = r.deref_node(iref, pdu_path) or { continue }
				sig_pdu_path = el_text(iref)
			}
			if sig_pdu.name != 'I-SIGNAL-I-PDU' {
				// N-PDU (ISO-TP), NM-PDU, container, multiplexed …: a real frame with a real
				// id, carried with no signals, exactly as a DBC would list it. Counted by
				// count_ignored, so nothing here is silent.
				continue
			}
			sigs << r.load_signals(sig_pdu, sig_pdu_path, pdu_off)
			tm := r.load_timing(sig_pdu)
			info = ArxmlFrame{
				...info
				tx_mode: tm.tx_mode
				cycle_ms: tm.cycle_ms
				min_delay_ms: tm.min_delay_ms
			}
			if e := r.e2e[sig_pdu_path] {
				info = ArxmlFrame{
					...info
					e2e: e
				}
			}
			// the I-PDU-group answer to who sends and who listens, unioned with the ports'
			for ecu in r.pdu_out[sig_pdu_path] {
				if ecu !in nodes {
					nodes << ecu
				}
				if sender == '' {
					sender = ecu
				} else if ecu != sender && ecu !in tx_nodes {
					tx_nodes << ecu
				}
			}
			for ecu in r.pdu_in[sig_pdu_path] {
				if ecu !in nodes {
					nodes << ecu
				}
				if ecu !in receivers {
					receivers << ecu
				}
			}
		}
		msgs << Message{
			name: fname
			id: id
			ext: ext
			dlc: dlc
			sender: sender
			tx_nodes: tx_nodes
			cycle_ms: info.cycle_ms
			signals: sigs
		}
		frames[fname] = ArxmlFrame{
			...info
			receivers: receivers
		}
	}
	return ArxmlCluster{
		name: name
		baudrate: baud
		fd_baudrate: fd_baud
		db: Database{
			messages: msgs
			nodes: nodes
		}
		frames: frames
	}
}

struct ArxmlTiming {
	tx_mode      string
	cycle_ms     int
	min_delay_ms int
}

// load_timing reads the TRUE transmission mode of an I-SIGNAL-I-PDU: cyclic if it has a
// CYCLIC-TIMING, event if an EVENT-CONTROLLED-TIMING, mixed if both. The FALSE mode (what
// the PDU does when its mode condition is off) is not read: COM's mode switching is ECU
// configuration, and a bench needs the cadence the bus is expected to carry.
fn (r ArxmlReader) load_timing(pdu xml.XMLNode) ArxmlTiming {
	spec := first(pdu, 'I-PDU-TIMING') or { return ArxmlTiming{} }
	min_delay := seconds_to_ms(first_text(spec, 'MINIMUM-DELAY'))
	tt := first(spec, 'TRANSMISSION-MODE-TRUE-TIMING') or {
		return ArxmlTiming{
			min_delay_ms: min_delay
		}
	}
	mut cycle := 0
	mut mode := ''
	if ct := first(tt, 'CYCLIC-TIMING') {
		if tp := first(ct, 'TIME-PERIOD') {
			cycle = seconds_to_ms(first_text(tp, 'VALUE'))
		}
		mode = 'cyclic'
	}
	if first(tt, 'EVENT-CONTROLLED-TIMING') != none {
		mode = if mode == 'cyclic' { 'mixed' } else { 'event' }
	}
	return ArxmlTiming{
		tx_mode: mode
		cycle_ms: cycle
		min_delay_ms: min_delay
	}
}

fn (mut r ArxmlReader) load_secoc(pdu xml.XMLNode, pdu_path string) ?ArxmlSecOc {
	props := first(pdu, 'SECURE-COMMUNICATION-PROPS') or {
		r.report.notes << '${pdu_path}: SECURED-I-PDU without SECURE-COMMUNICATION-PROPS, layout unknown'
		return none
	}
	fresh_tx := parse_int(child_text(props, 'FRESHNESS-VALUE-TX-LENGTH'))
	auth_tx := parse_int(child_text(props, 'AUTH-INFO-TX-LENGTH'))
	// the authentic PDU's length, in bytes: the secured PDU is payload ‖ freshness ‖ MAC
	mut authentic := 0
	if trig := r.deref(pdu, 'PAYLOAD-REF', pdu_path) {
		if ipdu := r.deref(trig, 'I-PDU-REF', pdu_path) {
			authentic = parse_int(child_text(ipdu, 'LENGTH'))
		}
	}
	if child(props, 'AUTH-DATA-FRESHNESS-START-POSITION') != none {
		r.report.notes << '${pdu_path}: AUTH-DATA-FRESHNESS (freshness taken from the payload) is not modelled; fresh_byte assumes a trailing freshness'
	}
	fresh_bytes := (fresh_tx + 7) / 8
	return ArxmlSecOc{
		data_id: u32(parse_int(child_text(props, 'DATA-ID')))
		freshness_len: parse_int(child_text(props, 'FRESHNESS-VALUE-LENGTH'))
		freshness_tx_len: fresh_tx
		auth_info_tx_len: auth_tx
		authentic_len: authentic
		fresh_byte: authentic
		mac_byte: authentic + fresh_bytes
		mac_len: (auth_tx + 7) / 8
	}
}

// load_signals reads every I-SIGNAL-TO-I-PDU-MAPPING of an I-SIGNAL-I-PDU. `pdu_off` is the
// PDU's bit offset inside the frame, added to each start position — it is byte-aligned in
// any real file, so it shifts an Intel and a Motorola start alike.
fn (mut r ArxmlReader) load_signals(pdu xml.XMLNode, pdu_path string, pdu_off int) []Signal {
	mut out := []Signal{}
	for m in pdu.get_elements_by_tag('I-SIGNAL-TO-I-PDU-MAPPING') {
		m_path := r.path_of(m, pdu_path)
		isig := r.deref(m, 'I-SIGNAL-REF', m_path) or {
			if child(m, 'I-SIGNAL-GROUP-REF') != none {
				// a signal group mapping: its members are mapped individually
				continue
			}
			continue
		}
		isig_path := el_text(child(m, 'I-SIGNAL-REF') or { continue })
		name := child_text(isig, 'SHORT-NAME')
		start := parse_int(child_text(m, 'START-POSITION')) + pdu_off
		order := if child_text(m, 'PACKING-BYTE-ORDER') == 'MOST-SIGNIFICANT-BYTE-FIRST' {
			ByteOrder.big_endian
		} else {
			ByteOrder.little_endian
		}
		length := parse_int(child_text(isig, 'LENGTH'))

		// base type: signedness (and the one encoding this model cannot hold)
		mut is_signed := false
		props := first(isig, 'SW-DATA-DEF-PROPS-CONDITIONAL') or {
			xml.XMLNode{
				name: ''
			}
		}
		if bt := r.deref(props, 'BASE-TYPE-REF', isig_path) {
			enc := first_text(bt, 'BASE-TYPE-ENCODING')
			if enc == '2C' || enc == '1C' || enc == 'SM' {
				is_signed = true
			} else if enc.starts_with('IEEE754') {
				r.report.notes << '${isig_path}: IEEE754 (floating-point) signal read as an unsigned integer'
			}
		}

		// scaling and enums: the compu method on the SYSTEM-SIGNAL's physical props (where the
		// standard puts the physical meaning, and the only place cantools looks), else the one
		// on the I-SIGNAL's network representation. Unit: the physical props' own, else the
		// compu method's, else the network representation's.
		mut factor := 1.0
		mut offset := 0.0
		mut values := map[u64]string{}
		mut unit := ''
		mut minimum := 0.0
		mut maximum := 0.0
		sys := r.deref(isig, 'SYSTEM-SIGNAL-REF', isig_path)
		sys_path := if s := sys { r.path_of(s, '') } else { '' }
		mut phys := xml.XMLNode{
			name: ''
		}
		if s := sys {
			if pp := first(s, 'PHYSICAL-PROPS') {
				phys = first(pp, 'SW-DATA-DEF-PROPS-CONDITIONAL') or { phys }
			}
		}
		mut cm := r.deref(phys, 'COMPU-METHOD-REF', sys_path)
		if cm == none {
			cm = r.deref(props, 'COMPU-METHOD-REF', isig_path)
		}
		mut scale := ArxmlScale{}
		if c := cm {
			scale = r.load_compu(c, isig_path, length)
			factor = scale.factor
			offset = scale.offset
			values = scale.values.clone()
		}
		if u := r.deref(phys, 'UNIT-REF', sys_path) {
			unit = first_text(u, 'DISPLAY-NAME')
		}
		if unit == '' {
			if c := cm {
				if u := r.deref(c, 'UNIT-REF', isig_path) {
					unit = first_text(u, 'DISPLAY-NAME')
				}
			}
		}
		if unit == '' {
			if u := r.deref(props, 'UNIT-REF', isig_path) {
				unit = first_text(u, 'DISPLAY-NAME')
			}
		}

		// range: a data constraint's physical limits, else its internal ones scaled, else the
		// domain of the linear compu scale (raw) scaled — the last being cantools' answer
		mut dc := r.deref(phys, 'DATA-CONSTR-REF', sys_path)
		if dc == none {
			dc = r.deref(props, 'DATA-CONSTR-REF', isig_path)
		}
		if d := dc {
			if pc := first(d, 'PHYS-CONSTRS') {
				minimum = parse_num(child_text(pc, 'LOWER-LIMIT'))
				maximum = parse_num(child_text(pc, 'UPPER-LIMIT'))
			} else if ic := first(d, 'INTERNAL-CONSTRS') {
				minimum = parse_num(child_text(ic, 'LOWER-LIMIT')) * factor + offset
				maximum = parse_num(child_text(ic, 'UPPER-LIMIT')) * factor + offset
			}
		} else if scale.has_domain {
			minimum = scale.lower * factor + offset
			maximum = scale.upper * factor + offset
		}

		// description: the system signal's, else the I-SIGNAL's own
		mut desc := ''
		if s := sys {
			desc = desc_text(s)
		}
		if desc == '' {
			desc = desc_text(isig)
		}

		out << Signal{
			name: name
			start_bit: start
			length: length
			factor: factor
			offset: offset
			minimum: minimum
			maximum: maximum
			unit: unit
			desc: desc
			values: values
			is_signed: is_signed
			byte_order: order
		}
	}
	return out
}

struct ArxmlScale {
	factor     f64 = 1.0
	offset     f64
	values     map[u64]string
	has_domain bool // the linear scale declared LOWER-LIMIT/UPPER-LIMIT (raw)
	lower      f64
	upper      f64
}

// load_compu reads a COMPU-METHOD's internal-to-physical scales: one LINEAR scale gives the
// factor and offset (numerator V0 = offset, V1 = factor, over denominator V0); TEXTTABLE
// scales with equal limits give the enum; SCALE_LINEAR_AND_TEXTTABLE gives both. A
// rational function with a non-constant denominator is not a factor/offset and is noted.
fn (mut r ArxmlReader) load_compu(cm xml.XMLNode, at string, width int) ArxmlScale {
	mut factor := 1.0
	mut offset := 0.0
	mut values := map[u64]string{}
	mut linear_seen := false
	mut has_domain := false
	mut lower := 0.0
	mut upper := 0.0
	mask := if width >= 64 { ~u64(0) } else { (u64(1) << width) - 1 }
	cm_name := child_text(cm, 'SHORT-NAME')
	itp := first(cm, 'COMPU-INTERNAL-TO-PHYS') or { return ArxmlScale{} }
	for s in itp.get_elements_by_tag('COMPU-SCALE') {
		lo := child_text(s, 'LOWER-LIMIT')
		hi := child_text(s, 'UPPER-LIMIT')
		if k := first(s, 'COMPU-CONST') {
			label := first_text(k, 'VT')
			if lo == hi && lo != '' {
				raw := parse_int(lo)
				values[u64(raw) & mask] = label
			} else {
				r.report.notes << '${at}: ${cm_name} maps the range ${lo}..${hi} to "${label}", which a value table cannot express; dropped'
			}
			continue
		}
		if rc := first(s, 'COMPU-RATIONAL-COEFFS') {
			mut num := []f64{}
			mut den := []f64{}
			if nn := first(rc, 'COMPU-NUMERATOR') {
				for v in nn.get_elements_by_tag('V') {
					num << parse_num(el_text(v))
				}
			}
			if dd := first(rc, 'COMPU-DENOMINATOR') {
				for v in dd.get_elements_by_tag('V') {
					den << parse_num(el_text(v))
				}
			}
			d := if den.len > 0 { den[0] } else { 1.0 }
			if den.len > 1 && den[1] != 0 {
				r.report.notes << '${at}: ${cm_name} is a rational function (non-constant denominator), read as factor 1 offset 0'
				continue
			}
			if num.len > 2 && num[2] != 0 {
				r.report.notes << '${at}: ${cm_name} is a polynomial of degree ${num.len - 1}, read as factor 1 offset 0'
				continue
			}
			if linear_seen {
				r.report.notes << '${at}: ${cm_name} has more than one linear scale, the first is kept'
				continue
			}
			linear_seen = true
			if d != 0 {
				offset = if num.len > 0 { num[0] / d } else { 0.0 }
				factor = if num.len > 1 { num[1] / d } else { 1.0 }
			}
			if lo != '' && hi != '' {
				has_domain = true
				lower = parse_num(lo)
				upper = parse_num(hi)
			}
		}
	}
	return ArxmlScale{
		factor: factor
		offset: offset
		values: values
		has_domain: has_domain
		lower: lower
		upper: upper
	}
}

// --- XML helpers ---------------------------------------------------------------------------

// child returns the first DIRECT child element named `name`.
fn child(n xml.XMLNode, name string) ?xml.XMLNode {
	for c in n.children {
		if c is xml.XMLNode {
			if c.name == name {
				return c
			}
		}
	}
	return none
}

fn child_text(n xml.XMLNode, name string) string {
	c := child(n, name) or { return '' }
	return el_text(c)
}

// first returns the first element named `name` anywhere below `n`, document order.
fn first(n xml.XMLNode, name string) ?xml.XMLNode {
	for c in n.children {
		if c is xml.XMLNode {
			if c.name == name {
				return c
			}
			if f := first(c, name) {
				return f
			}
		}
	}
	return none
}

fn first_text(n xml.XMLNode, name string) string {
	c := first(n, name) or { return '' }
	return el_text(c)
}

// desc_text reads a DESC's first language entry.
fn desc_text(n xml.XMLNode) string {
	d := child(n, 'DESC') or { return '' }
	return first_text(d, 'L-2')
}

// el_text is the element's own text, trimmed and with the five XML entities decoded —
// vlib's parser hands them through undecoded.
fn el_text(n xml.XMLNode) string {
	mut s := ''
	for c in n.children {
		if c is string {
			s += c
		}
	}
	return xml_unescape(s.trim_space())
}

fn xml_unescape(s string) string {
	if !s.contains('&') {
		return s
	}
	return s.replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"').replace('&apos;', "'").replace('&amp;', '&')
}

// parse_int reads an ARXML integer: decimal, 0x hex, or a float that happens to be integral
// ("8.0"). Anything else is 0.
fn parse_int(s string) int {
	t := s.trim_space()
	if t == '' {
		return 0
	}
	if t.starts_with('0x') || t.starts_with('0X') {
		return int(t[2..].parse_uint(16, 64) or { 0 })
	}
	if t.contains('.') || t.contains('e') || t.contains('E') {
		return int(t.f64())
	}
	return int(t.i64())
}

fn parse_num(s string) f64 {
	t := s.trim_space()
	if t.starts_with('0x') || t.starts_with('0X') {
		return f64(t[2..].parse_uint(16, 64) or { 0 })
	}
	return t.f64()
}

// seconds_to_ms converts an ARXML time (seconds, "0.1" or "1.0E-2") to whole milliseconds,
// rounded — a 100 ms period written as 0.1 must not come back as 99.
fn seconds_to_ms(s string) int {
	if s.trim_space() == '' {
		return 0
	}
	return int(parse_num(s) * 1000.0 + 0.5)
}
