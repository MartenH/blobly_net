module candb

import os

// dbc/example.arxml is the hand-written AUTOSAR 4.2 fixture: one feature per frame, so a
// failing assertion names the feature. cantools reads the same file (sut/arxml_oracle.py),
// which is what keeps it a real AUTOSAR file rather than one only this reader accepts.
fn example_arxml() Arxml {
	path := os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'example.arxml')
	return load_arxml_file(path) or { panic('cannot load ${path}: ${err}') }
}

fn sig(m Message, name string) Signal {
	for s in m.signals {
		if s.name == name {
			return s
		}
	}
	panic('no signal ${name} in ${m.name}')
}

fn test_cluster_and_nodes() {
	a := example_arxml()
	assert a.clusters.len == 1
	c := a.cluster('') or { panic(err) }
	assert c.name == 'Body'
	assert c.baudrate == 500000
	assert c.fd_baudrate == 2000000
	assert c.db.messages.len == 5
	assert c.db.nodes == ['ECU_A', 'ECU_B', 'ECU_C']
	// the file is complete: nothing dangling, and the one partial read is the mixed-format
	// cluster, which the simulation cannot carry per frame
	assert a.report.unresolved == []
	assert a.report.notes == [
		'/PDUs/LampFrame_PDU: cyclic and event-controlled timing; the simulation sends on the cycle only, never on a change',
		"LampFrame: declares an E2E PROFILE_01 contract; carried to the DBC export and the fragment, but NOT applied by the native simulation, which protects only what the project's protect: entries name",
		'SecureFrame: declares SecOC protection; carried to the fragment, but NOT applied by the native simulation, which has no SecOC stamping — freshness and MAC bytes go out as 0',
		'/PDUs/Wide_PDU: event-controlled timing only, no cyclic timing; the simulation sends on a cycle and sends nothing for this frame',
		'/Cluster/Body: 1 CAN-FD and 4 classic frames on one cluster; the simulation applies one format per bus, the export keeps the distinction',
	]
	// and the one PDU kind not extracted is counted, not dropped in silence
	assert a.report.ignored == {
		'N-PDU': 1
	}
}

fn test_plain_cyclic_frame_with_every_signal_shape() {
	c := example_arxml().cluster('Body') or { panic(err) }
	m := c.db.lookup(0x100) or { panic('no Powertrain') }
	assert m.name == 'Powertrain'
	assert !m.ext
	assert m.dlc == 8
	assert m.sender == 'ECU_A'
	assert m.tx_nodes == []
	assert m.cycle_ms == 100
	f := c.frame_of(m) or { panic('no frame info') }
	assert f.pdu == 'Powertrain_PDU'
	assert f.pdu_kind == 'I-SIGNAL-I-PDU'
	assert f.tx_mode == 'cyclic'
	assert f.cycle_ms == 100
	assert f.min_delay_ms == 20
	assert !f.fd
	assert f.receivers == ['ECU_B', 'ECU_C']
	assert f.e2e == none
	assert f.secoc == none
	assert m.signals.len == 4
	// every signal carries the frame's receivers, the way a DBC states them
	assert m.signals.all(it.receivers == ['ECU_B', 'ECU_C'])

	// Intel, linear compu method, unit via the compu method, physical range, entity in desc
	es := sig(m, 'EngineSpeed')
	assert es.start_bit == 0
	assert es.length == 16
	assert es.byte_order == .little_endian
	assert !es.is_signed
	assert es.factor == 0.25
	assert es.offset == 0
	assert es.unit == 'rpm'
	assert es.minimum == 0
	assert es.maximum == 8000
	assert es.desc == 'Engine speed & direction'

	// signed (2C base type), a denominator that is not 1, an INTERNAL range scaled to physical
	ct := sig(m, 'CoolantTemp')
	assert ct.start_bit == 16
	assert ct.length == 8
	assert ct.is_signed
	assert ct.factor == 1
	assert ct.offset == -20
	assert ct.unit == '°C'
	assert ct.minimum == -120
	assert ct.maximum == 80

	// TEXTTABLE -> value table, keys width-masked
	g := sig(m, 'Gear')
	assert g.start_bit == 24
	assert g.length == 4
	assert g.factor == 1
	assert g.values == {
		u64(0):  'Neutral'
		u64(1):  'First'
		u64(15): 'Reverse'
	}

	// Motorola start position carried as the DBC MSB start bit; compu method AND unit found
	// on the SYSTEM-SIGNAL's physical props when the I-SIGNAL has none
	tq := sig(m, 'Torque')
	assert tq.byte_order == .big_endian
	assert tq.start_bit == 39
	assert tq.length == 12
	assert tq.factor == 0.5
	assert tq.offset == -500
	assert tq.unit == 'Nm'
}

fn test_e2e_protected_frame() {
	c := example_arxml().cluster('Body') or { panic(err) }
	m := c.db.lookup(0x200) or { panic('no LampFrame') }
	assert m.sender == 'ECU_B'
	assert m.cycle_ms == 100 // written as 1.0E-1 s
	

	f := c.frame_of(m) or { panic('no frame info') }
	assert f.tx_mode == 'mixed'
	assert f.min_delay_ms == 10
	assert f.receivers == ['ECU_A']
	e := f.e2e or { panic('LampFrame has no E2E') }
	assert e.profile == 'PROFILE_01'
	assert e.data_id == 42
	assert e.data_ids == [u32(42)]
	assert e.data_id_mode == 'ALL-16-BIT'
	assert e.has_crc_counter
	assert e.crc_offset == 48
	assert e.counter_offset == 56
	assert e.data_length == 64
	assert e.pdu_offset == 0
	assert e.crc_byte() == 6
	assert e.counter_byte() == 7
	// the CRC and counter SIGNALS sit exactly there — what #271's attributes will name
	assert sig(m, 'LampCrc').start_bit == 48
	assert sig(m, 'LampCounter').start_bit == 56
	assert sig(m, 'LampCounter').length == 4
}

fn test_secoc_frame_reaches_the_authentic_pdu() {
	c := example_arxml().cluster('Body') or { panic(err) }
	m := c.db.lookup(0x300) or { panic('no SecureFrame') }
	assert m.dlc == 8
	assert m.sender == 'ECU_B'
	assert m.cycle_ms == 50
	f := c.frame_of(m) or { panic('no frame info') }
	assert f.pdu == 'Secure_PDU'
	assert f.pdu_kind == 'SECURED-I-PDU'
	assert f.tx_mode == 'cyclic'
	s := f.secoc or { panic('SecureFrame has no SecOC') }
	assert s.data_id == 43
	assert s.freshness_len == 64
	assert s.freshness_tx_len == 8
	assert s.auth_info_tx_len == 32
	assert s.authentic_len == 3
	assert s.pdu_offset == 0
	assert s.fresh_bit == 24
	assert s.mac_bit == 32
	assert s.byte_aligned
	assert s.fresh_byte == 3
	assert s.mac_byte == 4
	assert s.mac_len == 4
	// the signals come from the AUTHENTIC PDU behind PAYLOAD-REF
	assert m.signals.len == 1
	assert sig(m, 'Rpm').length == 16
}

fn test_extended_fd_event_frame() {
	c := example_arxml().cluster('Body') or { panic(err) }
	m := c.db.lookup(0x1ABCDE) or { panic('no Wide') } // exact: no J1939 PGN fallback
	assert m.name == 'Wide'
	assert m.ext
	assert m.dlc == 16
	assert m.sender == 'ECU_C'
	assert m.cycle_ms == 0
	f := c.frame_of(m) or { panic('no frame info') }
	assert f.fd
	assert f.tx_mode == 'event'
	assert f.receivers == []
	od := sig(m, 'Odometer')
	assert od.start_bit == 64
	assert od.length == 32
	assert od.factor == 0.1
	assert od.unit == 'km'
}

fn test_n_pdu_frame_is_a_frame_without_signals() {
	c := example_arxml().cluster('Body') or { panic(err) }
	m := c.db.lookup(0x7E0) or { panic('no DiagReq') }
	assert m.signals.len == 0
	assert m.sender == ''
	f := c.frame_of(m) or { panic('no frame info') }
	assert f.pdu_kind == 'N-PDU'
	assert f.receivers == ['ECU_A']
}

fn test_export_round_trips_through_the_dbc_writer() {
	c := example_arxml().cluster('Body') or { panic(err) }
	text := c.db.to_dbc()
	back := parse_dbc(text) or { panic(err) }
	assert back.to_dbc() == text
	assert back.messages.len == 5
	pt := back.lookup(0x100) or { panic('no Powertrain after round trip') }
	assert pt.cycle_ms == 100
	assert sig(pt, 'Torque').start_bit == 39
	assert sig(pt, 'Gear').values.len == 3
}

// --- the honesty rules, on inline fixtures ------------------------------------------------
const arxml_head = '<?xml version="1.0" encoding="UTF-8"?>
<AUTOSAR xmlns="http://autosar.org/schema/r4.0"><AR-PACKAGES>'
const arxml_tail = '</AR-PACKAGES></AUTOSAR>'

fn cluster_xml(name string, id int, frame_ref string) string {
	return '<AR-PACKAGE><SHORT-NAME>${name}</SHORT-NAME><ELEMENTS><CAN-CLUSTER><SHORT-NAME>${name}</SHORT-NAME>\n<CAN-CLUSTER-VARIANTS><CAN-CLUSTER-CONDITIONAL><BAUDRATE>500000</BAUDRATE><PHYSICAL-CHANNELS>\n<CAN-PHYSICAL-CHANNEL><SHORT-NAME>Ch</SHORT-NAME><FRAME-TRIGGERINGS>\n<CAN-FRAME-TRIGGERING><SHORT-NAME>FT</SHORT-NAME><FRAME-REF DEST="CAN-FRAME">${frame_ref}</FRAME-REF>\n<CAN-ADDRESSING-MODE>STANDARD</CAN-ADDRESSING-MODE><IDENTIFIER>${id}</IDENTIFIER></CAN-FRAME-TRIGGERING>\n</FRAME-TRIGGERINGS></CAN-PHYSICAL-CHANNEL></PHYSICAL-CHANNELS></CAN-CLUSTER-CONDITIONAL></CAN-CLUSTER-VARIANTS>\n</CAN-CLUSTER></ELEMENTS></AR-PACKAGE>'
}

const frame_xml = '<AR-PACKAGE><SHORT-NAME>Frames</SHORT-NAME><ELEMENTS><CAN-FRAME><SHORT-NAME>F</SHORT-NAME>
<FRAME-LENGTH>8</FRAME-LENGTH><PDU-TO-FRAME-MAPPINGS><PDU-TO-FRAME-MAPPING><SHORT-NAME>M</SHORT-NAME>
<PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/Missing</PDU-REF><START-POSITION>0</START-POSITION>
</PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS></CAN-FRAME></ELEMENTS></AR-PACKAGE>'

fn test_dangling_reference_is_reported_not_swallowed() {
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + frame_xml + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	// the frame is real (it has an id) and carries no signals — and the report says WHY
	assert c.db.messages.len == 1
	assert c.db.messages[0].signals.len == 0
	assert a.report.unresolved.len == 1
	assert a.report.unresolved[0].contains('PDU-REF -> /PDUs/Missing (I-SIGNAL-I-PDU)')
}

fn test_dangling_frame_ref_skips_the_triggering_and_reports_it() {
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/Nope') + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	assert c.db.messages.len == 0
	assert a.report.unresolved.len == 1
	assert a.report.unresolved[0].contains('FRAME-REF -> /Frames/Nope')
}

fn test_several_clusters_must_be_named() {
	a := parse_arxml(arxml_head + cluster_xml('Body', 1, '/Frames/F') + cluster_xml('Chassis', 2, '/Frames/F') + frame_xml + arxml_tail) or { panic(err) }
	assert a.clusters.len == 2
	if _ := a.cluster('') {
		assert false, 'two clusters and no name must be refused'
	} else {
		assert err.msg().contains('Body')
		assert err.msg().contains('Chassis')
	}
	assert (a.cluster('Chassis') or { panic(err) }).db.messages[0].id == 2
	if _ := a.cluster('Powertrain') {
		assert false
	} else {
		assert err.msg().contains('no CAN cluster "Powertrain"')
	}
}

fn test_ignored_kinds_are_counted_from_the_whole_file() {
	extra := '<AR-PACKAGE><SHORT-NAME>Other</SHORT-NAME><ELEMENTS>
<LIN-CLUSTER><SHORT-NAME>Lin1</SHORT-NAME></LIN-CLUSTER>
<CONTAINER-I-PDU><SHORT-NAME>C1</SHORT-NAME></CONTAINER-I-PDU>
<CONTAINER-I-PDU><SHORT-NAME>C2</SHORT-NAME></CONTAINER-I-PDU>
</ELEMENTS></AR-PACKAGE>'
	a := parse_arxml(arxml_head + extra + arxml_tail) or { panic(err) }
	assert a.clusters.len == 0
	assert a.report.ignored == {
		'LIN-CLUSTER':     1
		'CONTAINER-I-PDU': 2
	}
	if _ := a.cluster('') {
		assert false
	} else {
		assert err.msg() == 'no CAN cluster in the file'
	}
}

fn test_namespace_prefixed_document_reads_the_same() {
	// the same fixture with every element prefixed `ar:` — a prefix is the author's choice
	path := os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'example.arxml')
	plain := os.read_file(path) or { panic(err) }
	prefixed := plain.replace('<AUTOSAR xmlns="http://autosar.org/schema/r4.0"', '<ar:AUTOSAR xmlns:ar="http://autosar.org/schema/r4.0"')
	mut out := []string{}
	mut in_comment := false
	for line in prefixed.split_into_lines() {
		mut l := line
		if l.contains('<!--') {
			in_comment = true
		}
		if !in_comment {
			// <NAME> and </NAME> get the prefix; the root was done above
			l = l.replace('</', '</ar:').replace('<ar:ar:', '<ar:')
			mut o := ''
			mut i := 0
			for i < l.len {
				if l[i] == `<` && i + 1 < l.len && l[i + 1] != `/` && l[i + 1] != `!` && l[i + 1] != `?` && !l[i..].starts_with('<ar:') {
					o += '<ar:'
				} else {
					o += l[i].ascii_str()
				}
				i++
			}
			l = o
		}
		if l.contains('-->') {
			in_comment = false
		}
		out << l
	}
	a := parse_arxml(out.join('\n')) or { panic(err) }
	c := a.cluster('') or { panic(err) }
	assert c.db.messages.len == 5
	assert c.db.nodes == ['ECU_A', 'ECU_B', 'ECU_C']
	pt := c.db.lookup(0x100) or { panic('no Powertrain') }
	assert pt.signals.len == 4
	assert sig(pt, 'EngineSpeed').desc == 'Engine speed & direction'
	assert (c.frame_of(c.db.lookup(0x200) or { panic('no LampFrame') }) or { panic('no frame') }).e2e != none
	assert a.report.ignored == {
		'N-PDU': 1
	}
}

fn test_descriptions_keep_marked_up_text_and_enum_bounds_compare_numerically() {
	marked := offset_pdu_xml.replace('<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL>', '<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH><DESC><L-2 L="EN">checksum over <E>all</E> bytes, see <TT>E2E</TT></L-2></DESC><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>Sys</SHORT-NAME><ELEMENTS><SYSTEM-SIGNAL><SHORT-NAME>S</SHORT-NAME><PHYSICAL-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/T</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></PHYSICAL-PROPS></SYSTEM-SIGNAL></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>T</SHORT-NAME><CATEGORY>TEXTTABLE</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><LOWER-LIMIT>1</LOWER-LIMIT><UPPER-LIMIT>1.0</UPPER-LIMIT><COMPU-CONST><VT>One</VT></COMPU-CONST></COMPU-SCALE><COMPU-SCALE><LOWER-LIMIT>2</LOWER-LIMIT><UPPER-LIMIT>2E0</UPPER-LIMIT><COMPU-CONST><VT>Two</VT></COMPU-CONST></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>'
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + marked + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	s := sig(c.db.messages[0], 'Crc')
	assert s.desc == 'checksum over all bytes, see E2E'
	assert s.values == {
		u64(1): 'One'
		u64(2): 'Two'
	}
}

fn test_event_bursts_are_carried_and_named_in_the_fragment() {
	burst := offset_pdu_xml.replace('<LENGTH>4</LENGTH>\n<I-SIGNAL-TO-PDU-MAPPINGS>', '<LENGTH>4</LENGTH><I-PDU-TIMING-SPECIFICATIONS><I-PDU-TIMING><TRANSMISSION-MODE-DECLARATION><TRANSMISSION-MODE-TRUE-TIMING><EVENT-CONTROLLED-TIMING><NUMBER-OF-REPETITIONS>2</NUMBER-OF-REPETITIONS><REPETITION-PERIOD><VALUE>0.02</VALUE></REPETITION-PERIOD></EVENT-CONTROLLED-TIMING></TRANSMISSION-MODE-TRUE-TIMING></TRANSMISSION-MODE-DECLARATION></I-PDU-TIMING></I-PDU-TIMING-SPECIFICATIONS>\n<I-SIGNAL-TO-PDU-MAPPINGS>')
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + burst + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	f := c.frame_of(c.db.messages[0]) or { panic('no frame') }
	assert f.tx_mode == 'event'
	assert f.repetitions == 2
	assert f.repetition_ms == 20
	assert c.frame_toml('').contains('# event burst: a change is sent 3 times, 20 ms apart')
	// and the native load path hears about it too, not only the fragment
	assert a.report.notes.any(it.contains('event-controlled timing repeats a change 2 more times 20 ms apart; the simulation sends once'))
}

fn test_not_autosar_and_not_4x_are_refused() {
	if _ := parse_arxml('<?xml version="1.0"?><ROOT/>') {
		assert false
	} else {
		assert err.msg().contains('<ROOT>')
	}
	if _ := parse_arxml('<?xml version="1.0"?><AUTOSAR xmlns="http://autosar.org/3.2.3"></AUTOSAR>') {
		assert false
	} else {
		assert err.msg().contains('not 4.x')
	}
	// the guard reads the namespace the ROOT is in, prefixed or not
	if _ := parse_arxml('<?xml version="1.0"?><ar:AUTOSAR xmlns:ar="http://autosar.org/3.2.3"></ar:AUTOSAR>') {
		assert false, 'a prefixed 3.x root must be refused too'
	} else {
		assert err.msg().contains('not 4.x')
	}
	if _ := parse_arxml('this is not xml') {
		assert false
	} else {
		assert err.msg().starts_with('not XML')
	}
}

// --- the layout traps the review named ------------------------------------------------------

// a PDU that does not start at byte 0 of its frame: signal starts shift, and so must the E2E
// byte positions — blobly_emb's crc_pos/counter_pos are frame-relative
const offset_pdu_xml = '<AR-PACKAGE><SHORT-NAME>Frames</SHORT-NAME><ELEMENTS><CAN-FRAME><SHORT-NAME>F</SHORT-NAME>
<FRAME-LENGTH>8</FRAME-LENGTH><PDU-TO-FRAME-MAPPINGS><PDU-TO-FRAME-MAPPING><SHORT-NAME>M</SHORT-NAME>
<PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF><START-POSITION>8</START-POSITION>
</PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS></CAN-FRAME></ELEMENTS></AR-PACKAGE>
<AR-PACKAGE><SHORT-NAME>PDUs</SHORT-NAME><ELEMENTS><I-SIGNAL-I-PDU><SHORT-NAME>P</SHORT-NAME><LENGTH>4</LENGTH>
<I-SIGNAL-TO-PDU-MAPPINGS>
<I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MV</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/Sig/V</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>0</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING>
<I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MC</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/Sig/Crc</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>16</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING>
<I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MN</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/Sig/Ctr</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>24</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING>
</I-SIGNAL-TO-PDU-MAPPINGS></I-SIGNAL-I-PDU></ELEMENTS></AR-PACKAGE>
<AR-PACKAGE><SHORT-NAME>Sig</SHORT-NAME><ELEMENTS>
<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH></I-SIGNAL>
<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL>
<I-SIGNAL><SHORT-NAME>Ctr</SHORT-NAME><LENGTH>4</LENGTH></I-SIGNAL>
</ELEMENTS></AR-PACKAGE>'

fn e2e_xml(profile string, offsets string) string {
	return '<AR-PACKAGE><SHORT-NAME>E2E</SHORT-NAME><ELEMENTS><END-TO-END-PROTECTION-SET><SHORT-NAME>S</SHORT-NAME>\n<END-TO-END-PROTECTIONS><END-TO-END-PROTECTION><SHORT-NAME>P</SHORT-NAME><END-TO-END-PROFILE>\n<CATEGORY>${profile}</CATEGORY>${offsets}<DATA-IDS><DATA-ID>7</DATA-ID></DATA-IDS><DATA-LENGTH>32</DATA-LENGTH>\n</END-TO-END-PROFILE><END-TO-END-PROTECTION-I-SIGNAL-I-PDUS><END-TO-END-PROTECTION-I-SIGNAL-I-PDU>\n<DATA-LENGTH>32</DATA-LENGTH><DATA-OFFSET>0</DATA-OFFSET><I-SIGNAL-I-PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</I-SIGNAL-I-PDU-REF>\n</END-TO-END-PROTECTION-I-SIGNAL-I-PDU></END-TO-END-PROTECTION-I-SIGNAL-I-PDUS></END-TO-END-PROTECTION>\n</END-TO-END-PROTECTIONS></END-TO-END-PROTECTION-SET></ELEMENTS></AR-PACKAGE>'
}

fn test_e2e_positions_are_frame_relative_when_the_pdu_is_offset() {
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>16</CRC-OFFSET>') + arxml_tail) or { panic(err) }
	assert a.report.unresolved == []
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	// the PDU begins at frame byte 1: every signal moved by 8 bits …
	assert sig(m, 'V').start_bit == 8
	assert sig(m, 'Crc').start_bit == 24
	assert sig(m, 'Ctr').start_bit == 32
	// … and so did the protection
	f := c.frame_of(m) or { panic('no frame info') }
	e := f.e2e or { panic('unprotected') }
	assert e.pdu_offset == 8
	assert e.crc_byte() == 3
	assert e.counter_byte() == 4
	s := c.e2e_signals(m) or { panic('no e2e signals') }
	assert s.crc == 'Crc'
	assert s.counter == 'Ctr'
	assert c.frame_toml('').contains('e2e  = { data_id = 0x7, crc_pos = 3, counter_pos = 4 }')
	// the fields must be EXACTLY the profile's widths: a 4-bit signal at the CRC offset is not
	// an 8-bit CRC, and a 2-bit one at the counter offset wraps early
	narrow := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH>', '<SHORT-NAME>Crc</SHORT-NAME><LENGTH>4</LENGTH>') + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>16</CRC-OFFSET>') + arxml_tail) or { panic(err) }
	nc := narrow.cluster('') or { panic(err) }
	assert nc.e2e_signals(nc.db.messages[0]) == none
	assert !nc.frame_toml('').contains('\ne2e  =')
	// and on a byte boundary: a CRC at bit 20 has no crc_pos
	skew := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<START-POSITION>16</START-POSITION>', '<START-POSITION>12</START-POSITION>') + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>12</CRC-OFFSET>') + arxml_tail) or { panic(err) }
	sc := skew.cluster('') or { panic(err) }
	assert sig(sc.db.messages[0], 'Crc').start_bit == 20
	assert sc.e2e_signals(sc.db.messages[0]) == none
	assert !sc.frame_toml('').contains('\ne2e  =')
}

