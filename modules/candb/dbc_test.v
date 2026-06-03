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
