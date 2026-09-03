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
	// the file is complete: nothing dangling, nothing partially read
	assert a.report.unresolved == []
	assert a.report.notes == []
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
	assert a.cluster_names() == ['/Body/Body', '/Other/Body']
	if _ := a.cluster('Body') {
		assert false, 'a shared short name must be refused'
	} else {
		assert err.msg().contains('"Body" names 2 CAN clusters (/Body/Body, /Other/Body): use the path')
	}
	assert (a.cluster('/Other/Body') or { panic(err) }).db.messages[0].id == 2
	// a unique short name still works, by name or by path
	one := parse_arxml(arxml_head + cluster_xml('Body', 1, '/Frames/F') + frame_xml + arxml_tail) or {
		panic(err)
	}
	assert one.cluster_names() == ['Body']
	assert (one.cluster('Body') or { panic(err) }).path == '/Body/Body'
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
	// second must not inherit the first's masked table
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
		u64(15): 'Invalid'
		u64(1):  'One'
	}
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
	// a one-term numerator is a constant: factor 0, not the identity
	konst := parse_arxml(arxml_head + cluster_xml('Bus', 256, '/Frames/F') + sigs + poly.replace('@COEFFS@', '<V>5</V>') + arxml_tail) or { panic(err) }
	kc := konst.cluster('') or { panic(err) }
	ks := sig(kc.db.messages[0], 'Crc')
	assert ks.factor == 0
	assert ks.offset == 5
	assert ks.minimum == 5
	assert ks.maximum == 5
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
	assert lines.any(it == 'CM_ "arxml2dbc: source=example.arxml sha256=abc123 reader=0.2.0 cluster=Body dropped=1 unresolved=0";')
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
	assert example_arxml().report.lines() == ['ignored: 1 × N-PDU']
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