fn test_package_scoped_names_are_never_folded() {
	// the class the review kept finding one kind at a time: a SHORT-NAME is scoped per
	// package, and the reader must not fold two of them into one identity — clusters and
	// frames are covered above; here ECUs and signals
	ecus := '<AR-PACKAGE><SHORT-NAME>A</SHORT-NAME><ELEMENTS><ECU-INSTANCE><SHORT-NAME>Node</SHORT-NAME><CONNECTORS><CAN-COMMUNICATION-CONNECTOR><SHORT-NAME>Conn</SHORT-NAME><ECU-COMM-PORT-INSTANCES><FRAME-PORT><SHORT-NAME>Out</SHORT-NAME><COMMUNICATION-DIRECTION>OUT</COMMUNICATION-DIRECTION></FRAME-PORT></ECU-COMM-PORT-INSTANCES></CAN-COMMUNICATION-CONNECTOR></CONNECTORS></ECU-INSTANCE></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>B</SHORT-NAME><ELEMENTS><ECU-INSTANCE><SHORT-NAME>Node</SHORT-NAME><CONNECTORS><CAN-COMMUNICATION-CONNECTOR><SHORT-NAME>Conn</SHORT-NAME><ECU-COMM-PORT-INSTANCES><FRAME-PORT><SHORT-NAME>In</SHORT-NAME><COMMUNICATION-DIRECTION>IN</COMMUNICATION-DIRECTION></FRAME-PORT></ECU-COMM-PORT-INSTANCES></CAN-COMMUNICATION-CONNECTOR></CONNECTORS></ECU-INSTANCE></ELEMENTS></AR-PACKAGE>'
	ported := cluster_xml('Bus', 256, '/Frames/F').replace('<FRAME-REF DEST="CAN-FRAME">', '<FRAME-PORT-REFS><FRAME-PORT-REF DEST="FRAME-PORT">/A/Node/Conn/Out</FRAME-PORT-REF><FRAME-PORT-REF DEST="FRAME-PORT">/B/Node/Conn/In</FRAME-PORT-REF></FRAME-PORT-REFS><FRAME-REF DEST="CAN-FRAME">')
	a := parse_arxml(arxml_head + ported + frame_xml + ecus + arxml_tail) or { panic(err) }
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	// two ECUs, two names — one sends, the other listens, and nothing says "Node sends to Node"
	assert m.sender == 'A_Node'
	assert (c.frame_of(m) or { panic('no frame') }).receivers == ['B_Node']
	assert c.db.nodes == ['A_Node', 'B_Node']
	assert c.ecus() == ['A_Node', 'B_Node']
	assert a.report.notes.filter(it.contains('ECU name Node is used by another package too')).len == 2
	// qualification is not injective on its own: a plain /C/A_Node is spelled like the
	// qualified /A/Node, so names are allocated against what was given out
	three := ecus.replace_once('</ELEMENTS></AR-PACKAGE>', '</ELEMENTS></AR-PACKAGE><AR-PACKAGE><SHORT-NAME>C</SHORT-NAME><ELEMENTS><ECU-INSTANCE><SHORT-NAME>A_Node</SHORT-NAME></ECU-INSTANCE></ELEMENTS></AR-PACKAGE>')
	t := parse_arxml(arxml_head + ported + frame_xml + three + arxml_tail) or { panic(err) }
	assert t.report.notes.any(it.contains('/A/Node: ECU name Node is used by another package too; this one is A_Node_2'))
	assert !t.report.notes.any(it.contains('/C/A_Node'))

	// two I-SIGNALs of one SHORT-NAME from two packages in one message (a two-PDU frame)
	two := offset_pdu_xml.replace('</PDU-TO-FRAME-MAPPINGS>', '<PDU-TO-FRAME-MAPPING><SHORT-NAME>M2</SHORT-NAME><PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P2</PDU-REF><START-POSITION>40</START-POSITION></PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS>').replace('</I-SIGNAL-I-PDU></ELEMENTS>', '</I-SIGNAL-I-PDU><I-SIGNAL-I-PDU><SHORT-NAME>P2</SHORT-NAME><LENGTH>1</LENGTH><I-SIGNAL-TO-PDU-MAPPINGS><I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MX</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/Sig2/V</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>0</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING></I-SIGNAL-TO-PDU-MAPPINGS></I-SIGNAL-I-PDU></ELEMENTS>') + '<AR-PACKAGE><SHORT-NAME>Sig2</SHORT-NAME><ELEMENTS><I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL></ELEMENTS></AR-PACKAGE>'
	d := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + two + arxml_tail) or {
		panic(err)
	}
	dc := d.cluster('') or { panic(err) }
	names := dc.db.messages[0].signals.map(it.name)
	assert names == ['V', 'Crc', 'Ctr', 'Sig2_V']
	// a third signal whose OWN name is the qualified spelling of an earlier duplicate keeps it:
	// unique names are reserved before duplicates are qualified (round 30), so the duplicate
	// /Sig2/V is the one that moves on, to the suffix path the ECU case above shows
	third := two.replace('</I-SIGNAL-TO-PDU-MAPPINGS></I-SIGNAL-I-PDU></ELEMENTS>', '<I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MY</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/Sig3/Sig2_V</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>0</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING></I-SIGNAL-TO-PDU-MAPPINGS></I-SIGNAL-I-PDU></ELEMENTS>') + '<AR-PACKAGE><SHORT-NAME>Sig3</SHORT-NAME><ELEMENTS><I-SIGNAL><SHORT-NAME>Sig2_V</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL></ELEMENTS></AR-PACKAGE>'
	t3 := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + third + arxml_tail) or {
		panic(err)
	}
	t3c := t3.cluster('') or { panic(err) }
	assert t3c.db.messages[0].signals.map(it.name) == ['V', 'Crc', 'Ctr', 'Sig2_V_2', 'Sig2_V']
	assert t3.report.notes.any(it.contains('/Sig2/V: signal name V is already used in this message; this one is Sig2_V_2'))
	assert d.report.notes.any(it.contains('signal name V is already used in this message; this one is Sig2_V'))
	// and the DBC export has no duplicate SG_
	text := dc.export_dbc(ArxmlProvenance{}, d.report)
	assert text.contains(' SG_ V : 8|16@1+')
	assert text.contains(' SG_ Sig2_V : 40|8@1+')
}

fn test_cluster_variants_and_duplicate_frame_names() {
	// two CAN-CLUSTER-CONDITIONAL variants: the first is the bus, the second is reported
	two_variants := cluster_xml('Bus', 256, '/Frames/F').replace('</CAN-CLUSTER-CONDITIONAL>', '</CAN-CLUSTER-CONDITIONAL><CAN-CLUSTER-CONDITIONAL><BAUDRATE>250000</BAUDRATE><PHYSICAL-CHANNELS><CAN-PHYSICAL-CHANNEL><SHORT-NAME>Ch2</SHORT-NAME><FRAME-TRIGGERINGS><CAN-FRAME-TRIGGERING><SHORT-NAME>FT2</SHORT-NAME><FRAME-REF DEST="CAN-FRAME">/Frames/F</FRAME-REF><CAN-ADDRESSING-MODE>STANDARD</CAN-ADDRESSING-MODE><IDENTIFIER>512</IDENTIFIER></CAN-FRAME-TRIGGERING></FRAME-TRIGGERINGS></CAN-PHYSICAL-CHANNEL></PHYSICAL-CHANNELS></CAN-CLUSTER-CONDITIONAL>')
	a := parse_arxml(arxml_head + two_variants + frame_xml + arxml_tail) or { panic(err) }
	c := a.cluster('') or { panic(err) }
	assert c.baudrate == 500000
	assert c.db.messages.len == 1 // the second variant's frame is not merged in
	

	assert c.db.messages[0].id == 256
	assert a.report.notes.any(it.contains('2 CAN-CLUSTER-CONDITIONAL variants; the first is read, the other 1 are not'))

	// two frames of one SHORT-NAME in different packages, both triggered: the second gets a
	// package-qualified name, because a name is an identity downstream
	dup := cluster_xml('Bus', 256, '/Frames/F').replace('</FRAME-TRIGGERINGS>', '<CAN-FRAME-TRIGGERING><SHORT-NAME>FT2</SHORT-NAME><FRAME-REF DEST="CAN-FRAME">/Other/F</FRAME-REF><CAN-ADDRESSING-MODE>STANDARD</CAN-ADDRESSING-MODE><IDENTIFIER>512</IDENTIFIER></CAN-FRAME-TRIGGERING></FRAME-TRIGGERINGS>')
	other := frame_xml.replace('<SHORT-NAME>Frames</SHORT-NAME>', '<SHORT-NAME>Other</SHORT-NAME>')
	d := parse_arxml(arxml_head + dup + frame_xml + other + arxml_tail) or { panic(err) }
	dc := d.cluster('') or { panic(err) }
	assert dc.db.messages.map(it.name) == ['F', 'Other_F']
	assert dc.db.messages[1].id == 512
	assert d.report.notes.any(it.contains('frame name F is already used by another id in this cluster; this one is Other_F'))
}

fn test_sub_millisecond_timing_is_said_never_zeroed() {
	fast := offset_pdu_xml.replace('<LENGTH>4</LENGTH>\n<I-SIGNAL-TO-PDU-MAPPINGS>', '<LENGTH>4</LENGTH><I-PDU-TIMING-SPECIFICATIONS><I-PDU-TIMING><MINIMUM-DELAY>0.0025</MINIMUM-DELAY><TRANSMISSION-MODE-DECLARATION><TRANSMISSION-MODE-TRUE-TIMING><CYCLIC-TIMING><TIME-PERIOD><VALUE>0.0002</VALUE></TIME-PERIOD></CYCLIC-TIMING></TRANSMISSION-MODE-TRUE-TIMING></TRANSMISSION-MODE-DECLARATION></I-PDU-TIMING></I-PDU-TIMING-SPECIFICATIONS>\n<I-SIGNAL-TO-PDU-MAPPINGS>')
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + fast + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	f := c.frame_of(c.db.messages[0]) or { panic('no frame') }
	// 200 µs is not 0 ms (that would make the frame event-driven): 1 ms, and a note
	assert f.tx_mode == 'cyclic'
	assert f.cycle_ms == 1
	assert c.db.messages[0].cycle_ms == 1
	assert a.report.notes.any(it.contains('TIME-PERIOD 0.0002 s is below a millisecond; read as 1 ms'))
	// 2.5 ms rounds, and says so
	assert f.min_delay_ms == 3
	assert a.report.notes.any(it.contains('MINIMUM-DELAY 0.0025 s is not a whole millisecond; read as 3 ms'))
}

fn test_fixed_header_profile_is_named_not_approximated() {
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + e2e_xml('PROFILE_05', '<OFFSET>0</OFFSET>') + arxml_tail) or { panic(err) }
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	e := (c.frame_of(m) or { panic('no frame info') }).e2e or { panic('unprotected') }
	assert !e.has_crc_counter
	assert e.profile == 'PROFILE_05'
	// nothing invents a CRC signal, the attributes stay out, the fragment says why
	assert c.e2e_signals(m) == none
	assert !c.export_dbc(ArxmlProvenance{}, a.report).contains('E2E')
	assert c.frame_toml('').contains('# E2E PROFILE_05 (data_id 0x7, header at bit 8): a fixed-header profile')
	assert a.report.notes.any(it.contains('PROFILE_05 declares no CRC-OFFSET/COUNTER-OFFSET'))
}

fn secoc_xml(fresh_tx int) string {
	return '<AR-PACKAGE><SHORT-NAME>Frames</SHORT-NAME><ELEMENTS><CAN-FRAME><SHORT-NAME>F</SHORT-NAME>\n<FRAME-LENGTH>8</FRAME-LENGTH><PDU-TO-FRAME-MAPPINGS><PDU-TO-FRAME-MAPPING><SHORT-NAME>M</SHORT-NAME>\n<PDU-REF DEST="SECURED-I-PDU">/PDUs/Sec</PDU-REF><START-POSITION>0</START-POSITION>\n</PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS></CAN-FRAME></ELEMENTS></AR-PACKAGE>\n<AR-PACKAGE><SHORT-NAME>PDUs</SHORT-NAME><ELEMENTS>\n<SECURED-I-PDU><SHORT-NAME>Sec</SHORT-NAME><LENGTH>8</LENGTH><PAYLOAD-REF DEST="PDU-TRIGGERING">/PDUs/T</PAYLOAD-REF>\n<SECURE-COMMUNICATION-PROPS><AUTH-INFO-TX-LENGTH>28</AUTH-INFO-TX-LENGTH><DATA-ID>9</DATA-ID>\n<FRESHNESS-VALUE-LENGTH>64</FRESHNESS-VALUE-LENGTH><FRESHNESS-VALUE-TX-LENGTH>${fresh_tx}</FRESHNESS-VALUE-TX-LENGTH>\n</SECURE-COMMUNICATION-PROPS></SECURED-I-PDU>\n<PDU-TRIGGERING><SHORT-NAME>T</SHORT-NAME><I-PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</I-PDU-REF></PDU-TRIGGERING>\n<I-SIGNAL-I-PDU><SHORT-NAME>P</SHORT-NAME><LENGTH>4</LENGTH></I-SIGNAL-I-PDU>\n</ELEMENTS></AR-PACKAGE>'
}

// a SECURED-I-PDU with no PAYLOAD-REF is said: its signals, timing and layout all live behind
// that reference, and the frame was published as an empty message with no word why (round 41)
fn test_secured_pdu_without_payload_ref_is_said() {
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + secoc_xml(8).replace('<PAYLOAD-REF DEST="PDU-TRIGGERING">/PDUs/T</PAYLOAD-REF>', '') + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	assert c.db.messages[0].signals.len == 0
	assert a.report.notes.any(it.contains('/PDUs/Sec: SECURED-I-PDU without a PAYLOAD-REF; its authentic PDU cannot be found, no signals'))
}

fn test_secoc_with_a_freshness_that_is_not_byte_aligned() {
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + secoc_xml(4) + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	s := (c.frame_of(m) or { panic('no frame info') }).secoc or { panic('no secoc') }
	assert s.fresh_bit == 32
	assert s.mac_bit == 36
	assert !s.byte_aligned
	assert a.report.notes.any(it.contains('a 4-bit freshness puts the MAC at bit 36'))
	// the fragment refuses to give byte positions it cannot stand behind
	assert c.frame_toml('').contains('# SecOC (data_id 0x9): a 4-bit freshness and a 28-bit MAC at bit 36')
	assert !c.frame_toml('').contains('mac_pos')
	// a byte-aligned freshness with a 28-bit MAC is no better: mac_len = 4 would describe a
	// 32-bit MAC
	b := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + secoc_xml(8) + arxml_tail) or {
		panic(err)
	}
	bc := b.cluster('') or { panic(err) }
	assert !bc.frame_toml('').contains('mac_pos')
	assert b.report.notes.any(it.contains('a 28-bit MAC does not fill whole bytes'))
	// whole bytes on both: stated, and FRAME-relative when the secured PDU is offset
	w := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + secoc_xml(8).replace('<AUTH-INFO-TX-LENGTH>28<', '<AUTH-INFO-TX-LENGTH>24<').replace('<START-POSITION>0<', '<START-POSITION>8<') + arxml_tail) or { panic(err) }
	wc := w.cluster('') or { panic(err) }
	ws := (wc.frame_of(wc.db.messages[0]) or { panic('no frame') }).secoc or { panic('no secoc') }
	assert ws.pdu_offset == 8
	assert ws.fresh_byte == 5
	assert ws.mac_byte == 6
	assert ws.mac_len == 3
	assert wc.frame_toml('').contains('fresh_pos = 5, mac_pos = 6, mac_len = 3')
	// freshness taken from the payload (AUTH-DATA-FRESHNESS): the trailing layout this model
	// assumes is not the one on the wire, so no byte positions
	pf := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + secoc_xml(8).replace('<AUTH-INFO-TX-LENGTH>28<', '<AUTH-INFO-TX-LENGTH>24<').replace('<DATA-ID>9</DATA-ID>', '<AUTH-DATA-FRESHNESS-START-POSITION>0</AUTH-DATA-FRESHNESS-START-POSITION><AUTH-DATA-FRESHNESS-LENGTH>8</AUTH-DATA-FRESHNESS-LENGTH><DATA-ID>9</DATA-ID>') + arxml_tail) or { panic(err) }
	pfc := pf.cluster('') or { panic(err) }
	assert !((pfc.frame_of(pfc.db.messages[0]) or { panic('no frame') }).secoc or { panic('no secoc') }).byte_aligned
	assert !pfc.frame_toml('').contains('mac_pos')
	// the PAYLOAD-REF chain is followed once, so a dangling one is reported once
	d := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + secoc_xml(8).replace('/PDUs/T<', '/PDUs/Missing<') + arxml_tail) or { panic(err) }
	assert d.report.unresolved.len == 1
}

