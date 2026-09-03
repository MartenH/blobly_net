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
	f := c.frames['Powertrain']
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
	

	f := c.frames['LampFrame']
	assert f.tx_mode == 'mixed'
	assert f.min_delay_ms == 10
	assert f.receivers == ['ECU_A']
	e := f.e2e or { panic('LampFrame has no E2E') }
	assert e.profile == 'PROFILE_01'
	assert e.data_id == 42
	assert e.data_ids == [u32(42)]
	assert e.data_id_mode == 'ALL-16-BIT'
	assert e.crc_offset == 48
	assert e.counter_offset == 56
	assert e.data_length == 64
	assert e.crc_byte == 6
	assert e.counter_byte == 7
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
	f := c.frames['SecureFrame']
	assert f.pdu == 'Secure_PDU'
	assert f.pdu_kind == 'SECURED-I-PDU'
	assert f.tx_mode == 'cyclic'
	s := f.secoc or { panic('SecureFrame has no SecOC') }
	assert s.data_id == 43
	assert s.freshness_len == 64
	assert s.freshness_tx_len == 8
	assert s.auth_info_tx_len == 32
	assert s.authentic_len == 3
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
	f := c.frames['Wide']
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
	f := c.frames['DiagReq']
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
	assert all.contains('name = "LampFrame"\nbus  = "Body"\ntx   = { mode = "mixed", cycle_ms = 100, min_delay_ms = 10 }\ne2e  = { data_id = 0x2A, crc_pos = 6, counter_pos = 7 }  # PROFILE_01')
	assert all.contains('# secoc = { key = "…", data_id = 0x2B, fresh_pos = 3, mac_pos = 4, mac_len = 4 }')
	assert all.contains('name = "Wide"\nbus  = "Body"\ntx   = { mode = "event" }')
	// a frame nobody sends is still listed when everything is asked for
	assert all.contains('name = "DiagReq"')
	assert !all.contains('rx   =')

	// ECU_A: sends Powertrain, receives LampFrame, SecureFrame and DiagReq; never sees Wide
	a := c.frame_toml('ECU_A')
	assert a.contains('name = "Powertrain"\nbus  = "Body"\ntx   =')
	assert a.contains('name = "LampFrame"\nbus  = "Body"\n# rx timeout is ECU configuration (ComTimeout), not in the system description\nrx   = { timeout_ms = 300 }\ne2e  =')
	assert a.contains('name = "DiagReq"\nbus  = "Body"\n# rx timeout')
	assert a.contains('rx   = { timeout_ms = 0 }') // no cadence to derive one from: 0, not a guess
	

	assert !a.contains('name = "Wide"')
	assert !a.contains('name = "Powertrain"\nbus  = "Body"\n# rx')
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
