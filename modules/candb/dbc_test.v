module candb

import os

// Resolve the repo's real DBC relative to this source file, so the test passes
// regardless of the working directory `v test` runs from.
fn cantester_dbc() Database {
	path := os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'cantester.dbc')
	return load_dbc_file(path) or { panic('cannot load ${path}: ${err}') }
}

fn test_dbc_messages_parsed() {
	db := cantester_dbc()
	assert db.messages.len == 4
	pt := db.lookup(0x100) or { panic('no Powertrain') }
	assert pt.name == 'Powertrain'
	assert pt.dlc == 8
	assert pt.signals.len == 6
	hb := db.lookup(0x700) or { panic('no Heartbeat') }
	assert hb.name == 'Heartbeat'
	assert hb.dlc == 1
	assert hb.signals.len == 1
	assert db.lookup(0x101) != none
	assert db.lookup(0x102) != none
}

fn test_dbc_signal_layout() {
	pt := cantester_dbc().lookup(0x100) or { panic('no Powertrain') }
	es := pt.signals[0]
	assert es.name == 'EngineSpeed'
	assert es.start_bit == 0
	assert es.length == 16
	assert es.factor == 0.25
	assert es.offset == 0
	assert es.unit == 'rpm'
	assert es.byte_order == .little_endian
	assert es.is_signed == false

	ct := pt.signals[2]
	assert ct.name == 'CoolantTemp'
	assert ct.start_bit == 28
	assert ct.length == 8
	assert ct.offset == -40
}

fn test_dbc_value_table() {
	pt := cantester_dbc().lookup(0x100) or { panic('no Powertrain') }
	gear := pt.signals[4]
	assert gear.name == 'Gear'
	assert gear.values[3] == 'Third'
	assert gear.values[0] == 'Neutral'
	cruise := pt.signals[5]
	assert cruise.values[1] == 'On'
	assert cruise.values[0] == 'Off'
}

fn test_dbc_comments() {
	pt := cantester_dbc().lookup(0x100) or { panic('no Powertrain') }
	assert pt.signals[0].desc == 'Crankshaft rotational speed'
	assert pt.signals[4].desc == 'Currently engaged gear'
}

fn test_parse_tolerates_other_records() {
	// BU_, BA_DEF_, blank lines and an indented SG_ under its BO_ must all parse.
	text := 'VERSION "x"\n\nBU_: SUT Tester\nBO_ 100 M: 8 SUT\n SG_ S1 : 0|8@1+ (1,0) [0|255] "u" Tester\nBA_DEF_ "GenMsgCycleTime" INT 0 10000;\n\nVAL_ 100 S1 0 "zero" 1 "one" ;\n'
	db := parse_dbc(text) or { panic('should parse: ${err}') }
	assert db.messages.len == 1
	m := db.lookup(100) or { panic('no msg') } // BO_ ids are decimal
	assert m.signals.len == 1
	assert m.signals[0].values[1] == 'one'
}

fn test_parse_big_endian_signal() {
	text := 'BO_ 200 BE: 8 SUT\n SG_ Word : 7|16@0+ (1,0) [0|65535] "" Tester\n'
	m := (parse_dbc(text) or { panic(err) }).lookup(200) or { panic('no msg') }
	w := m.signals[0]
	assert w.byte_order == .big_endian
	data := [u8(0x12), 0x34, 0, 0, 0, 0, 0, 0]
	assert w.physical(data) == f64(0x1234)
}

fn test_parse_signed_marker() {
	text := 'BO_ 300 S: 8 SUT\n SG_ T : 0|8@1- (1,0) [-128|127] "" Tester\n'
	m := (parse_dbc(text) or { panic(err) }).lookup(300) or { panic('no msg') }
	assert m.signals[0].is_signed
}

fn test_sg_without_bo_is_error() {
	if _ := parse_dbc('SG_ Orphan : 0|8@1+ (1,0) [0|0] "" R') {
		assert false, 'expected error for SG_ with no BO_'
	}
}

fn test_missing_file_is_error() {
	if _ := load_dbc_file('/nonexistent/does-not-exist.dbc') {
		assert false, 'expected error for missing file'
	}
}

fn test_dbc_decode_roundtrip_and_label() {
	pt := cantester_dbc().lookup(0x100) or { panic('no Powertrain') }
	mut data := []u8{len: 8}
	pt.signals[0].encode(mut data, 2000.0) // EngineSpeed
	pt.signals[1].encode(mut data, 88.0)   // VehicleSpeed
	pt.signals[4].encode(mut data, 3.0)    // Gear
	assert pt.signals[0].physical(data) == 2000.0
	assert pt.signals[1].physical(data) == 88.0
	assert pt.signals[4].label(data) == 'Third'
}