fn test_alternating_data_ids_are_named_not_collapsed() {
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>16</CRC-OFFSET><DATA-ID-MODE>ALTERNATING-8-BIT</DATA-ID-MODE>').replace('<DATA-ID>7</DATA-ID>', '<DATA-ID>7</DATA-ID><DATA-ID>9</DATA-ID>') + arxml_tail) or { panic(err) }
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	e := (c.frame_of(m) or { panic('no frame') }).e2e or { panic('unprotected') }
	assert e.data_ids == [u32(7), 9]
	assert !e.single_data_id()
	assert c.e2e_signals(m) == none
	assert !c.export_dbc(ArxmlProvenance{}, a.report).contains('E2EDataId')
	// and the load report says so, since a DBC-only consumer never sees the fragment (round 26)
	assert a.report.notes.any(it.contains('F: the DBC export carries NO E2E attributes for it — its data-id mode ALTERNATING-8-BIT is not expressible there')), a.report.notes.str()
	// a DATA-ID or an offset that is not an integer makes the contract untrustworthy: refused
	// and said, never exported with the 0 the lenient parser read (round 39)
	for bad in [['<DATA-ID>7</DATA-ID>', '<DATA-ID>invalid</DATA-ID>', 'DATA-ID "invalid" is not an integer'],
		['<CRC-OFFSET>16</CRC-OFFSET>', '<CRC-OFFSET>x</CRC-OFFSET>', 'CRC-OFFSET "x" is not an integer'],
		['<COUNTER-OFFSET>24</COUNTER-OFFSET>', '<COUNTER-OFFSET>-8</COUNTER-OFFSET>', 'COUNTER-OFFSET -8 is outside 0..512']] {
		mb := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>16</CRC-OFFSET>').replace(bad[0], bad[1]) + arxml_tail) or {
			panic(err)
		}
		mc := mb.cluster('') or { panic(err) }
		assert mc.e2e_signals(mc.db.messages[0]) == none, bad[1]
		assert mb.report.notes.any(it.contains('carries NO E2E attributes for it — its ' + bad[2])), mb.report.notes.str()
	}
	// an overflowing DATA-ID is malformed too, not the id 0 (round 40)
	ovid := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>16</CRC-OFFSET>').replace('<DATA-ID>7</DATA-ID>', '<DATA-ID>0x10000000000000000</DATA-ID>') + arxml_tail) or {
		panic(err)
	}
	ovc := ovid.cluster('') or { panic(err) }
	assert ovc.e2e_signals(ovc.db.messages[0]) == none
	assert ovid.report.notes.any(it.contains('its DATA-ID 0x10000000000000000 is outside 0..4294967295')), ovid.report.notes.str()
	// a protection with no DATA-ID is not exported as id 0 (round 38)
	no_id := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>16</CRC-OFFSET>').replace('<DATA-IDS><DATA-ID>7</DATA-ID></DATA-IDS>', '<DATA-IDS></DATA-IDS>') + arxml_tail) or {
		panic(err)
	}
	nc := no_id.cluster('') or { panic(err) }
	assert nc.e2e_signals(nc.db.messages[0]) == none
	assert no_id.report.notes.any(it.contains('F: the DBC export carries NO E2E attributes for it — it declares no DATA-ID')), no_id.report.notes.str()
	// and by the same predicate the export refuses with, so a layout refusal is said too: a CRC
	// offset inside an application signal (round 27)
	inside := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>0</CRC-OFFSET>') + arxml_tail) or {
		panic(err)
	}
	ic := inside.cluster('') or { panic(err) }
	assert ic.e2e_signals(ic.db.messages[0]) == none
	assert inside.report.notes.any(it.contains('F: the DBC export carries NO E2E attributes for it — the signals at its CRC and counter offsets are not the byte-aligned')), inside.report.notes.str()
	assert c.frame_toml('').contains('# E2E PROFILE_01 with ALTERNATING-8-BIT data ids (0x7, 0x9): this data-id mode is not expressible here')
	// LOWER-12-BIT feeds part of the id into the CRC: one scalar cannot say that either
	l := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>16</CRC-OFFSET><DATA-ID-MODE>LOWER-12-BIT</DATA-ID-MODE>') + arxml_tail) or { panic(err) }
	lc := l.cluster('') or { panic(err) }
	assert lc.e2e_signals(lc.db.messages[0]) == none
	assert lc.frame_toml('').contains('with LOWER-12-BIT data ids (0x7): this data-id mode')
}

fn test_e2e_export_needs_the_field_signals_and_a_known_checksum() {
	// the CRC offset inside a 16-bit application signal is not a CRC signal
	inside := offset_pdu_xml.replace('<START-POSITION>16</START-POSITION>', '<START-POSITION>48</START-POSITION>').replace('<START-POSITION>24</START-POSITION>', '<START-POSITION>56</START-POSITION>').replace('<SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH>', '<SHORT-NAME>V</SHORT-NAME><LENGTH>32</LENGTH>')
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + inside + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>16</CRC-OFFSET>') + arxml_tail) or { panic(err) }
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	assert m.signal_at(24) == 0 // V covers bit 24 …
	

	assert c.e2e_signals(m) == none // … but is not the CRC
	

	assert !c.export_dbc(ArxmlProvenance{}, a.report).contains('E2ECrcSignal" BO_')
	// and the fragment follows the same verdict: no e2e entry, a comment saying why
	assert !c.frame_toml('').contains('\ne2e  =')
	assert c.frame_toml('').contains('# E2E PROFILE_01 (data_id 0x7, CRC at byte 3, counter at byte 4): not exported')
	// a profile whose checksum this app cannot compute exports no contract either, even with
	// the fields in place
	p := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + e2e_xml('PROFILE_07', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>16</CRC-OFFSET>') + arxml_tail) or { panic(err) }
	pc := p.cluster('') or { panic(err) }
	assert pc.e2e_signals(pc.db.messages[0]) == none
	assert !pc.export_dbc(ArxmlProvenance{}, p.report).contains('E2EProfile')
	assert !pc.frame_toml('').contains('\ne2e  =')
}

fn test_ones_complement_and_sign_magnitude_are_said() {
	enc := offset_pdu_xml.replace('<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL>', '<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH><NETWORK-REPRESENTATION-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><BASE-TYPE-REF DEST="SW-BASE-TYPE">/BT/s8</BASE-TYPE-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></NETWORK-REPRESENTATION-PROPS></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>BT</SHORT-NAME><ELEMENTS><SW-BASE-TYPE><SHORT-NAME>s8</SHORT-NAME><BASE-TYPE-ENCODING>1C</BASE-TYPE-ENCODING></SW-BASE-TYPE></ELEMENTS></AR-PACKAGE>'
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + enc + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	assert sig(c.db.messages[0], 'Crc').is_signed
	assert a.report.notes.any(it.contains('1C encoding is not modelled'))
}

fn test_messages_from_counts_additional_transmitters() {
	// ECU_B and ECU_C both OUT on one frame: the second is an additional transmitter, and
	// must still get the frame from messages_from, or it simulates nothing
	two := cluster_xml('Bus', 256, '/Frames/F').replace('<FRAME-REF DEST="CAN-FRAME">', '<FRAME-PORT-REFS><FRAME-PORT-REF DEST="FRAME-PORT">/ECUs/ECU_B/Conn/Out</FRAME-PORT-REF><FRAME-PORT-REF DEST="FRAME-PORT">/ECUs/ECU_C/Conn/Out</FRAME-PORT-REF></FRAME-PORT-REFS><FRAME-REF DEST="CAN-FRAME">') + '<AR-PACKAGE><SHORT-NAME>ECUs</SHORT-NAME><ELEMENTS>' + '<ECU-INSTANCE><SHORT-NAME>ECU_B</SHORT-NAME><CONNECTORS><CAN-COMMUNICATION-CONNECTOR><SHORT-NAME>Conn</SHORT-NAME><ECU-COMM-PORT-INSTANCES><FRAME-PORT><SHORT-NAME>Out</SHORT-NAME><COMMUNICATION-DIRECTION>OUT</COMMUNICATION-DIRECTION></FRAME-PORT></ECU-COMM-PORT-INSTANCES></CAN-COMMUNICATION-CONNECTOR></CONNECTORS></ECU-INSTANCE>' + '<ECU-INSTANCE><SHORT-NAME>ECU_C</SHORT-NAME><CONNECTORS><CAN-COMMUNICATION-CONNECTOR><SHORT-NAME>Conn</SHORT-NAME><ECU-COMM-PORT-INSTANCES><FRAME-PORT><SHORT-NAME>Out</SHORT-NAME><COMMUNICATION-DIRECTION>OUT</COMMUNICATION-DIRECTION></FRAME-PORT></ECU-COMM-PORT-INSTANCES></CAN-COMMUNICATION-CONNECTOR></CONNECTORS></ECU-INSTANCE>' + '</ELEMENTS></AR-PACKAGE>'
	a := parse_arxml(arxml_head + two + frame_xml + arxml_tail) or { panic(err) }
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	assert m.sender == 'ECU_B'
	assert m.tx_nodes == ['ECU_C']
	assert c.db.messages_from('ECU_B').len == 1
	assert c.db.messages_from('ECU_C').len == 1
	assert c.db.messages_from('ECU_A').len == 0
}

fn test_duplicate_cluster_short_names_need_the_path() {
	// two packages, one SHORT-NAME: legal AUTOSAR, and the name alone must not pick one
	dup := cluster_xml('Body', 1, '/Frames/F') + cluster_xml('Body', 2, '/Frames/F').replace('<SHORT-NAME>Body</SHORT-NAME><ELEMENTS>', '<SHORT-NAME>Other</SHORT-NAME><ELEMENTS>')
	a := parse_arxml(arxml_head + dup + frame_xml + arxml_tail) or { panic(err) }
	assert a.clusters.len == 2
	assert a.clusters.map(it.path) == ['/Body/Body', '/Other/Body']
	// the bus identifier is collision-free and identifier-safe: what the export writes and
	// what --cluster takes (the path works too)
	assert a.cluster_names() == ['Body_Body', 'Other_Body']
	if _ := a.cluster('Body') {
		assert false, 'a shared short name must be refused'
	} else {
		assert err.msg().contains('"Body" names 2 CAN clusters: use Body_Body or Other_Body, or the path')
	}
	assert (a.cluster('/Other/Body') or { panic(err) }).db.messages[0].id == 2
	assert (a.cluster('Other_Body') or { panic(err) }).db.messages[0].id == 2
	assert (a.cluster('Other_Body') or { panic(err) }).frame_toml('').contains('bus  = "Other_Body"')
	// a unique short name still works, by name or by path
	one := parse_arxml(arxml_head + cluster_xml('Body', 1, '/Frames/F') + frame_xml + arxml_tail) or {
		panic(err)
	}
	assert one.cluster_names() == ['Body']
	assert (one.cluster('Body') or { panic(err) }).path == '/Body/Body'
	assert (one.cluster('Body') or { panic(err) }).bus == 'Body'
	assert (one.cluster('/Body/Body') or { panic(err) }).name == 'Body'
}

fn test_multi_pdu_frame_keeps_the_first_pdus_metadata_and_says_so() {
	two := offset_pdu_xml.replace('</PDU-TO-FRAME-MAPPINGS>', '<PDU-TO-FRAME-MAPPING><SHORT-NAME>M2</SHORT-NAME><PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P2</PDU-REF><START-POSITION>40</START-POSITION></PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS>').replace('</I-SIGNAL-I-PDU></ELEMENTS>', '</I-SIGNAL-I-PDU><I-SIGNAL-I-PDU><SHORT-NAME>P2</SHORT-NAME><LENGTH>1</LENGTH><I-PDU-TIMING-SPECIFICATIONS><I-PDU-TIMING><TRANSMISSION-MODE-DECLARATION><TRANSMISSION-MODE-TRUE-TIMING><CYCLIC-TIMING><TIME-PERIOD><VALUE>0.5</VALUE></TIME-PERIOD></CYCLIC-TIMING></TRANSMISSION-MODE-TRUE-TIMING></TRANSMISSION-MODE-DECLARATION></I-PDU-TIMING></I-PDU-TIMING-SPECIFICATIONS><I-SIGNAL-TO-PDU-MAPPINGS><I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MX</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/Sig/Ctr</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>0</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING></I-SIGNAL-TO-PDU-MAPPINGS></I-SIGNAL-I-PDU></ELEMENTS>')
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + two + e2e_xml('PROFILE_01', '<COUNTER-OFFSET>24</COUNTER-OFFSET><CRC-OFFSET>16</CRC-OFFSET>') + arxml_tail) or { panic(err) }
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	// every PDU's signals; the first PDU's timing and protection; and a note about the rest
	assert m.signals.len == 4
	assert m.signals[3].start_bit == 40
	f := c.frame_of(m) or { panic('no frame') }
	assert f.pdu == 'P'
	assert f.cycle_ms == 0
	assert f.e2e != none
	assert a.report.notes.any(it.contains('frame F maps 2 PDUs; the signals of P2 are read, its timing and protection are not'))
}

fn test_compu_method_shared_by_signals_of_two_widths() {
	// one TEXTTABLE with a 255 entry, read by an 8-bit and a 4-bit signal in that order: the
	// second must not inherit the first's masked table — and (round 16) must not fold 255 onto
	// its raw 15 either, a value the table never named: the key does not fit and is said
	shared_xml := offset_pdu_xml.replace('<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL>', '<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>').replace('<I-SIGNAL><SHORT-NAME>Ctr</SHORT-NAME><LENGTH>4</LENGTH></I-SIGNAL>', '<I-SIGNAL><SHORT-NAME>Ctr</SHORT-NAME><LENGTH>4</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>Sys</SHORT-NAME><ELEMENTS><SYSTEM-SIGNAL><SHORT-NAME>S</SHORT-NAME><PHYSICAL-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/T</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></PHYSICAL-PROPS></SYSTEM-SIGNAL></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>T</SHORT-NAME><CATEGORY>TEXTTABLE</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><LOWER-LIMIT>255</LOWER-LIMIT><UPPER-LIMIT>255</UPPER-LIMIT><COMPU-CONST><VT>Invalid</VT></COMPU-CONST></COMPU-SCALE><COMPU-SCALE><LOWER-LIMIT>1</LOWER-LIMIT><UPPER-LIMIT>1</UPPER-LIMIT><COMPU-CONST><VT>One</VT></COMPU-CONST></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>'
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + shared_xml + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	assert sig(m, 'Crc').values == {
		u64(255): 'Invalid'
		u64(1):   'One'
	}
	assert sig(m, 'Ctr').values == {
		u64(1): 'One'
	}
	assert a.report.notes.any(it.contains('/Sig/Ctr: enum key 255 ("Invalid") of /CM/T does not fit a 4-bit unsigned signal; dropped'))
}

fn test_enum_keys_above_2_pow_53_and_opaque_packing() {
	mut big := offset_pdu_xml.replace('<SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH></I-SIGNAL>', '<SHORT-NAME>V</SHORT-NAME><LENGTH>64</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>Sys</SHORT-NAME><ELEMENTS><SYSTEM-SIGNAL><SHORT-NAME>S</SHORT-NAME><PHYSICAL-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/T</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></PHYSICAL-PROPS></SYSTEM-SIGNAL></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>T</SHORT-NAME><CATEGORY>TEXTTABLE</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><LOWER-LIMIT>9007199254740993</LOWER-LIMIT><UPPER-LIMIT>9007199254740993</UPPER-LIMIT><COMPU-CONST><VT>Odd</VT></COMPU-CONST></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>'
	big = big.replace('<FRAME-LENGTH>8</FRAME-LENGTH>', '<FRAME-LENGTH>16</FRAME-LENGTH>').replace('<SHORT-NAME>P</SHORT-NAME><LENGTH>4</LENGTH>', '<SHORT-NAME>P</SHORT-NAME><LENGTH>16</LENGTH>') // a 64-bit signal needs the 16-byte CAN-FD payload fd_cluster declares
	a := parse_arxml(arxml_head + fd_cluster() + big + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	v := sig(c.db.messages[0], 'V')
	// 2^53 + 1 survives as itself: an integer literal is parsed as an integer
	assert v.values == {
		u64(9007199254740993): 'Odd'
	}
	// and the top of a 64-bit unsigned domain survives too: a non-negative key is a u64
	top := parse_arxml(arxml_head + fd_cluster() + big.replace('9007199254740993', '18446744073709551615').replace('<VT>Odd</VT>', '<VT>Max</VT>') + arxml_tail) or { panic(err) }
	tc := top.cluster('') or { panic(err) }
	assert sig(tc.db.messages[0], 'V').values == {
		u64(18446744073709551615): 'Max'
	}
	assert parse_key('-1') == u64(18446744073709551615)
	// a zero-fraction decimal spelling is the same integer, above 2^53 too
	assert parse_key('9007199254740993.0') == u64(9007199254740993)
	assert parse_key('9007199254740993.000') == u64(9007199254740993)
	assert parse_key('12.5') == 12
	// and a NEGATIVE zero-fraction spelling too: the sign must not send it through f64
	assert parse_key('-9007199254740993.0') == u64(i64(-9007199254740993))
	assert parse_key('-9007199254740993') == u64(i64(-9007199254740993))
	assert parse_i64('-9007199254740993.0') == i64(-9007199254740993)
	assert parse_i64('-12.5') == -12
	assert parse_i64('-1.0E2') == -100
	// the sign is one rule for every literal form: a negative hex key with an E in it is not a float
	assert parse_i64('-0x1E') == -30
	assert parse_key('-0x1E') == u64(i64(-30))
	assert parse_key('+5') == 5
	assert parse_i64('+5.0') == 5
	// a non-negative float spelling at the top of the u64 domain stays there (not INT64_MIN)
	assert parse_key('1.8E19') == u64(18000000000000000000)
	assert parse_key('1.8E19') != parse_key('1.9E19')
	// an integral EXPONENT spelling is the same integer too, in digits and never through f64
	assert parse_key('9.007199254740993E15') == u64(9007199254740993)
	assert parse_key('9.007199254740993e+15') == u64(9007199254740993)
	assert parse_key('9.007199254740993E015') == u64(9007199254740993) // leading zeros are digits too
	assert parse_key('9007199254740993E-00') == u64(9007199254740993)
	assert integral_decimal('1E1x') == none
	assert parse_key('-9.007199254740993E15') == u64(i64(-9007199254740993))
	assert parse_i64('-9.007199254740993E15') == i64(-9007199254740993)
	assert parse_key('12E2') == 1200
	assert parse_key('1200E-2') == 12
	assert parse_key('0.5E1') == 5
	assert integral_decimal('9.0071992547409931E15') == none // a real fraction remains: f64 territory
	assert integral_decimal('1.25E1') == none
	assert integral_decimal('1.5') == none
	assert integral_decimal('15') == none
	assert integral_decimal('0.000E-3') or { '' } == '0'
	assert integral_decimal('18446744073709551615.0') or { '' } == '18446744073709551615'
	// OPAQUE: read as little-endian (the bytes round-trip) and said
	// OPAQUE: read as little-endian (the bytes round-trip), said, and carrying NO numeric
	// metadata — the same system signal's text table is not applied to a byte array (round 20)
	o := parse_arxml(arxml_head + fd_cluster() + big.replace('<PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>0</START-POSITION>', '<PACKING-BYTE-ORDER>OPAQUE</PACKING-BYTE-ORDER><START-POSITION>0</START-POSITION>') + arxml_tail) or {
		panic(err)
	}
	ov := sig((o.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert ov.byte_order == .little_endian
	assert ov.values.len == 0 && ov.factor == 1.0 && ov.offset == 0.0
	assert o.report.notes.any(it.contains('OPAQUE packing (a byte array) read as a little-endian integer; its value is not a quantity, and no compu method, unit or constraint is applied'))
	// a bound past what a 64-bit raw key holds is dropped and said, not filed on raw zero
	over := parse_arxml(arxml_head + fd_cluster() + big.replace('9007199254740993', '18446744073709551616').replace('<VT>Odd</VT>', '<VT>Over</VT>') + arxml_tail) or {
		panic(err)
	}
	assert sig((over.cluster('') or { panic(err) }).db.messages[0], 'V').values.len == 0
	assert over.report.notes.any(it.contains('/CM/T: the bounds 18446744073709551616..18446744073709551616 of "Over" do not fit a 64-bit raw key; dropped'))
	assert key_of('18446744073709551616') == none
	assert parse_key('18446744073709551616') == 0 // the compare-only fallback, documented
	assert key_of('-9223372036854775808') or { 0 } == u64(1) << 63
	assert key_of('-9223372036854775809') == none
	assert key_of('1.8E19') or { 0 } == u64(18000000000000000000)
	assert key_of('1.85E19') == none // past 2^64
	assert key_of('1E100000000') == none // refused before a hundred million zeroes are built
	assert integral_decimal('1E21') == none && integral_decimal('1E19') or { '' } == '1' + '0'.repeat(19)
	assert integral_decimal('0.1E20') or { '' } == '1' + '0'.repeat(19) // leading zeroes are not digits
	assert key_of('0.1E20') or { 0 } == u64(10000000000000000000)
	assert integral_decimal('0.0E1') or { '' } == '0' && integral_decimal('0.05E1') == none
}

fn test_pdu_group_directions_do_not_leak_into_subgroups() {
	// an OUT group containing an IN subgroup: the subgroup's PDU is received, not sent
	groups := '<AR-PACKAGE><SHORT-NAME>PduGroups</SHORT-NAME><ELEMENTS>' + '<I-SIGNAL-I-PDU-GROUP><SHORT-NAME>Tx</SHORT-NAME><COMMUNICATION-DIRECTION>OUT</COMMUNICATION-DIRECTION><CONTAINED-I-SIGNAL-I-PDU-GROUP-REFS><CONTAINED-I-SIGNAL-I-PDU-GROUP-REF DEST="I-SIGNAL-I-PDU-GROUP">/PduGroups/Rx</CONTAINED-I-SIGNAL-I-PDU-GROUP-REF></CONTAINED-I-SIGNAL-I-PDU-GROUP-REFS></I-SIGNAL-I-PDU-GROUP>' + '<I-SIGNAL-I-PDU-GROUP><SHORT-NAME>Rx</SHORT-NAME><COMMUNICATION-DIRECTION>IN</COMMUNICATION-DIRECTION><I-SIGNAL-I-PDUS><I-SIGNAL-I-PDU-REF-CONDITIONAL><I-SIGNAL-I-PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</I-SIGNAL-I-PDU-REF></I-SIGNAL-I-PDU-REF-CONDITIONAL></I-SIGNAL-I-PDUS></I-SIGNAL-I-PDU-GROUP>' + '</ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>ECUs</SHORT-NAME><ELEMENTS><ECU-INSTANCE><SHORT-NAME>Node</SHORT-NAME><ASSOCIATED-COM-I-PDU-GROUP-REFS><ASSOCIATED-COM-I-PDU-GROUP-REF DEST="I-SIGNAL-I-PDU-GROUP">/PduGroups/Tx</ASSOCIATED-COM-I-PDU-GROUP-REF></ASSOCIATED-COM-I-PDU-GROUP-REFS></ECU-INSTANCE></ELEMENTS></AR-PACKAGE>'
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + groups + arxml_tail) or { panic(err) }
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	assert m.senders() == []
	assert (c.frame_of(m) or { panic('no frame') }).receivers == ['Node']
	assert c.db.messages_from('Node').len == 0
}

fn test_receivers_are_per_pdu_on_a_multi_pdu_frame() {
	// two PDUs in one frame, each received by a different ECU through its I-PDU group: the
	// signals carry their own PDU's receivers, the frame the union
	two := offset_pdu_xml.replace('</PDU-TO-FRAME-MAPPINGS>', '<PDU-TO-FRAME-MAPPING><SHORT-NAME>M2</SHORT-NAME><PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P2</PDU-REF><START-POSITION>40</START-POSITION></PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS>').replace('</I-SIGNAL-I-PDU></ELEMENTS>', '</I-SIGNAL-I-PDU><I-SIGNAL-I-PDU><SHORT-NAME>P2</SHORT-NAME><LENGTH>1</LENGTH><I-SIGNAL-TO-PDU-MAPPINGS><I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MX</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/Sig2/W</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>0</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING></I-SIGNAL-TO-PDU-MAPPINGS></I-SIGNAL-I-PDU></ELEMENTS>') + '<AR-PACKAGE><SHORT-NAME>Sig2</SHORT-NAME><ELEMENTS><I-SIGNAL><SHORT-NAME>W</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL></ELEMENTS></AR-PACKAGE>'
	groups := '<AR-PACKAGE><SHORT-NAME>PduGroups</SHORT-NAME><ELEMENTS>' + '<I-SIGNAL-I-PDU-GROUP><SHORT-NAME>RxP</SHORT-NAME><COMMUNICATION-DIRECTION>IN</COMMUNICATION-DIRECTION><I-SIGNAL-I-PDUS><I-SIGNAL-I-PDU-REF-CONDITIONAL><I-SIGNAL-I-PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</I-SIGNAL-I-PDU-REF></I-SIGNAL-I-PDU-REF-CONDITIONAL></I-SIGNAL-I-PDUS></I-SIGNAL-I-PDU-GROUP>' + '<I-SIGNAL-I-PDU-GROUP><SHORT-NAME>RxP2</SHORT-NAME><COMMUNICATION-DIRECTION>IN</COMMUNICATION-DIRECTION><I-SIGNAL-I-PDUS><I-SIGNAL-I-PDU-REF-CONDITIONAL><I-SIGNAL-I-PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P2</I-SIGNAL-I-PDU-REF></I-SIGNAL-I-PDU-REF-CONDITIONAL></I-SIGNAL-I-PDUS></I-SIGNAL-I-PDU-GROUP>' + '</ELEMENTS></AR-PACKAGE><AR-PACKAGE><SHORT-NAME>ECUs</SHORT-NAME><ELEMENTS>' + '<ECU-INSTANCE><SHORT-NAME>X</SHORT-NAME><ASSOCIATED-COM-I-PDU-GROUP-REFS><ASSOCIATED-COM-I-PDU-GROUP-REF DEST="I-SIGNAL-I-PDU-GROUP">/PduGroups/RxP</ASSOCIATED-COM-I-PDU-GROUP-REF></ASSOCIATED-COM-I-PDU-GROUP-REFS></ECU-INSTANCE>' + '<ECU-INSTANCE><SHORT-NAME>Y</SHORT-NAME><ASSOCIATED-COM-I-PDU-GROUP-REFS><ASSOCIATED-COM-I-PDU-GROUP-REF DEST="I-SIGNAL-I-PDU-GROUP">/PduGroups/RxP2</ASSOCIATED-COM-I-PDU-GROUP-REF></ASSOCIATED-COM-I-PDU-GROUP-REFS></ECU-INSTANCE>' + '</ELEMENTS></AR-PACKAGE>'
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + two + groups + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	m := c.db.messages[0]
	assert sig(m, 'V').receivers == ['X']
	assert sig(m, 'Crc').receivers == ['X']
	assert sig(m, 'W').receivers == ['Y']
	assert (c.frame_of(m) or { panic('no frame') }).receivers == ['X', 'Y']
	text := c.export_dbc(ArxmlProvenance{}, a.report)
	assert text.contains(' SG_ V : 8|16@1+ (1,0) [0|0] "" X')
	assert text.contains(' SG_ W : 40|8@1+ (1,0) [0|0] "" Y')
}

fn test_signal_shapes_the_model_cannot_hold_are_said() {
	// wider than 64 bits: not read, and said
	wide := offset_pdu_xml.replace('<SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH>', '<SHORT-NAME>V</SHORT-NAME><LENGTH>72</LENGTH>')
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + wide + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	assert c.db.messages[0].signals.map(it.name) == ['Crc', 'Ctr']
	assert a.report.notes.any(it.contains('72-bit signal is wider than the 64-bit scalar model; not read'))
	// two property variants: the first is read, and said
	vari := offset_pdu_xml.replace('<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL>', '<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH><NETWORK-REPRESENTATION-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><BASE-TYPE-REF DEST="SW-BASE-TYPE">/BT/s8</BASE-TYPE-REF></SW-DATA-DEF-PROPS-CONDITIONAL><SW-DATA-DEF-PROPS-CONDITIONAL><BASE-TYPE-REF DEST="SW-BASE-TYPE">/BT/u8</BASE-TYPE-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></NETWORK-REPRESENTATION-PROPS></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>BT</SHORT-NAME><ELEMENTS><SW-BASE-TYPE><SHORT-NAME>s8</SHORT-NAME><BASE-TYPE-ENCODING>2C</BASE-TYPE-ENCODING></SW-BASE-TYPE><SW-BASE-TYPE><SHORT-NAME>u8</SHORT-NAME><BASE-TYPE-ENCODING>NONE</BASE-TYPE-ENCODING></SW-BASE-TYPE></ELEMENTS></AR-PACKAGE>'
	v := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + vari + arxml_tail) or {
		panic(err)
	}
	vc := v.cluster('') or { panic(err) }
	assert sig(vc.db.messages[0], 'Crc').is_signed
	assert v.report.notes.any(it.contains('2 SW-DATA-DEF-PROPS-CONDITIONAL variants; the first is read'))
	// a numeric lookup table (COMPU-CONST/V) is not an enum: not read, and said
	tab := offset_pdu_xml.replace('<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL>', '<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>Sys</SHORT-NAME><ELEMENTS><SYSTEM-SIGNAL><SHORT-NAME>S</SHORT-NAME><PHYSICAL-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/N</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></PHYSICAL-PROPS></SYSTEM-SIGNAL></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>N</SHORT-NAME><CATEGORY>TAB_NOINTP</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><LOWER-LIMIT>0</LOWER-LIMIT><UPPER-LIMIT>0</UPPER-LIMIT><COMPU-CONST><V>10</V></COMPU-CONST></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>'
	t := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + tab + arxml_tail) or {
		panic(err)
	}
	tc := t.cluster('') or { panic(err) }
	assert sig(tc.db.messages[0], 'Crc').values.len == 0
	assert t.report.notes.any(it.contains('a numeric lookup table (COMPU-CONST/V) is not modelled'))
}

fn test_nonlinear_scales_and_negative_factors() {
	// a zero quadratic term before a nonzero cubic one is still a curve
	poly := '<AR-PACKAGE><SHORT-NAME>Sys</SHORT-NAME><ELEMENTS><SYSTEM-SIGNAL><SHORT-NAME>S</SHORT-NAME><PHYSICAL-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/L</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></PHYSICAL-PROPS></SYSTEM-SIGNAL></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>L</SHORT-NAME><CATEGORY>LINEAR</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><LOWER-LIMIT>0</LOWER-LIMIT><UPPER-LIMIT>255</UPPER-LIMIT><COMPU-RATIONAL-COEFFS><COMPU-NUMERATOR>@COEFFS@</COMPU-NUMERATOR><COMPU-DENOMINATOR><V>1</V></COMPU-DENOMINATOR></COMPU-RATIONAL-COEFFS></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>'
	sigs := offset_pdu_xml.replace('<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL>', '<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>')
	cubic := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + sigs + poly.replace('@COEFFS@', '<V>0</V><V>1</V><V>0</V><V>1</V>') + arxml_tail) or { panic(err) }
	cc := cubic.cluster('') or { panic(err) }
	assert sig(cc.db.messages[0], 'Crc').factor == 1
	assert cubic.report.notes.any(it.contains('a polynomial of degree 3'))
	// a negative factor: the physical range still reads low to high
	neg := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + sigs + poly.replace('@COEFFS@', '<V>100</V><V>-0.5</V>') + arxml_tail) or { panic(err) }
	nc := neg.cluster('') or { panic(err) }
	ns := sig(nc.db.messages[0], 'Crc')
	assert ns.factor == -0.5
	assert ns.offset == 100
	assert ns.minimum == -27.5
	assert ns.maximum == 100
	// a one-term numerator is a constant, which factor/offset cannot say (factor 0 divides by
	// zero on encode): reported, read as the identity
	konst := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + sigs + poly.replace('@COEFFS@', '<V>5</V>') + arxml_tail) or { panic(err) }
	kc := konst.cluster('') or { panic(err) }
	ks := sig(kc.db.messages[0], 'Crc')
	assert ks.factor == 1
	assert ks.offset == 0
	assert konst.report.notes.any(it.contains('a constant conversion (every raw value is 5) is not modelled'))
}

fn test_selectors_never_collide_with_a_documented_short_name() {
	// /A/Bus, /B/Bus and /C/A_Bus: the cluster whose own name is A_Bus keeps it, and the
	// shared pair get names allocated around it — selecting by a documented SHORT-NAME
	// must never load another cluster
	three := cluster_xml('Bus', 1, '/Frames/F').replace('<SHORT-NAME>Bus</SHORT-NAME><ELEMENTS>', '<SHORT-NAME>A</SHORT-NAME><ELEMENTS>') + cluster_xml('Bus', 2, '/Frames/F').replace('<SHORT-NAME>Bus</SHORT-NAME><ELEMENTS>', '<SHORT-NAME>B</SHORT-NAME><ELEMENTS>') + cluster_xml('A_Bus', 3, '/Frames/F').replace('<SHORT-NAME>A_Bus</SHORT-NAME><ELEMENTS>', '<SHORT-NAME>C</SHORT-NAME><ELEMENTS>')
	a := parse_arxml(arxml_head + three + frame_xml + arxml_tail) or { panic(err) }
	assert a.clusters.map(it.path) == ['/A/Bus', '/B/Bus', '/C/A_Bus']
	assert a.cluster_names() == ['A_Bus_2', 'B_Bus', 'A_Bus']
	assert (a.cluster('A_Bus') or { panic(err) }).path == '/C/A_Bus'
	assert (a.cluster('A_Bus_2') or { panic(err) }).path == '/A/Bus'
	assert a.report.notes.any(it.contains('/A/Bus: cluster name Bus is used by another package too; this one is A_Bus_2'))
	// the same allocation for ECUs: /A/Node, /B/Node, /C/A_Node
	ecus := '<AR-PACKAGE><SHORT-NAME>A</SHORT-NAME><ELEMENTS><ECU-INSTANCE><SHORT-NAME>Node</SHORT-NAME></ECU-INSTANCE></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>B</SHORT-NAME><ELEMENTS><ECU-INSTANCE><SHORT-NAME>Node</SHORT-NAME></ECU-INSTANCE></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>C</SHORT-NAME><ELEMENTS><ECU-INSTANCE><SHORT-NAME>A_Node</SHORT-NAME></ECU-INSTANCE></ELEMENTS></AR-PACKAGE>'
	e := parse_arxml(arxml_head + ecus + arxml_tail) or { panic(err) }
	assert e.report.notes.any(it.contains('/A/Node: ECU name Node is used by another package too; this one is A_Node_2'))
	assert e.report.notes.any(it.contains('/B/Node: ECU name Node is used by another package too; this one is B_Node'))
	assert !e.report.notes.any(it.contains('/C/A_Node'))
}

fn test_shapes_reported_rather_than_misread() {
	// a PDU packed MSB-first into its frame: the PDU's start is counted at the MSB of its
	// first byte (bit 15 for byte 1), and the bytes are not reversed — the same layout as
	// the LSB-first mapping at bit 8, which is what a real export and cantools agree on
	msb := offset_pdu_xml.replace('<PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF><START-POSITION>8</START-POSITION>', '<PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-FIRST</PACKING-BYTE-ORDER><PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF><START-POSITION>15</START-POSITION>')
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + msb + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	assert sig(c.db.messages[0], 'V').start_bit == 8
	assert sig(c.db.messages[0], 'Crc').start_bit == 24
	assert a.report.notes.len == 0
	// a start that is on neither convention's byte boundary is said, and read from its byte
	odd := offset_pdu_xml.replace_once('<START-POSITION>8</START-POSITION>', '<START-POSITION>12</START-POSITION>')
	o := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + odd + arxml_tail) or {
		panic(err)
	}
	oc := o.cluster('') or { panic(err) }
	assert sig(oc.db.messages[0], 'V').start_bit == 8
	assert o.report.notes.any(it.contains('PDU P starts at bit 12 of frame F, not on a byte; read from byte 1'))
	// an update bit: said, with its frame-relative position
	ub := offset_pdu_xml.replace('<I-SIGNAL-REF DEST="I-SIGNAL">/Sig/V</I-SIGNAL-REF>', '<I-SIGNAL-REF DEST="I-SIGNAL">/Sig/V</I-SIGNAL-REF><UPDATE-BIT-POSITION>31</UPDATE-BIT-POSITION>')
	u := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + ub + arxml_tail) or {
		panic(err)
	}
	assert u.report.notes.any(it.contains('/Sig/V: declares an update bit at bit 39; not modelled'))
}

fn test_initial_values_are_said_not_dropped() {
	v_sig := '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH></I-SIGNAL>'
	init := fn (spec string) string {
		return '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH><INIT-VALUE>${spec}</INIT-VALUE></I-SIGNAL>'
	}
	// nonzero: the simulated frame would carry a different payload than the file declares
	seven := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace(v_sig, init('<NUMERICAL-VALUE-SPECIFICATION><VALUE>7</VALUE></NUMERICAL-VALUE-SPECIFICATION>')) + arxml_tail) or {
		panic(err)
	}
	assert seven.report.notes.any(it.contains('/Sig/V: declares an initial value of 7; not modelled, the simulated ECUs start it at raw 0'))
	assert sig(seven.cluster('') or { panic(err) }.db.messages[0], 'V').length == 16
	// zero is what the frame does anyway: nothing to say
	zero := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace(v_sig, init('<NUMERICAL-VALUE-SPECIFICATION><VALUE>0.0</VALUE></NUMERICAL-VALUE-SPECIFICATION>')) + arxml_tail) or {
		panic(err)
	}
	assert !zero.report.notes.any(it.contains('initial value'))
	// every other form is said as unread, never judged by a VALUE found somewhere inside it: a
	// TEXT-VALUE's label would read as 0, an ARRAY's first element as the whole
	unread := 'declares an initial value in a form not read (not a NUMERICAL-VALUE-SPECIFICATION)'
	for form in ['<CONSTANT-REFERENCE><CONSTANT-REF DEST="CONSTANT-SPECIFICATION">/C/Init</CONSTANT-REF></CONSTANT-REFERENCE>',
		'<TEXT-VALUE-SPECIFICATION><VALUE>Off</VALUE></TEXT-VALUE-SPECIFICATION>',
		'<ARRAY-VALUE-SPECIFICATION><ELEMENTS><NUMERICAL-VALUE-SPECIFICATION><VALUE>0</VALUE></NUMERICAL-VALUE-SPECIFICATION><NUMERICAL-VALUE-SPECIFICATION><VALUE>255</VALUE></NUMERICAL-VALUE-SPECIFICATION></ELEMENTS></ARRAY-VALUE-SPECIFICATION>'] {
		other := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace(v_sig, init(form)) + arxml_tail) or {
			panic(err)
		}
		assert other.report.notes.any(it.contains('/Sig/V: ${unread}')), form
		assert !other.report.notes.any(it.contains('declares an initial value of')), form
	}
	// a signal the model does not carry gets no claim about its simulated outcome
	wide := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace(v_sig, init('<NUMERICAL-VALUE-SPECIFICATION><VALUE>7</VALUE></NUMERICAL-VALUE-SPECIFICATION>').replace('<LENGTH>16</LENGTH>', '<LENGTH>72</LENGTH>')) + arxml_tail) or {
		panic(err)
	}
	assert wide.report.notes.any(it.contains('72-bit signal is wider'))
	assert !wide.report.notes.any(it.contains('initial value'))
}

fn test_open_bounds_and_inverse_only_conversions_are_said() {
	v_sig := '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH></I-SIGNAL>'
	linked := offset_pdu_xml.replace(v_sig, '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>Sys</SHORT-NAME><ELEMENTS><SYSTEM-SIGNAL><SHORT-NAME>S</SHORT-NAME><PHYSICAL-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/Inv</COMPU-METHOD-REF><DATA-CONSTR-REF DEST="DATA-CONSTR">/DC/Open</DATA-CONSTR-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></PHYSICAL-PROPS></SYSTEM-SIGNAL></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>Inv</SHORT-NAME><CATEGORY>LINEAR</CATEGORY><COMPU-PHYS-TO-INTERNAL><COMPU-SCALES><COMPU-SCALE><COMPU-RATIONAL-COEFFS><COMPU-NUMERATOR><V>-5</V><V>0.5</V></COMPU-NUMERATOR><COMPU-DENOMINATOR><V>1</V></COMPU-DENOMINATOR></COMPU-RATIONAL-COEFFS></COMPU-SCALE></COMPU-SCALES></COMPU-PHYS-TO-INTERNAL></COMPU-METHOD></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>DC</SHORT-NAME><ELEMENTS><DATA-CONSTR><SHORT-NAME>Open</SHORT-NAME><DATA-CONSTR-RULES><DATA-CONSTR-RULE><PHYS-CONSTRS><LOWER-LIMIT INTERVAL-TYPE="OPEN">0</LOWER-LIMIT><UPPER-LIMIT INTERVAL-TYPE="INFINITE">0</UPPER-LIMIT></PHYS-CONSTRS></DATA-CONSTR-RULE></DATA-CONSTR-RULES></DATA-CONSTR></ELEMENTS></AR-PACKAGE>'
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + linked + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	v := sig(c.db.messages[0], 'V')
	// the inverse-only method is NOT applied as if it were the forward one, and is said
	assert v.factor == 1.0
	assert v.offset == 0.0
	assert a.report.notes.any(it.contains('/CM/Inv: gives only a physical-to-internal conversion'))
	// the bounds are read as closed, and each open one is said with its kind
	assert a.report.notes.any(it.contains('/Sig/V: LOWER-LIMIT 0 is OPEN; read as a closed'))
	assert a.report.notes.any(it.contains('/Sig/V: UPPER-LIMIT 0 is INFINITE; read as a closed'))
	// a description keeps its punctuation tight against inline markup
	punct := offset_pdu_xml.replace(v_sig, '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><DESC><L-2 L="EN">use <E>foo</E>, then (<TT>bar</TT>) over <E>all</E> bytes.</L-2></DESC><LENGTH>16</LENGTH></I-SIGNAL>')
	d := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + punct + arxml_tail) or {
		panic(err)
	}
	assert sig(d.cluster('') or { panic(err) }.db.messages[0], 'V').desc == 'use foo, then (bar) over all bytes.'
}

fn test_round_15_shapes_are_said_or_read_right() {
	v_sig := '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH></I-SIGNAL>'
	pdu_head := '<I-SIGNAL-I-PDU><SHORT-NAME>P</SHORT-NAME><LENGTH>4</LENGTH>'
	// fractional text-table bounds are not a singleton at the raw key they truncate to; a masked
	// bitfield table is not a value table; an unmodelled encoding is said; a nonzero unused-bit
	// pattern is said; event-only timing is said
	shapes := offset_pdu_xml.replace(v_sig, '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH><NETWORK-REPRESENTATION-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><BASE-TYPE-REF DEST="SW-BASE-TYPE">/BT/bcd</BASE-TYPE-REF><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/Frac</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></NETWORK-REPRESENTATION-PROPS></I-SIGNAL>').replace('<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL>', '<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH><NETWORK-REPRESENTATION-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/Bits</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></NETWORK-REPRESENTATION-PROPS></I-SIGNAL>').replace(pdu_head, pdu_head + '<UNUSED-BIT-PATTERN>255</UNUSED-BIT-PATTERN><I-PDU-TIMING-SPECIFICATIONS><I-PDU-TIMING><TRANSMISSION-MODE-DECLARATION><TRANSMISSION-MODE-TRUE-TIMING><EVENT-CONTROLLED-TIMING><NUMBER-OF-REPETITIONS>0</NUMBER-OF-REPETITIONS></EVENT-CONTROLLED-TIMING></TRANSMISSION-MODE-TRUE-TIMING></TRANSMISSION-MODE-DECLARATION></I-PDU-TIMING></I-PDU-TIMING-SPECIFICATIONS>') + '<AR-PACKAGE><SHORT-NAME>BT</SHORT-NAME><ELEMENTS><SW-BASE-TYPE><SHORT-NAME>bcd</SHORT-NAME><BASE-TYPE-ENCODING>BCD-P</BASE-TYPE-ENCODING></SW-BASE-TYPE></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>Frac</SHORT-NAME><CATEGORY>TEXTTABLE</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><LOWER-LIMIT>1.1</LOWER-LIMIT><UPPER-LIMIT>1.9</UPPER-LIMIT><COMPU-CONST><VT>Between</VT></COMPU-CONST></COMPU-SCALE><COMPU-SCALE><LOWER-LIMIT>2</LOWER-LIMIT><UPPER-LIMIT>2.0</UPPER-LIMIT><COMPU-CONST><VT>Two</VT></COMPU-CONST></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD><COMPU-METHOD><SHORT-NAME>Bits</SHORT-NAME><CATEGORY>BITFIELD_TEXTTABLE</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><MASK>1</MASK><LOWER-LIMIT>1</LOWER-LIMIT><UPPER-LIMIT>1</UPPER-LIMIT><COMPU-CONST><VT>Bit0</VT></COMPU-CONST></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>'
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + shapes + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	v := sig(c.db.messages[0], 'V')
	assert v.values == {
		u64(2): 'Two'
	}
	assert a.report.notes.any(it.contains('/CM/Frac: maps the range 1.1..1.9 to "Between"'))
	assert sig(c.db.messages[0], 'Crc').values.len == 0
	assert a.report.notes.any(it.contains('/CM/Bits: a masked bitfield text table'))
	assert a.report.notes.any(it.contains('/Sig/V: BASE-TYPE-ENCODING BCD-P is not modelled'))
	assert a.report.notes.any(it.contains('/PDUs/P: UNUSED-BIT-PATTERN 255 is not modelled'))
	assert a.report.notes.any(it.contains('/PDUs/P: event-controlled timing only, no cyclic timing'))
	assert integral_literal('0x1E') && integral_literal('-7') && integral_literal('2.0') && integral_literal('1E2')
	assert !integral_literal('1.1') && !integral_literal('') && !integral_literal('0x')
	assert !integral_literal('0xZZ') && !integral_literal('0x1G') && integral_literal('0xfF') // round 38
	assert !integral_literal('+-256') && !integral_literal('--1') && integral_literal('+256') // round 41
	// endpoints declared through I-PDU ports alone (no frame ports) still give the frame a
	// sender and a receiver
	ft_pdus := '<IDENTIFIER>256</IDENTIFIER><PDU-TRIGGERINGS><PDU-TRIGGERING-REF-CONDITIONAL><PDU-TRIGGERING-REF DEST="PDU-TRIGGERING">/Bus/Bus/Ch/PT</PDU-TRIGGERING-REF></PDU-TRIGGERING-REF-CONDITIONAL></PDU-TRIGGERINGS></CAN-FRAME-TRIGGERING>'
	ch_pdus := '</FRAME-TRIGGERINGS><PDU-TRIGGERINGS><PDU-TRIGGERING><SHORT-NAME>PT</SHORT-NAME><I-PDU-PORT-REFS><I-PDU-PORT-REF DEST="I-PDU-PORT">/ECUs/E/Conn/P_Out</I-PDU-PORT-REF><I-PDU-PORT-REF DEST="I-PDU-PORT">/ECUs/R/Conn/P_In</I-PDU-PORT-REF></I-PDU-PORT-REFS><I-PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</I-PDU-REF></PDU-TRIGGERING></PDU-TRIGGERINGS></CAN-PHYSICAL-CHANNEL>'
	ecus := '<AR-PACKAGE><SHORT-NAME>ECUs</SHORT-NAME><ELEMENTS><ECU-INSTANCE><SHORT-NAME>E</SHORT-NAME><CONNECTORS><CAN-COMMUNICATION-CONNECTOR><SHORT-NAME>Conn</SHORT-NAME><ECU-COMM-PORT-INSTANCES><I-PDU-PORT><SHORT-NAME>P_Out</SHORT-NAME><COMMUNICATION-DIRECTION>OUT</COMMUNICATION-DIRECTION></I-PDU-PORT></ECU-COMM-PORT-INSTANCES></CAN-COMMUNICATION-CONNECTOR></CONNECTORS></ECU-INSTANCE><ECU-INSTANCE><SHORT-NAME>R</SHORT-NAME><CONNECTORS><CAN-COMMUNICATION-CONNECTOR><SHORT-NAME>Conn</SHORT-NAME><ECU-COMM-PORT-INSTANCES><I-PDU-PORT><SHORT-NAME>P_In</SHORT-NAME><COMMUNICATION-DIRECTION>IN</COMMUNICATION-DIRECTION></I-PDU-PORT></ECU-COMM-PORT-INSTANCES></CAN-COMMUNICATION-CONNECTOR></CONNECTORS></ECU-INSTANCE></ELEMENTS></AR-PACKAGE>'
	cl := cluster_xml('Bus', 256, '/Frames/F').replace('<IDENTIFIER>256</IDENTIFIER></CAN-FRAME-TRIGGERING>', ft_pdus).replace('</FRAME-TRIGGERINGS></CAN-PHYSICAL-CHANNEL>', ch_pdus)
	e := parse_arxml(arxml_head + cl + offset_pdu_xml + ecus + arxml_tail) or { panic(err) }
	ec := e.cluster('') or { panic(err) }
	assert ec.db.messages[0].sender == 'E', ec.db.messages[0].sender
	assert 'R' in sig(ec.db.messages[0], 'V').receivers
	assert 'E' in ec.db.nodes && 'R' in ec.db.nodes
	// an ECU that bears the DBC placeholder name is renamed, or senders() would normalise it
	// away and it would simulate nothing (round 27)
	ph := parse_arxml(arxml_head + cl.replace('/ECUs/E/Conn/P_Out', '/ECUs/Vector__XXX/Conn/P_Out') + offset_pdu_xml + ecus.replace('<SHORT-NAME>E</SHORT-NAME>', '<SHORT-NAME>Vector__XXX</SHORT-NAME>') + arxml_tail) or {
		panic(err)
	}
	phc := ph.cluster('') or { panic(err) }
	assert phc.db.messages[0].sender == 'ECUs_Vector__XXX', phc.db.messages[0].sender
	assert phc.db.messages[0].senders() == ['ECUs_Vector__XXX']
	assert ph.report.notes.any(it.contains('/ECUs/Vector__XXX: ECU name Vector__XXX is the DBC placeholder'))
	// and an IN port listens to ITS PDU only: on a frame mapping P and Q, Q's receiver is not a
	// receiver of P's signals (round 16)
	two := offset_pdu_xml.replace('</PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS>', '</PDU-TO-FRAME-MAPPING><PDU-TO-FRAME-MAPPING><SHORT-NAME>MQ</SHORT-NAME><PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/Q</PDU-REF><START-POSITION>48</START-POSITION></PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS>').replace('</I-SIGNAL-I-PDU>', '</I-SIGNAL-I-PDU><I-SIGNAL-I-PDU><SHORT-NAME>Q</SHORT-NAME><LENGTH>2</LENGTH><I-SIGNAL-TO-PDU-MAPPINGS><I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MW</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/Sig/W</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>0</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING></I-SIGNAL-TO-PDU-MAPPINGS></I-SIGNAL-I-PDU>').replace(v_sig, v_sig + '<I-SIGNAL><SHORT-NAME>W</SHORT-NAME><LENGTH>16</LENGTH></I-SIGNAL>')
	ch_two := ch_pdus.replace('</PDU-TRIGGERING></PDU-TRIGGERINGS>', '</PDU-TRIGGERING><PDU-TRIGGERING><SHORT-NAME>PTQ</SHORT-NAME><I-PDU-PORT-REFS><I-PDU-PORT-REF DEST="I-PDU-PORT">/ECUs/S/Conn/Q_In</I-PDU-PORT-REF></I-PDU-PORT-REFS><I-PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/Q</I-PDU-REF></PDU-TRIGGERING></PDU-TRIGGERINGS>')
	ft_two := ft_pdus.replace('</PDU-TRIGGERING-REF-CONDITIONAL></PDU-TRIGGERINGS>', '</PDU-TRIGGERING-REF-CONDITIONAL><PDU-TRIGGERING-REF-CONDITIONAL><PDU-TRIGGERING-REF DEST="PDU-TRIGGERING">/Bus/Bus/Ch/PTQ</PDU-TRIGGERING-REF></PDU-TRIGGERING-REF-CONDITIONAL></PDU-TRIGGERINGS>')
	ecus_s := ecus.replace('</ECU-INSTANCE></ELEMENTS>', '</ECU-INSTANCE><ECU-INSTANCE><SHORT-NAME>S</SHORT-NAME><CONNECTORS><CAN-COMMUNICATION-CONNECTOR><SHORT-NAME>Conn</SHORT-NAME><ECU-COMM-PORT-INSTANCES><I-PDU-PORT><SHORT-NAME>Q_In</SHORT-NAME><COMMUNICATION-DIRECTION>IN</COMMUNICATION-DIRECTION></I-PDU-PORT></ECU-COMM-PORT-INSTANCES></CAN-COMMUNICATION-CONNECTOR></CONNECTORS></ECU-INSTANCE></ELEMENTS>')
	cl2 := cluster_xml('Bus', 256, '/Frames/F').replace('<IDENTIFIER>256</IDENTIFIER></CAN-FRAME-TRIGGERING>', ft_two).replace('</FRAME-TRIGGERINGS></CAN-PHYSICAL-CHANNEL>', ch_two)
	e2 := parse_arxml(arxml_head + cl2 + two + ecus_s + arxml_tail) or { panic(err) }
	m2 := (e2.cluster('') or { panic(err) }).db.messages[0]
	assert m2.sender == 'E'
	assert 'R' in sig(m2, 'V').receivers && 'S' !in sig(m2, 'V').receivers, sig(m2, 'V').receivers.str()
	assert 'S' in sig(m2, 'W').receivers && 'R' !in sig(m2, 'W').receivers, sig(m2, 'W').receivers.str()
	// an enum key the signal's width cannot hold is dropped and said, not aliased onto a value
	// the table never named
	wide_keys := offset_pdu_xml.replace(v_sig, '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>8</LENGTH><NETWORK-REPRESENTATION-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/K</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></NETWORK-REPRESENTATION-PROPS></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>K</SHORT-NAME><CATEGORY>TEXTTABLE</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><LOWER-LIMIT>0</LOWER-LIMIT><UPPER-LIMIT>0</UPPER-LIMIT><COMPU-CONST><VT>Zero</VT></COMPU-CONST></COMPU-SCALE><COMPU-SCALE><LOWER-LIMIT>256</LOWER-LIMIT><UPPER-LIMIT>256</UPPER-LIMIT><COMPU-CONST><VT>TooWide</VT></COMPU-CONST></COMPU-SCALE><COMPU-SCALE><LOWER-LIMIT>-1</LOWER-LIMIT><UPPER-LIMIT>-1</UPPER-LIMIT><COMPU-CONST><VT>Neg</VT></COMPU-CONST></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>'
	k := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + wide_keys + arxml_tail) or {
		panic(err)
	}
	kv := sig((k.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert kv.values == {
		u64(0): 'Zero'
	}, kv.values.str()
	assert k.report.notes.any(it.contains('/Sig/V: enum key 256 ("TooWide") of /CM/K does not fit a 8-bit unsigned signal; dropped'))
	assert k.report.notes.any(it.contains('enum key -1 ("Neg") of /CM/K does not fit a 8-bit unsigned')), k.report.notes.str()
	// the export's field predicate takes the field in either byte order, within its byte
	assert is_e2e_field(Signal{ start_bit: 48, length: 8 }, 48, 8)
	assert is_e2e_field(Signal{ start_bit: 55, length: 8, byte_order: .big_endian }, 48, 8)
	assert is_e2e_field(Signal{ start_bit: 51, length: 4, byte_order: .big_endian }, 48, 4)
	assert !is_e2e_field(Signal{ start_bit: 48, length: 8, byte_order: .big_endian }, 48, 8)
	assert !is_e2e_field(Signal{ start_bit: 48, length: 16 }, 48, 8)
	assert !is_e2e_field(Signal{ start_bit: 20, length: 8 }, 20, 8)
	// and for a SIGNED 8-bit signal: -1 fits (0xFF), 200 does not (0xC8 decodes as -56), 100 does
	signed_keys := wide_keys.replace('<LENGTH>8</LENGTH><NETWORK-REPRESENTATION-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL>', '<LENGTH>8</LENGTH><NETWORK-REPRESENTATION-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><BASE-TYPE-REF DEST="SW-BASE-TYPE">/BT/s8</BASE-TYPE-REF>').replace('<LOWER-LIMIT>256</LOWER-LIMIT><UPPER-LIMIT>256</UPPER-LIMIT><COMPU-CONST><VT>TooWide</VT>', '<LOWER-LIMIT>200</LOWER-LIMIT><UPPER-LIMIT>200</UPPER-LIMIT><COMPU-CONST><VT>TooWide</VT></COMPU-CONST></COMPU-SCALE><COMPU-SCALE><LOWER-LIMIT>100</LOWER-LIMIT><UPPER-LIMIT>100</UPPER-LIMIT><COMPU-CONST><VT>Hundred</VT>') + '<AR-PACKAGE><SHORT-NAME>BT</SHORT-NAME><ELEMENTS><SW-BASE-TYPE><SHORT-NAME>s8</SHORT-NAME><BASE-TYPE-ENCODING>2C</BASE-TYPE-ENCODING></SW-BASE-TYPE></ELEMENTS></AR-PACKAGE>'
	sk := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + signed_keys + arxml_tail) or {
		panic(err)
	}
	skv := sig((sk.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert skv.is_signed
	assert skv.values == {
		u64(0):   'Zero'
		u64(100): 'Hundred'
		u64(255): 'Neg'
	}, skv.values.str()
	assert sk.report.notes.any(it.contains('/Sig/V: enum key 200 ("TooWide") of /CM/K does not fit a 8-bit signed signal; dropped'))
	// a negative key below the signed minimum whose PATTERN still sign-extends into the width
	// (-257 for 8 bits) is dropped, not filed on raw -1 (round 34)
	wrapped := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + signed_keys.replace('<LOWER-LIMIT>-1</LOWER-LIMIT><UPPER-LIMIT>-1</UPPER-LIMIT>', '<LOWER-LIMIT>-257</LOWER-LIMIT><UPPER-LIMIT>-257</UPPER-LIMIT>') + arxml_tail) or {
		panic(err)
	}
	wv := sig((wrapped.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert u64(255) !in wv.values, wv.values.str()
	assert wrapped.report.notes.any(it.contains('/Sig/V: enum key -257 ("Neg") of /CM/K does not fit a 8-bit signed signal; dropped'))
	// -1 and 2^64-1 are one u64 pattern; a method shared by a signed and an unsigned 64-bit signal
	// keeps them apart, and each signal takes the one its domain holds (round 21)
	mut both := offset_pdu_xml.replace('<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL>', '<I-SIGNAL><SHORT-NAME>Crc</SHORT-NAME><LENGTH>64</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>').replace('<I-SIGNAL><SHORT-NAME>Ctr</SHORT-NAME><LENGTH>4</LENGTH></I-SIGNAL>', '<I-SIGNAL><SHORT-NAME>Ctr</SHORT-NAME><LENGTH>64</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF><NETWORK-REPRESENTATION-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><BASE-TYPE-REF DEST="SW-BASE-TYPE">/BT/s8</BASE-TYPE-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></NETWORK-REPRESENTATION-PROPS></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>Sys</SHORT-NAME><ELEMENTS><SYSTEM-SIGNAL><SHORT-NAME>S</SHORT-NAME><PHYSICAL-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/B</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></PHYSICAL-PROPS></SYSTEM-SIGNAL></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>BT</SHORT-NAME><ELEMENTS><SW-BASE-TYPE><SHORT-NAME>s8</SHORT-NAME><BASE-TYPE-ENCODING>2C</BASE-TYPE-ENCODING></SW-BASE-TYPE></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>B</SHORT-NAME><CATEGORY>TEXTTABLE</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><LOWER-LIMIT>-1</LOWER-LIMIT><UPPER-LIMIT>-1</UPPER-LIMIT><COMPU-CONST><VT>Neg</VT></COMPU-CONST></COMPU-SCALE><COMPU-SCALE><LOWER-LIMIT>18446744073709551615</LOWER-LIMIT><UPPER-LIMIT>18446744073709551615</UPPER-LIMIT><COMPU-CONST><VT>Max</VT></COMPU-CONST></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>'
	both = both.replace('<FRAME-LENGTH>8</FRAME-LENGTH>', '<FRAME-LENGTH>16</FRAME-LENGTH>').replace('<SHORT-NAME>P</SHORT-NAME><LENGTH>4</LENGTH>', '<SHORT-NAME>P</SHORT-NAME><LENGTH>16</LENGTH>') // a 64-bit signal needs the 16-byte CAN-FD payload fd_cluster declares
	bo := parse_arxml(arxml_head + fd_cluster() + both + arxml_tail) or {
		panic(err)
	}
	bm := (bo.cluster('') or { panic(err) }).db.messages[0]
	assert sig(bm, 'Crc').values == {
		u64(18446744073709551615): 'Max'
	}, sig(bm, 'Crc').values.str()
	assert sig(bm, 'Ctr').values == {
		u64(18446744073709551615): 'Neg'
	}, sig(bm, 'Ctr').values.str()
	assert bo.report.notes.any(it.contains('/Sig/Crc: enum key -1 ("Neg") of /CM/B does not fit a 64-bit unsigned'))
	assert bo.report.notes.any(it.contains('/Sig/Ctr: enum key 18446744073709551615 ("Max") of /CM/B does not fit a 64-bit signed'))
	// and a RANGE between them is not a singleton, whatever their patterns say (round 22)
	span := parse_arxml(arxml_head + fd_cluster() + both.replace('<LOWER-LIMIT>-1</LOWER-LIMIT><UPPER-LIMIT>-1</UPPER-LIMIT><COMPU-CONST><VT>Neg</VT>', '<LOWER-LIMIT>-1</LOWER-LIMIT><UPPER-LIMIT>18446744073709551615</UPPER-LIMIT><COMPU-CONST><VT>Span</VT>') + arxml_tail) or {
		panic(err)
	}
	assert sig((span.cluster('') or { panic(err) }).db.messages[0], 'Ctr').values.len == 0
	assert span.report.notes.any(it.contains('/CM/B: maps the range -1..18446744073709551615 to "Span"'))
	// signed hex and a zero linear term
	assert parse_num('-0x1E') == -30.0
	assert parse_num('+0x10') == 16.0
	zero_slope := offset_pdu_xml.replace(v_sig, '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>Sys</SHORT-NAME><ELEMENTS><SYSTEM-SIGNAL><SHORT-NAME>S</SHORT-NAME><PHYSICAL-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/C</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></PHYSICAL-PROPS></SYSTEM-SIGNAL></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>C</SHORT-NAME><CATEGORY>LINEAR</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><COMPU-RATIONAL-COEFFS><COMPU-NUMERATOR><V>5</V><V>0</V></COMPU-NUMERATOR><COMPU-DENOMINATOR><V>1</V></COMPU-DENOMINATOR></COMPU-RATIONAL-COEFFS></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>'
	zs := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + zero_slope + arxml_tail) or {
		panic(err)
	}
	zv := sig((zs.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert zv.factor == 1.0 && zv.offset == 0.0
	assert zs.report.notes.any(it.contains('/CM/C: a constant conversion (every raw value is 5) is not modelled'))
	// rational coefficients with no numerator at all: said, not indexed (round 32)
	no_num := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + zero_slope.replace('<COMPU-NUMERATOR><V>5</V><V>0</V></COMPU-NUMERATOR>', '<COMPU-NUMERATOR></COMPU-NUMERATOR>') + arxml_tail) or {
		panic(err)
	}
	assert sig((no_num.cluster('') or { panic(err) }).db.messages[0], 'V').factor == 1.0
	assert no_num.report.notes.any(it.contains('/CM/C: rational coefficients without a numerator'))
	// a coefficient that is not a number: the scale is not read, no offset is invented (round 41)
	bad_c := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + zero_slope.replace('<COMPU-NUMERATOR><V>5</V><V>0</V></COMPU-NUMERATOR>', '<COMPU-NUMERATOR><V>invalid</V><V>2</V></COMPU-NUMERATOR>') + arxml_tail) or {
		panic(err)
	}
	bcv := sig((bad_c.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert bcv.factor == 1.0 && bcv.offset == 0.0
	assert bad_c.report.notes.any(it.contains('/CM/C: rational coefficient "invalid" is not a number; the scale is not read'))
	// a zero denominator: said, read as identity, and not counted as the linear scale (round 35)
	zero_den := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + zero_slope.replace('<COMPU-NUMERATOR><V>5</V><V>0</V></COMPU-NUMERATOR><COMPU-DENOMINATOR><V>1</V></COMPU-DENOMINATOR>', '<COMPU-NUMERATOR><V>5</V><V>2</V></COMPU-NUMERATOR><COMPU-DENOMINATOR><V>0</V></COMPU-DENOMINATOR>') + arxml_tail) or {
		panic(err)
	}
	zdv := sig((zero_den.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert zdv.factor == 1.0 && zdv.offset == 0.0
	assert zero_den.report.notes.any(it.contains('/CM/C: a linear scale with denominator 0 is not a conversion'))
}

fn test_round_19_shapes() {
	v_sig := '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH></I-SIGNAL>'
	// a signal the width guard drops must not reserve its name: the supported one behind it
	// keeps the plain name and no collision is reported
	wide_then_same := offset_pdu_xml.replace(v_sig, '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>72</LENGTH></I-SIGNAL>').replace('</I-SIGNAL-TO-PDU-MAPPINGS>', '<I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MV2</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/Sig2/V</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>16</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING></I-SIGNAL-TO-PDU-MAPPINGS>') + '<AR-PACKAGE><SHORT-NAME>Sig2</SHORT-NAME><ELEMENTS><I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>8</LENGTH></I-SIGNAL></ELEMENTS></AR-PACKAGE>'
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + wide_then_same + arxml_tail) or {
		panic(err)
	}
	m := (a.cluster('') or { panic(err) }).db.messages[0]
	assert m.signals.map(it.name) == ['Crc', 'Ctr', 'V'], m.signals.map(it.name).str()
	assert sig(m, 'V').length == 8
	assert a.report.notes.any(it.contains('72-bit signal is wider'))
	assert !a.report.notes.any(it.contains('is already used in this message'))
	// a LENGTH missing or 0 is dropped and said too — before its name is claimed (round 33)
	zero_w := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace(v_sig, '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>0</LENGTH></I-SIGNAL>') + arxml_tail) or {
		panic(err)
	}
	assert (zero_w.cluster('') or { panic(err) }).db.messages[0].signals.map(it.name) == ['Crc', 'Ctr']
	assert zero_w.report.notes.any(it.contains('/Sig/V: LENGTH 0 is outside 1..1048576; not read'))
	// `-0` is zero: filed under raw 0 for an unsigned signal, not dropped as a negative that
	// no sign bit can hold; a COMPU-DEFAULT-VALUE and nested SCALE-CONSTRS are said
	shapes := offset_pdu_xml.replace(v_sig, '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>Sys</SHORT-NAME><ELEMENTS><SYSTEM-SIGNAL><SHORT-NAME>S</SHORT-NAME><PHYSICAL-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/Z</COMPU-METHOD-REF><DATA-CONSTR-REF DEST="DATA-CONSTR">/DC/Split</DATA-CONSTR-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></PHYSICAL-PROPS></SYSTEM-SIGNAL></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>Z</SHORT-NAME><CATEGORY>TEXTTABLE</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><LOWER-LIMIT>-0</LOWER-LIMIT><UPPER-LIMIT>-0.0</UPPER-LIMIT><COMPU-CONST><VT>Off</VT></COMPU-CONST></COMPU-SCALE></COMPU-SCALES><COMPU-DEFAULT-VALUE><VT>Other</VT></COMPU-DEFAULT-VALUE></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>DC</SHORT-NAME><ELEMENTS><DATA-CONSTR><SHORT-NAME>Split</SHORT-NAME><DATA-CONSTR-RULES><DATA-CONSTR-RULE><PHYS-CONSTRS><LOWER-LIMIT>0</LOWER-LIMIT><UPPER-LIMIT>100</UPPER-LIMIT><SCALE-CONSTRS><SCALE-CONSTR><LOWER-LIMIT>0</LOWER-LIMIT><UPPER-LIMIT>10</UPPER-LIMIT></SCALE-CONSTR><SCALE-CONSTR><LOWER-LIMIT>90</LOWER-LIMIT><UPPER-LIMIT>100</UPPER-LIMIT></SCALE-CONSTR></SCALE-CONSTRS></PHYS-CONSTRS></DATA-CONSTR-RULE></DATA-CONSTR-RULES></DATA-CONSTR></ELEMENTS></AR-PACKAGE>'
	b := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + shapes + arxml_tail) or {
		panic(err)
	}
	bv := sig((b.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert bv.values == {
		u64(0): 'Off'
	}, bv.values.str()
	assert bv.minimum == 0.0 && bv.maximum == 100.0
	assert b.report.notes.any(it.contains('/CM/Z: declares a COMPU-DEFAULT-VALUE ("Other")'))
	assert b.report.notes.any(it.contains('/Sig/V: the data constraint has SCALE-CONSTRS'))
	// two rules: the first is read, and the choice is said (round 23)
	two_rules := shapes.replace('</DATA-CONSTR-RULE></DATA-CONSTR-RULES>', '</DATA-CONSTR-RULE><DATA-CONSTR-RULE><CONSTR-LEVEL>1</CONSTR-LEVEL><PHYS-CONSTRS><LOWER-LIMIT>5</LOWER-LIMIT><UPPER-LIMIT>50</UPPER-LIMIT></PHYS-CONSTRS></DATA-CONSTR-RULE></DATA-CONSTR-RULES>')
	tr := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + two_rules + arxml_tail) or {
		panic(err)
	}
	trv := sig((tr.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert trv.minimum == 0.0 && trv.maximum == 100.0
	assert tr.report.notes.any(it.contains('/Sig/V: the data constraint has 2 DATA-CONSTR-RULEs; the first physical'))
	// a linear scale's own OPEN bound, used as the range when nothing overrides it, is said too
	open_scale := offset_pdu_xml.replace(v_sig, '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH><SYSTEM-SIGNAL-REF DEST="SYSTEM-SIGNAL">/Sys/S</SYSTEM-SIGNAL-REF></I-SIGNAL>') + '<AR-PACKAGE><SHORT-NAME>Sys</SHORT-NAME><ELEMENTS><SYSTEM-SIGNAL><SHORT-NAME>S</SHORT-NAME><PHYSICAL-PROPS><SW-DATA-DEF-PROPS-VARIANTS><SW-DATA-DEF-PROPS-CONDITIONAL><COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/L</COMPU-METHOD-REF></SW-DATA-DEF-PROPS-CONDITIONAL></SW-DATA-DEF-PROPS-VARIANTS></PHYSICAL-PROPS></SYSTEM-SIGNAL></ELEMENTS></AR-PACKAGE>' + '<AR-PACKAGE><SHORT-NAME>CM</SHORT-NAME><ELEMENTS><COMPU-METHOD><SHORT-NAME>L</SHORT-NAME><CATEGORY>LINEAR</CATEGORY><COMPU-INTERNAL-TO-PHYS><COMPU-SCALES><COMPU-SCALE><LOWER-LIMIT INTERVAL-TYPE="OPEN">0</LOWER-LIMIT><UPPER-LIMIT>1000</UPPER-LIMIT><COMPU-RATIONAL-COEFFS><COMPU-NUMERATOR><V>0</V><V>0.1</V></COMPU-NUMERATOR><COMPU-DENOMINATOR><V>1</V></COMPU-DENOMINATOR></COMPU-RATIONAL-COEFFS></COMPU-SCALE></COMPU-SCALES></COMPU-INTERNAL-TO-PHYS></COMPU-METHOD></ELEMENTS></AR-PACKAGE>'
	os_ := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + open_scale + arxml_tail) or {
		panic(err)
	}
	osv := sig((os_.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert osv.factor == 0.1 && osv.minimum == 0.0 && osv.maximum == 100.0
	assert os_.report.notes.any(it.contains("/Sig/V: the compu scale's LOWER-LIMIT 0 is OPEN; read as a closed"))
	// …and NOT when a data constraint overrides the scale's domain: that import is exact (round 25)
	overridden := open_scale.replace('<COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/L</COMPU-METHOD-REF>', '<COMPU-METHOD-REF DEST="COMPU-METHOD">/CM/L</COMPU-METHOD-REF><DATA-CONSTR-REF DEST="DATA-CONSTR">/DC/Split</DATA-CONSTR-REF>') + '<AR-PACKAGE><SHORT-NAME>DC</SHORT-NAME><ELEMENTS><DATA-CONSTR><SHORT-NAME>Split</SHORT-NAME><DATA-CONSTR-RULES><DATA-CONSTR-RULE><PHYS-CONSTRS><LOWER-LIMIT>1</LOWER-LIMIT><UPPER-LIMIT>50</UPPER-LIMIT></PHYS-CONSTRS></DATA-CONSTR-RULE></DATA-CONSTR-RULES></DATA-CONSTR></ELEMENTS></AR-PACKAGE>'
	ov2 := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + overridden + arxml_tail) or {
		panic(err)
	}
	ov2v := sig((ov2.cluster('') or { panic(err) }).db.messages[0], 'V')
	assert ov2v.minimum == 1.0 && ov2v.maximum == 50.0
	assert !ov2.report.notes.any(it.contains('is OPEN'))
	// a description in two languages keeps the first and says so
	bilingual := offset_pdu_xml.replace(v_sig, '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><DESC><L-2 L="EN">speed</L-2><L-2 L="DE">Geschwindigkeit</L-2></DESC><LENGTH>16</LENGTH></I-SIGNAL>')
	bl := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + bilingual + arxml_tail) or {
		panic(err)
	}
	assert sig((bl.cluster('') or { panic(err) }).db.messages[0], 'V').desc == 'speed'
	assert bl.report.notes.any(it.contains('/Sig/V: the description has 2 languages; only the first (EN) is kept'))
	// two timing specifications on one PDU: the first is read and the count said (round 28)
	pdu_head := '<I-SIGNAL-I-PDU><SHORT-NAME>P</SHORT-NAME><LENGTH>4</LENGTH>'
	timing := fn (ms string) string {
		return '<I-PDU-TIMING><TRANSMISSION-MODE-DECLARATION><TRANSMISSION-MODE-TRUE-TIMING><CYCLIC-TIMING><TIME-PERIOD><VALUE>${ms}</VALUE></TIME-PERIOD></CYCLIC-TIMING></TRANSMISSION-MODE-TRUE-TIMING></TRANSMISSION-MODE-DECLARATION></I-PDU-TIMING>'
	}
	two_t := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace(pdu_head, pdu_head + '<I-PDU-TIMING-SPECIFICATIONS>' + timing('0.1') + timing('0.5') + '</I-PDU-TIMING-SPECIFICATIONS>') + arxml_tail) or {
		panic(err)
	}
	assert (two_t.cluster('') or { panic(err) }).db.messages[0].cycle_ms == 100
	assert two_t.report.notes.any(it.contains('/PDUs/P: 2 I-PDU-TIMING specifications; the first is read'))
	// a TIME-PERIOD that is not a number leaves no cycle, and says so twice over (round 40)
	nan_t := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace(pdu_head, pdu_head + '<I-PDU-TIMING-SPECIFICATIONS>' + timing('fast') + '</I-PDU-TIMING-SPECIFICATIONS>') + arxml_tail) or {
		panic(err)
	}
	assert (nan_t.cluster('') or { panic(err) }).db.messages[0].cycle_ms == 0
	assert nan_t.report.notes.any(it.contains('/PDUs/P: TIME-PERIOD "fast" is not a number; read as none'))
	assert nan_t.report.notes.any(it.contains('/PDUs/P: CYCLIC-TIMING with no usable TIME-PERIOD; the simulation sends nothing'))
	// a NUMBER-OF-REPETITIONS that cannot be read is said, not silently zero (round 41)
	bad_rep := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace(pdu_head, pdu_head + '<I-PDU-TIMING-SPECIFICATIONS><I-PDU-TIMING><TRANSMISSION-MODE-DECLARATION><TRANSMISSION-MODE-TRUE-TIMING><EVENT-CONTROLLED-TIMING><NUMBER-OF-REPETITIONS>many</NUMBER-OF-REPETITIONS></EVENT-CONTROLLED-TIMING></TRANSMISSION-MODE-TRUE-TIMING></TRANSMISSION-MODE-DECLARATION></I-PDU-TIMING></I-PDU-TIMING-SPECIFICATIONS>') + arxml_tail) or {
		panic(err)
	}
	assert bad_rep.report.notes.any(it.contains('/PDUs/P: NUMBER-OF-REPETITIONS "many" is not an integer; not read'))
	// a FALSE-mode timing beside the TRUE one: the true cadence is read and the choice said (round 29)
	false_t := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace(pdu_head, pdu_head + '<I-PDU-TIMING-SPECIFICATIONS>' + timing('0.1').replace('</TRANSMISSION-MODE-TRUE-TIMING>', '</TRANSMISSION-MODE-TRUE-TIMING><TRANSMISSION-MODE-FALSE-TIMING><CYCLIC-TIMING><TIME-PERIOD><VALUE>1.0</VALUE></TIME-PERIOD></CYCLIC-TIMING></TRANSMISSION-MODE-FALSE-TIMING>') + '</I-PDU-TIMING-SPECIFICATIONS>') + arxml_tail) or {
		panic(err)
	}
	assert (false_t.cluster('') or { panic(err) }).db.messages[0].cycle_ms == 100
	assert false_t.report.notes.any(it.contains("/PDUs/P: declares a TRANSMISSION-MODE-FALSE-TIMING too; the TRUE mode's timing is read"))
}

// a J1939 cluster beside a CAN one is a whole bus discarded: counted, so the load report and
// the provenance do not present the file as complete (round 28)
// A unique SHORT-NAME is reserved before any duplicate is qualified: with /Frames/F, /B/F and
// /C/B_F triggered in that order, the frame whose own name is B_F keeps it and the duplicate
// /B/F is qualified past it; the same for signals /Sig/V, /B/V, /C/B_V in one message (round 30).
fn test_unique_names_are_reserved_before_duplicates_are_qualified() {
	trig := fn (name string, id int, ref string) string {
		return '<CAN-FRAME-TRIGGERING><SHORT-NAME>${name}</SHORT-NAME><FRAME-REF DEST="CAN-FRAME">${ref}</FRAME-REF><CAN-ADDRESSING-MODE>STANDARD</CAN-ADDRESSING-MODE><IDENTIFIER>${id}</IDENTIFIER></CAN-FRAME-TRIGGERING>'
	}
	frame := fn (pkg string, name string) string {
		return '<AR-PACKAGE><SHORT-NAME>${pkg}</SHORT-NAME><ELEMENTS><CAN-FRAME><SHORT-NAME>${name}</SHORT-NAME><FRAME-LENGTH>8</FRAME-LENGTH><PDU-TO-FRAME-MAPPINGS><PDU-TO-FRAME-MAPPING><SHORT-NAME>M</SHORT-NAME><PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF><START-POSITION>8</START-POSITION></PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS></CAN-FRAME></ELEMENTS></AR-PACKAGE>'
	}
	cl := cluster_xml('Bus', 256, '/Frames/F').replace('</FRAME-TRIGGERINGS>', trig('FT2', 257, '/B/F') + trig('FT3', 258, '/C/B_F') + '</FRAME-TRIGGERINGS>')
	a := parse_arxml(arxml_head + cl + offset_pdu_xml + frame('B', 'F') + frame('C', 'B_F') + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	mut names := c.db.messages.map(it.name)
	names.sort()
	assert names == ['B_F', 'B_F_2', 'F'], names.str()
	assert (c.db.lookup(258) or { panic('no 258') }).name == 'B_F', 'the frame whose own name is B_F keeps it'
	assert (c.db.lookup(256) or { panic('no 256') }).name == 'F', 'the first duplicate keeps the short name'
	// signals: the same order inside one message
	v_sig := '<I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>16</LENGTH></I-SIGNAL>'
	maps := '<I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MB</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/B/V</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>16</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING><I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MC</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/C/B_V</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>20</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING></I-SIGNAL-TO-PDU-MAPPINGS>'
	sigs_xml := offset_pdu_xml.replace_once('</I-SIGNAL-TO-PDU-MAPPINGS>', maps) + '<AR-PACKAGE><SHORT-NAME>B</SHORT-NAME><ELEMENTS><I-SIGNAL><SHORT-NAME>V</SHORT-NAME><LENGTH>4</LENGTH></I-SIGNAL></ELEMENTS></AR-PACKAGE><AR-PACKAGE><SHORT-NAME>C</SHORT-NAME><ELEMENTS><I-SIGNAL><SHORT-NAME>B_V</SHORT-NAME><LENGTH>4</LENGTH></I-SIGNAL></ELEMENTS></AR-PACKAGE>'
	assert sigs_xml.contains(v_sig)
	s := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + sigs_xml + arxml_tail) or {
		panic(err)
	}
	m := (s.cluster('') or { panic(err) }).db.messages[0]
	mut snames := m.signals.map(it.name)
	snames.sort()
	assert snames == ['B_V', 'B_V_2', 'Crc', 'Ctr', 'V'], snames.str()
	assert sig(m, 'B_V').start_bit == 28, 'the signal whose own name is B_V keeps it'
	assert s.report.notes.any(it.contains('/B/V: signal name V is already used in this message; this one is B_V_2'))
	// one signal mapped TWICE keeps its first name and the second mapping is `_2` — not both
	// qualified, which allocating per occurrence did (round 31)
	twice := offset_pdu_xml.replace_once('</I-SIGNAL-TO-PDU-MAPPINGS>', '<I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MV2</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/Sig/V</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>16</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING></I-SIGNAL-TO-PDU-MAPPINGS>')
	tw := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + twice + arxml_tail) or {
		panic(err)
	}
	mut tnames := (tw.cluster('') or { panic(err) }).db.messages[0].signals.map(it.name)
	tnames.sort()
	assert tnames == ['Crc', 'Ctr', 'V', 'V_2'], tnames.str()
	// and a repeat cannot take a name RESERVED for a signal not yet reached: /Sig/V twice, then a
	// signal whose own name is V_2 — the repeat is V_3, V_2 stays V_2 (round 32)
	v2 := twice.replace_once('</I-SIGNAL-TO-PDU-MAPPINGS>', '<I-SIGNAL-TO-I-PDU-MAPPING><SHORT-NAME>MV3</SHORT-NAME><I-SIGNAL-REF DEST="I-SIGNAL">/D/V_2</I-SIGNAL-REF><PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER><START-POSITION>24</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING></I-SIGNAL-TO-PDU-MAPPINGS>') + '<AR-PACKAGE><SHORT-NAME>D</SHORT-NAME><ELEMENTS><I-SIGNAL><SHORT-NAME>V_2</SHORT-NAME><LENGTH>4</LENGTH></I-SIGNAL></ELEMENTS></AR-PACKAGE>'
	rv := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + v2 + arxml_tail) or {
		panic(err)
	}
	rm := (rv.cluster('') or { panic(err) }).db.messages[0]
	mut rnames := rm.signals.map(it.name)
	rnames.sort()
	assert rnames == ['Crc', 'Ctr', 'V', 'V_2', 'V_3'], rnames.str()
	assert sig(rm, 'V_2').start_bit == 32, 'the signal whose own name is V_2 keeps it'
	// the same for a frame triggered under two ids before a frame whose own name is F_2
	trig2 := fn (name string, id int, ref string) string {
		return '<CAN-FRAME-TRIGGERING><SHORT-NAME>${name}</SHORT-NAME><FRAME-REF DEST="CAN-FRAME">${ref}</FRAME-REF><CAN-ADDRESSING-MODE>STANDARD</CAN-ADDRESSING-MODE><IDENTIFIER>${id}</IDENTIFIER></CAN-FRAME-TRIGGERING>'
	}
	f2 := '<AR-PACKAGE><SHORT-NAME>G</SHORT-NAME><ELEMENTS><CAN-FRAME><SHORT-NAME>F_2</SHORT-NAME><FRAME-LENGTH>8</FRAME-LENGTH><PDU-TO-FRAME-MAPPINGS><PDU-TO-FRAME-MAPPING><SHORT-NAME>M</SHORT-NAME><PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF><START-POSITION>8</START-POSITION></PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS></CAN-FRAME></ELEMENTS></AR-PACKAGE>'
	clr := cluster_xml('Bus', 256, '/Frames/F').replace('</FRAME-TRIGGERINGS>', trig2('FTb', 257, '/Frames/F') + trig2('FTc', 258, '/G/F_2') + '</FRAME-TRIGGERINGS>')
	rf := parse_arxml(arxml_head + clr + offset_pdu_xml + f2 + arxml_tail) or { panic(err) }
	rfc := rf.cluster('') or { panic(err) }
	mut fnames := rfc.db.messages.map(it.name)
	fnames.sort()
	assert fnames == ['F', 'F_2', 'F_3'], fnames.str()
	assert (rfc.db.lookup(258) or { panic('no 258') }).name == 'F_2'
}

// a frame whose FRAME-LENGTH is missing or outside 0..64 is not read: a simulated sender sizes
// its payload from it (round 34)
fn test_frame_lengths_are_bounded() {
	big := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<FRAME-LENGTH>8</FRAME-LENGTH>', '<FRAME-LENGTH>72</FRAME-LENGTH>') + arxml_tail) or {
		panic(err)
	}
	assert (big.cluster('') or { panic(err) }).db.messages.len == 0
	assert big.report.notes.any(it.contains('frame F has FRAME-LENGTH 72 is outside 0..64; not read'))
	none_ := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<FRAME-LENGTH>8</FRAME-LENGTH>', '') + arxml_tail) or {
		panic(err)
	}
	assert (none_.cluster('') or { panic(err) }).db.messages.len == 0
	assert none_.report.notes.any(it.contains('frame F has no FRAME-LENGTH; not read'))
	// …and a FRAME-LENGTH that is not an integer is refused rather than read as 0 (round 38)
	nan := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<FRAME-LENGTH>8</FRAME-LENGTH>', '<FRAME-LENGTH>eight</FRAME-LENGTH>') + arxml_tail) or {
		panic(err)
	}
	assert (nan.cluster('') or { panic(err) }).db.messages.len == 0
	assert nan.report.notes.any(it.contains('frame F has FRAME-LENGTH "eight" is not an integer; not read'))
	// …and one that overflows the parser is refused too, not read as 0 (round 39)
	huge := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<FRAME-LENGTH>8</FRAME-LENGTH>', '<FRAME-LENGTH>0x10000000000000000</FRAME-LENGTH>') + arxml_tail) or {
		panic(err)
	}
	assert (huge.cluster('') or { panic(err) }).db.messages.len == 0
	assert huge.report.notes.any(it.contains('frame F has FRAME-LENGTH 0x10000000000000000 is outside 0..64; not read'))
	// classic CAN carries 8 bytes: a 12-byte frame not declared CAN-FD is not read (round 35)
	classic12 := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<FRAME-LENGTH>8</FRAME-LENGTH>', '<FRAME-LENGTH>12</FRAME-LENGTH>') + arxml_tail) or {
		panic(err)
	}
	assert (classic12.cluster('') or { panic(err) }).db.messages.len == 0
	assert classic12.report.notes.any(it.contains('frame F is classic CAN with FRAME-LENGTH 12, above the 8 bytes'))
	// …and is read when the triggering declares CAN-FD
	fd12 := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F').replace('<IDENTIFIER>256</IDENTIFIER>', '<IDENTIFIER>256</IDENTIFIER><CAN-FRAME-TX-BEHAVIOR>CAN-FD</CAN-FRAME-TX-BEHAVIOR>') + offset_pdu_xml.replace('<FRAME-LENGTH>8</FRAME-LENGTH>', '<FRAME-LENGTH>12</FRAME-LENGTH>') + arxml_tail) or {
		panic(err)
	}
	assert (fd12.cluster('') or { panic(err) }).db.messages[0].dlc == 12
	// …but only at a length a DLC expresses: 9 is padded by the software buses and refused by the
	// vendor backends, so it is not read (round 40)
	fd9 := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F').replace('<IDENTIFIER>256</IDENTIFIER>', '<IDENTIFIER>256</IDENTIFIER><CAN-FRAME-TX-BEHAVIOR>CAN-FD</CAN-FRAME-TX-BEHAVIOR>') + offset_pdu_xml.replace('<FRAME-LENGTH>8</FRAME-LENGTH>', '<FRAME-LENGTH>9</FRAME-LENGTH>') + arxml_tail) or {
		panic(err)
	}
	assert (fd9.cluster('') or { panic(err) }).db.messages.len == 0
	assert fd9.report.notes.any(it.contains('frame F is CAN-FD with FRAME-LENGTH 9, which no DLC expresses'))
	// an addressing mode that is neither STANDARD nor EXTENDED is not read as STANDARD
	weird := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F').replace('<CAN-ADDRESSING-MODE>STANDARD</CAN-ADDRESSING-MODE>', '<CAN-ADDRESSING-MODE>WIDE</CAN-ADDRESSING-MODE>') + offset_pdu_xml + arxml_tail) or {
		panic(err)
	}
	assert (weird.cluster('') or { panic(err) }).db.messages.len == 0
	assert weird.report.notes.any(it.contains('CAN-ADDRESSING-MODE "WIDE" is neither STANDARD nor EXTENDED; not read'))
	// a mapping without a PDU-REF is said, not silently an empty frame
	noref := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF>', '') + arxml_tail) or {
		panic(err)
	}
	assert (noref.cluster('') or { panic(err) }).db.messages[0].signals.len == 0
	assert noref.report.notes.any(it.contains('PDU-TO-FRAME-MAPPING M of frame F has no PDU-REF; not read'))
	// an overflowing PDU START-POSITION is refused, not read as byte 0
	ovp := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF><START-POSITION>8</START-POSITION>', '<PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF><START-POSITION>0x10000000000000000</START-POSITION>') + arxml_tail) or {
		panic(err)
	}
	assert (ovp.cluster('') or { panic(err) }).db.messages[0].signals.len == 0
	assert ovp.report.notes.any(it.contains('PDU P') && it.contains('START-POSITION 0x10000000000000000 is outside 0..512'))
	// an IDENTIFIER that is missing, negative or too wide for its addressing mode is not read
	for bad in ['<IDENTIFIER>2048</IDENTIFIER>', '<IDENTIFIER>-1</IDENTIFIER>', '',
		'<IDENTIFIER>invalid</IDENTIFIER>', '<IDENTIFIER>1.5</IDENTIFIER>', '<IDENTIFIER>+-256</IDENTIFIER>'] {
		b := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F').replace('<IDENTIFIER>256</IDENTIFIER>', bad) + offset_pdu_xml + arxml_tail) or {
			panic(err)
		}
		assert (b.cluster('') or { panic(err) }).db.messages.len == 0, bad
		assert b.report.notes.any(it.contains('IDENTIFIER') && it.contains('not read')), b.report.notes.str()
	}
	// a negative START-POSITION is not read
	neg := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<START-POSITION>0</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING>', '<START-POSITION>-16</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING>') + arxml_tail) or {
		panic(err)
	}
	assert !(neg.cluster('') or { panic(err) }).db.messages[0].signals.any(it.name == 'V')
	assert neg.report.notes.any(it.contains('/Sig/V: START-POSITION -16 is outside 0..512; not read'))
	// a START-POSITION missing or not an integer is not read (round 37)
	for bad in ['<START-POSITION>x</START-POSITION>', ''] {
		bp := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<START-POSITION>0</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING>', bad + '</I-SIGNAL-TO-I-PDU-MAPPING>') + arxml_tail) or {
			panic(err)
		}
		assert !(bp.cluster('') or { panic(err) }).db.messages[0].signals.any(it.name == 'V'), bad
		assert bp.report.notes.any(it.contains('/Sig/V: ') && it.contains('START-POSITION') && it.contains('not read')), bp.report.notes.str()
	}
	// a PDU whose own START-POSITION is negative, missing or not a number is not read, before
	// the byte normalisation could round -1 to byte 0 (round 38)
	for bad in ['<START-POSITION>-1</START-POSITION>', '<START-POSITION>eight</START-POSITION>', ''] {
		bp := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF><START-POSITION>8</START-POSITION>', '<PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF>' + bad) + arxml_tail) or {
			panic(err)
		}
		assert (bp.cluster('') or { panic(err) }).db.messages[0].signals.len == 0, bad
		assert bp.report.notes.any(it.contains('PDU P') && it.contains('START-POSITION') && it.contains('not read')), bp.report.notes.str()
	}
	// a signal that extends past the frame payload is not read: 16 bits at frame bit 56 of 8 bytes
	past := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<START-POSITION>0</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING>', '<START-POSITION>48</START-POSITION></I-SIGNAL-TO-I-PDU-MAPPING>').replace('<SHORT-NAME>P</SHORT-NAME><LENGTH>4</LENGTH>', '<SHORT-NAME>P</SHORT-NAME><LENGTH>8</LENGTH>') + arxml_tail) or {
		panic(err)
	}
	assert !(past.cluster('') or { panic(err) }).db.messages[0].signals.any(it.name == 'V')
	assert past.report.notes.any(it.contains('/Sig/V: 16-bit signal at frame bit 56 extends past the 8-byte frame F; not read'))
	// …and past its own PDU: a 16-bit signal in a 1-byte PDU, with frame room to spare (round 41)
	pdu1 := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace('<I-SIGNAL-I-PDU><SHORT-NAME>P</SHORT-NAME><LENGTH>4</LENGTH>', '<I-SIGNAL-I-PDU><SHORT-NAME>P</SHORT-NAME><LENGTH>1</LENGTH>') + arxml_tail) or {
		panic(err)
	}
	assert !(pdu1.cluster('') or { panic(err) }).db.messages[0].signals.any(it.name == 'V')
	assert pdu1.report.notes.any(it.contains('/Sig/V: 16-bit signal at PDU bit 0 extends past the 1-byte PDU; not read'))
	// a PACKING-BYTE-ORDER that is none of the three is not read as little-endian
	pbo := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml.replace_once('<PACKING-BYTE-ORDER>MOST-SIGNIFICANT-BYTE-LAST</PACKING-BYTE-ORDER>', '<PACKING-BYTE-ORDER>MIDDLE-ENDIAN</PACKING-BYTE-ORDER>') + arxml_tail) or {
		panic(err)
	}
	assert !(pbo.cluster('') or { panic(err) }).db.messages[0].signals.any(it.name == 'V')
	assert pbo.report.notes.any(it.contains('/Sig/V: PACKING-BYTE-ORDER "MIDDLE-ENDIAN" is not MOST-SIGNIFICANT-BYTE-FIRST, -LAST or OPAQUE; not read'))
	// the fit rule, both byte orders
	assert signal_fits_frame(Signal{ start_bit: 48, length: 16 }, 8)
	assert !signal_fits_frame(Signal{ start_bit: 56, length: 16 }, 8)
	assert signal_fits_frame(Signal{ start_bit: 63, length: 16, byte_order: .big_endian }, 8) == false // 63..56 then 55..48? no: Motorola from 63 descends to 56, then 71.. — past
	assert signal_fits_frame(Signal{ start_bit: 55, length: 16, byte_order: .big_endian }, 8) // 55..48, 63..56
	assert signal_fits_frame(Signal{ start_bit: 7, length: 8, byte_order: .big_endian }, 1)
	assert !signal_fits_frame(Signal{ start_bit: 7, length: 9, byte_order: .big_endian }, 1)
	// a rejected triggering reserves no name: /Frames/F with an invalid id, then /B/F imports as F
	rej := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F').replace('<IDENTIFIER>256</IDENTIFIER></CAN-FRAME-TRIGGERING>', '<IDENTIFIER>invalid</IDENTIFIER></CAN-FRAME-TRIGGERING><CAN-FRAME-TRIGGERING><SHORT-NAME>FTB</SHORT-NAME><FRAME-REF DEST="CAN-FRAME">/B/F</FRAME-REF><CAN-ADDRESSING-MODE>STANDARD</CAN-ADDRESSING-MODE><IDENTIFIER>257</IDENTIFIER></CAN-FRAME-TRIGGERING>') + offset_pdu_xml + '<AR-PACKAGE><SHORT-NAME>B</SHORT-NAME><ELEMENTS><CAN-FRAME><SHORT-NAME>F</SHORT-NAME><FRAME-LENGTH>8</FRAME-LENGTH><PDU-TO-FRAME-MAPPINGS><PDU-TO-FRAME-MAPPING><SHORT-NAME>M</SHORT-NAME><PDU-REF DEST="I-SIGNAL-I-PDU">/PDUs/P</PDU-REF><START-POSITION>8</START-POSITION></PDU-TO-FRAME-MAPPING></PDU-TO-FRAME-MAPPINGS></CAN-FRAME></ELEMENTS></AR-PACKAGE>' + arxml_tail) or {
		panic(err)
	}
	assert (rej.cluster('') or { panic(err) }).db.messages.map(it.name) == ['F']
}

fn test_a_j1939_cluster_is_counted_as_ignored() {
	j := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + offset_pdu_xml + '<AR-PACKAGE><SHORT-NAME>J</SHORT-NAME><ELEMENTS><J-1939-CLUSTER><SHORT-NAME>Truck</SHORT-NAME></J-1939-CLUSTER></ELEMENTS></AR-PACKAGE>' + arxml_tail) or {
		panic(err)
	}
	assert j.report.ignored['J-1939-CLUSTER'] == 1, j.report.ignored.str()
	assert j.report.lines().any(it.contains('J-1939-CLUSTER'))
}

// fd_cluster is cluster_xml's one triggering declared CAN-FD, for fixtures whose 64-bit signals
// need a 16-byte payload: a classic frame carries 8 bytes and the reader now holds it to that.
fn fd_cluster() string {
	return cluster_xml('Bus', 256, '/Frames/F').replace('<IDENTIFIER>256</IDENTIFIER>', '<IDENTIFIER>256</IDENTIFIER><CAN-FRAME-TX-BEHAVIOR>CAN-FD</CAN-FRAME-TX-BEHAVIOR>')
}

fn test_two_triggerings_of_one_id_keep_the_first_and_say_so() {
	two := cluster_xml('Bus', 256, '/Frames/F').replace('</FRAME-TRIGGERINGS>', '<CAN-FRAME-TRIGGERING><SHORT-NAME>FT2</SHORT-NAME><FRAME-REF DEST="CAN-FRAME">/Frames/F</FRAME-REF><CAN-ADDRESSING-MODE>STANDARD</CAN-ADDRESSING-MODE><IDENTIFIER>256</IDENTIFIER></CAN-FRAME-TRIGGERING></FRAME-TRIGGERINGS>')
	a := parse_arxml(arxml_head + two + frame_xml + arxml_tail) or { panic(err) }
	c := a.cluster('') or { panic(err) }
	assert c.db.messages.len == 1
	assert a.report.notes.any(it.contains('a second triggering for id 0x100'))
}

fn test_load_arxml_file_is_cached_per_file() {
	path := os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'example.arxml')
	before := arxml_cache_hit_count()
	load_arxml_file(path) or { panic(err) }
	load_arxml_file(path) or { panic(err) }
	assert arxml_cache_hit_count() >= before + 1
	// a rewritten file (new content, same length, same second) is read again
	dir := os.join_path(os.temp_dir(), 'candb_arxml_cache_test')
	os.mkdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	// a parse that FAILS is remembered for the same bytes too — the second load is a hit that
	// still errors — and repaired bytes retry (round 29)
	bad := os.join_path(dir, 'bad.arxml')
	os.write_file(bad, '<AUTOSAR><oops>') or { panic(err) }
	load_arxml_file(bad) or {}
	hits_before_bad := arxml_cache_hit_count()
	if _ := load_arxml_file(bad) {
		assert false, 'a broken file parsed'
	}
	assert arxml_cache_hit_count() == hits_before_bad + 1
	os.write_file(bad, arxml_head + cluster_xml('One', 1, '/Frames/F') + frame_xml + arxml_tail) or {
		panic(err)
	}
	load_arxml_file(bad) or { panic('repaired bytes must parse: ${err}') }
	p := os.join_path(dir, 'a.arxml')
	os.write_file(p, arxml_head + cluster_xml('One', 1, '/Frames/F') + frame_xml + arxml_tail) or {
		panic(err)
	}
	a1 := load_arxml_file(p) or { panic(err) }
	assert a1.clusters[0].name == 'One'
	os.write_file(p, arxml_head + cluster_xml('Two', 1, '/Frames/F') + frame_xml + arxml_tail) or {
		panic(err)
	}
	a2 := load_arxml_file(p) or { panic(err) }
	assert a2.clusters[0].name == 'Two'
}

fn test_merge_files_report_says_what_it_skipped() {
	dir := os.join_path(os.temp_dir(), 'candb_arxml_merge_report_test')
	os.mkdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	two := os.join_path(dir, 'two.arxml')
	os.write_file(two, arxml_head + cluster_xml('Body', 1, '/Frames/F') + cluster_xml('Chassis', 2, '/Frames/F') + frame_xml + arxml_tail) or { panic(err) }
	// no fragment on a two-cluster file: refused, and the refusal is in the notes rather
	// than being the silent empty database the merge used to hand back
	db, notes := merge_files_report([two, os.join_path(dir, 'missing.dbc')])
	assert db.messages.len == 0
	assert notes.len == 2
	assert notes[0].contains('cannot load ${two}: 2 CAN clusters (Body, Chassis): name one')
	assert notes[1].starts_with('cannot load ')
	// named: loaded, and the reader's own notes come along, prefixed with the file
	db2, notes2 := merge_files_report([two + '#Chassis'])
	assert db2.messages.len == 1
	// the frame's dangling PDU-REF is followed once per cluster that carries the frame
	assert notes2.len == 2
	assert notes2.all(it.starts_with('two.arxml: unresolved reference:'))
	assert merge_files([two + '#Chassis']).messages.len == 1
}

fn test_canonical_database_ref_keeps_the_fragment() {
	dir := os.join_path(os.temp_dir(), 'candb_arxml_canon_test')
	os.mkdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	p := os.join_path(dir, 'x.arxml')
	os.write_file(p, '<AUTOSAR/>') or { panic(err) }
	real := os.real_path(p)
	assert canonical_database_ref(p + '#Body') == real + '#Body'
	assert canonical_database_ref(p) == real
	// the same file reached two ways is ONE key, fragment and all
	assert canonical_database_ref(os.join_path(dir, '.', 'x.arxml') + '#Body') == real + '#Body'
}

fn test_number_forms() {
	assert parse_int('256') == 256
	assert parse_int('0x100') == 256
	assert parse_int('8.0') == 8
	assert parse_int('') == 0
	assert seconds_to_ms('0.1') == 100
	assert seconds_to_ms('1.0E-2') == 10
	assert seconds_to_ms('0.02') == 20
	assert seconds_to_ms('') == 0
	assert xml_unescape('a &amp; b &lt; c &gt; d &quot;e&quot; &apos;f&apos;') == 'a & b < c > d "e" \'f\''
	// a reference vlib does not know fails its decode; the raw text is the honest answer
	assert xml_unescape('x &unknown; y') == 'x &unknown; y'
}

// --- the export (arxml_export.v) --------------------------------------------------------
fn example_cluster() ArxmlCluster {
	return example_arxml().cluster('Body') or { panic(err) }
}

// the mapped primitive is one the simulation can compute, by the one list
fn test_e2e_profile_primitive_is_held_to_the_shared_list() {
	for p in ['PROFILE_01', 'PROFILE_11', 'PROFILE_02', 'PROFILE_22'] {
		assert e2e_profile_primitive(p) in e2e_profiles, p
	}
	assert e2e_profile_primitive('PROFILE_05') == ''
}

fn test_e2e_signals_from_offsets() {
	c := example_cluster()
	lamp := c.db.lookup(0x200) or { panic('no LampFrame') }
	s := c.e2e_signals(lamp) or { panic('LampFrame is protected') }
	assert s.counter == 'LampCounter'
	assert s.crc == 'LampCrc'
	assert s.profile == 'crc8_j1850'
	assert s.data_id == 42
	// unprotected: none
	pt := c.db.lookup(0x100) or { panic('no Powertrain') }
	assert c.e2e_signals(pt) == none
	// a profile whose CRC this app cannot compute maps to '' — nothing pretends
	assert e2e_profile_primitive('PROFILE_02') == 'crc8_autosar'
	assert e2e_profile_primitive('PROFILE_05') == ''
}

fn test_export_dbc_carries_provenance_and_attributes() {
	a := example_arxml()
	c := a.cluster('Body') or { panic(err) }
	text := c.export_dbc(ArxmlProvenance{
		source: 'example.arxml'
		sha256: 'abc123'
		reader: '0.2.0'
		cluster: 'Body'
	}, a.report)
	lines := text.split('\n')
	// the network comment says where the file came from and what the reader dropped
	// notes=5: the same five the golden list in test_cluster_and_nodes pins — a partial read is
	// stamped as one, and travels with the DBC
	assert lines.any(it == 'CM_ "arxml2dbc: source=example.arxml sha256=abc123 reader=0.2.0 cluster=Body dropped=1 unresolved=0 notes=5";'), lines.filter(it.starts_with('CM_ "arxml2dbc')).str()
	// #271's attributes, defined once, valued on the protected message only
	assert lines.any(it == 'BA_DEF_ BO_ "E2ECounterSignal" STRING;')
	assert lines.any(it == 'BA_DEF_ BO_ "E2EDataId" INT 0 65535;')
	assert lines.any(it == 'BA_DEF_DEF_ "E2EProfile" "";')
	assert lines.any(it == 'BA_ "E2ECounterSignal" BO_ 512 "LampCounter";')
	assert lines.any(it == 'BA_ "E2ECrcSignal" BO_ 512 "LampCrc";')
	assert lines.any(it == 'BA_ "E2EProfile" BO_ 512 "crc8_j1850";')
	assert lines.any(it == 'BA_ "E2EDataId" BO_ 512 42;')
	assert lines.filter(it.starts_with('BA_ "E2E')).len == 4
	// receivers reach the SG_ lines
	assert lines.any(it == ' SG_ EngineSpeed : 0|16@1+ (0.25,0) [0|8000] "rpm" ECU_B,ECU_C')
	// the frame format survives: the one thing that tells a short FD frame from a classic one
	assert lines.any(it.starts_with('BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN"'))
	assert lines.any(it == 'BA_DEF_DEF_ "VFrameFormat" "StandardCAN";') // an ENUM default is the choice
	
	assert lines.any(it == 'BA_ "VFrameFormat" BO_ 2149235934 15;')
	// every frame states its format once the attribute exists: the default would be
	// StandardCAN, wrong for an extended classic frame
	assert lines.any(it == 'BA_ "VFrameFormat" BO_ 256 0;')
	assert lines.filter(it.starts_with('BA_ "VFrameFormat"')).len == 5
	// section order the format requires: every BA_DEF_ before every BA_DEF_DEF_ before every
	// BA_, the comment with the CM_ records, value tables last
	last_def := index_of_last(lines, 'BA_DEF_ ')
	first_dd := index_of_first(lines, 'BA_DEF_DEF_')
	last_dd := index_of_last(lines, 'BA_DEF_DEF_')
	first_ba := index_of_first(lines, 'BA_ ')
	first_val := index_of_first(lines, 'VAL_ ')
	first_cm := index_of_first(lines, 'CM_ ')
	first_cm_sg := index_of_first(lines, 'CM_ SG_')
	assert last_def < first_dd
	assert last_dd < first_ba
	assert first_ba < first_val
	assert first_cm <= first_cm_sg
	assert first_cm < index_of_first(lines, 'BA_DEF_ ')
	// and the whole thing is still a DBC this parser reads, with nothing lost that it models
	back := parse_dbc(text) or { panic(err) }
	assert back.to_dbc() == c.db.to_dbc()
}

fn test_export_dbc_without_protection_has_no_attribute_block() {
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + frame_xml + arxml_tail) or {
		panic(err)
	}
	c := a.cluster('') or { panic(err) }
	text := c.export_dbc(ArxmlProvenance{ source: 'x.arxml' }, a.report)
	assert !text.contains('E2E')
	assert text.contains('unresolved=1')
	assert text.contains('dropped=0')
	assert text.contains('notes=')
}

fn test_frame_toml_per_ecu() {
	c := example_cluster()
	all := c.frame_toml('')
	assert all.contains('[[frame]]\nname = "Powertrain"\nbus  = "Body"\ntx   = { mode = "cyclic", cycle_ms = 100, min_delay_ms = 20 }')
	assert all.contains('name = "LampFrame"\nbus  = "Body"\ntx   = { mode = "mixed", cycle_ms = 100, min_delay_ms = 10 }\ne2e  = { data_id = 0x2A, crc_pos = 6, counter_pos = 7 }  # crc8_j1850, from PROFILE_01 (blobly\'s primitive, not the full AUTOSAR profile)')
	assert all.contains('# secoc = { key = "…", data_id = 0x2B, fresh_pos = 3, mac_pos = 4, mac_len = 4 }')
	assert all.contains('name = "Wide"\nbus  = "Body"\n# CAN-FD frame (16 bytes)\ntx   = { mode = "event" }')
	// a frame nobody sends is still listed when everything is asked for
	assert all.contains('name = "DiagReq"')
	assert !all.contains('\nrx   =')

	// ECU_A: sends Powertrain, receives LampFrame, SecureFrame and DiagReq; never sees Wide
	a := c.frame_toml('ECU_A')
	assert a.contains('name = "Powertrain"\nbus  = "Body"\ntx   =')
	// the deadline is not in the file: a placeholder with the cadence beside it, never a number
	assert a.contains('name = "LampFrame"\nbus  = "Body"\n# rx   = { timeout_ms = ? }  # set from the ECU\'s ComTimeout (the sender\'s cycle is 100 ms)\ne2e  =')
	assert a.contains('name = "DiagReq"\nbus  = "Body"\n# rx   = { timeout_ms = ? }  # set from the ECU\'s ComTimeout (no cycle declared)')
	assert !a.contains('\nrx   =')
	assert !a.contains('name = "Wide"')
	assert !a.contains('name = "Powertrain"\nbus  = "Body"\n# rx')
	// FD is a bus property in ecu.toml: stated once for the bus, and marked on the frame
	assert all.contains('# [bus.Body]  baudrate = 500000, data_baudrate = 2000000, fd = true')
	assert all.contains('name = "Wide"\nbus  = "Body"\n# CAN-FD frame (16 bytes)\ntx   =')
	// an ECU the cluster never names is a typo, not an empty fragment
	assert c.ecus() == ['ECU_A', 'ECU_B', 'ECU_C']
}

fn test_report_lines() {
	a := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + frame_xml + arxml_tail) or {
		panic(err)
	}
	l := a.report.lines()
	assert l.len == 1
	assert l[0].starts_with('unresolved reference: ')
	assert example_arxml().report.lines() == [
		'ignored: 1 × N-PDU',
		'note: /PDUs/LampFrame_PDU: cyclic and event-controlled timing; the simulation sends on the cycle only, never on a change',
		"note: LampFrame: declares an E2E PROFILE_01 contract; carried to the DBC export and the fragment, but NOT applied by the native simulation, which protects only what the project's protect: entries name",
		'note: SecureFrame: declares SecOC protection; carried to the fragment, but NOT applied by the native simulation, which has no SecOC stamping — freshness and MAC bytes go out as 0',
		'note: /PDUs/Wide_PDU: event-controlled timing only, no cyclic timing; the simulation sends on a cycle and sends nothing for this frame',
		'note: /Cluster/Body: 1 CAN-FD and 4 classic frames on one cluster; the simulation applies one format per bus, the export keeps the distinction',
	]
}

fn index_of_first(lines []string, prefix string) int {
	for i, l in lines {
		if l.starts_with(prefix) {
			return i
		}
	}
	return -1
}

fn index_of_last(lines []string, prefix string) int {
	mut r := -1
	for i, l in lines {
		if l.starts_with(prefix) {
			r = i
		}
	}
	return r
}

// --- database.v: one way to open a database by path -----------------------------------------
fn test_split_database_ref() {
	f, c := split_database_ref('x/net.arxml#Body')
	assert f == 'x/net.arxml'
	assert c == 'Body'
	f2, c2 := split_database_ref('x/net.arxml')
	assert f2 == 'x/net.arxml'
	assert c2 == ''
	// a DBC keeps its hash whatever precedes it: this is one DBC file, not an ARXML fragment
	fd, cd := split_database_ref('archive.arxml#body.dbc')
	assert fd == 'archive.arxml#body.dbc'
	assert cd == ''
	assert !is_arxml_ref('archive.arxml#body.dbc')
	// …and one ARXML whose name carries `.arxml#`: a cluster fragment never ends in an extension
	fa, ca := split_database_ref('archive.arxml#copy.arxml')
	assert fa == 'archive.arxml#copy.arxml'
	assert ca == ''
	assert is_arxml_ref('archive.arxml#copy.arxml')
	// a hash in a DBC name is a character, not a fragment
	f3, c3 := split_database_ref('odd#name.dbc')
	assert f3 == 'odd#name.dbc'
	assert c3 == ''
	f4, c4 := split_database_ref('NET.ARXML#Chassis')
	assert f4 == 'NET.ARXML'
	assert c4 == 'Chassis'
	assert is_arxml_ref('a.arxml#B')
	assert is_arxml_ref('a.arxml')
	assert !is_arxml_ref('a.dbc')
}

fn test_load_database_dispatches_on_extension() {
	arxml := os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'example.arxml')
	dbc := os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'blobly_net.dbc')
	a := load_database(arxml) or { panic(err) }
	assert a.messages.len == 5
	b := load_database(arxml + '#Body') or { panic(err) }
	assert b.messages.len == 5
	if _ := load_database(arxml + '#Chassis') {
		assert false, 'an absent cluster must be refused'
	} else {
		assert err.msg().contains('no CAN cluster "Chassis"')
	}
	d := load_database(dbc) or { panic(err) }
	assert d.messages.len == 8
	if _ := load_database('/nonexistent/x.arxml') {
		assert false
	} else {
		assert err.msg() != ''
	}
	// merge_files reaches the same dispatcher, so a project may mix the two; ids the two files
	// share (0x100, 0x200, 0x300 are in both) merge as they would for two DBCs — first wins
	m := merge_files([dbc, arxml + '#Body'])
	mut fresh := 0
	for x in a.messages {
		if d.lookup_frame(x.id, x.ext) == none {
			fresh++
		}
	}
	assert fresh == 2
	assert m.messages.len == d.messages.len + fresh
	assert (m.lookup(0x100) or { panic('no 0x100') }).name == 'Powertrain'
	assert (m.lookup(0x1ABCDE) or { panic('no Wide') }).name == 'Wide'
}
