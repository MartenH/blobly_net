module candb

import os

// Resolve the repo's real DBC relative to this source file, so the test passes
// regardless of the working directory `v test` runs from.
fn blobly_net_dbc() Database {
	path := os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'blobly_net.dbc')
	return load_dbc_file(path) or { panic('cannot load ${path}: ${err}') }
}

fn test_dbc_messages_parsed() {
	db := blobly_net_dbc()
	// SUT/Tester core (4) + BodyECU/ChassisECU/BatteryECU messages (4) = 8.
	assert db.messages.len == 8
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
	// nodes + transmitter mapping for the added ECUs
	assert db.nodes == ['SUT', 'Tester', 'BodyECU', 'ChassisECU', 'BatteryECU']
	assert db.messages_from('ChassisECU').len == 2 // WheelSpeeds + BrakeStatus
	assert db.lookup(0x300) or { panic('no WheelSpeeds') }.signals.len == 4
}

fn test_dbc_signal_layout() {
	pt := blobly_net_dbc().lookup(0x100) or { panic('no Powertrain') }
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
	pt := blobly_net_dbc().lookup(0x100) or { panic('no Powertrain') }
	gear := pt.signals[4]
	assert gear.name == 'Gear'
	assert gear.values[3] == 'Third'
	assert gear.values[0] == 'Neutral'
	cruise := pt.signals[5]
	assert cruise.values[1] == 'On'
	assert cruise.values[0] == 'Off'
}

fn test_dbc_comments() {
	pt := blobly_net_dbc().lookup(0x100) or { panic('no Powertrain') }
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

fn test_multiplexing_parse_and_select() {
	// A message with a multiplexor switch (Mode) and two multiplexed signals that
	// share the same bits but only appear for their selector value.
	text := 'BO_ 400 Mux: 8 SUT\n' +
		' SG_ Mode M : 0|8@1+ (1,0) [0|255] "" Tester\n' + ' SG_ TempA m0 : 8|16@1+ (0.1,0) [0|0] "degC" Tester\n' + ' SG_ PressB m1 : 8|16@1+ (0.5,0) [0|0] "kPa" Tester\n'
	m := (parse_dbc(text) or { panic(err) }).lookup(400) or { panic('no msg') }
	assert m.multiplexor_index() == 0
	assert m.signals[0].is_multiplexor
	assert m.signals[1].is_multiplexed && m.signals[1].multiplexor_value == 0
	assert m.signals[2].is_multiplexed && m.signals[2].multiplexor_value == 1

	// Mode=0 -> Mode + TempA present, PressB hidden.
	mut d0 := []u8{len: 8}
	m.signals[0].encode(mut d0, 0)
	m.signals[1].encode(mut d0, 12.5)
	active0 := m.active_signals(d0)
	assert active0.len == 2
	assert active0[0].name == 'Mode' && active0[1].name == 'TempA'

	// Mode=1 -> Mode + PressB present, TempA hidden.
	mut d1 := []u8{len: 8}
	m.signals[0].encode(mut d1, 1)
	m.signals[2].encode(mut d1, 50.0)
	active1 := m.active_signals(d1)
	assert active1.len == 2
	assert active1[1].name == 'PressB'
	assert active1[1].physical(d1) == 50.0
}

fn test_extended_mux_marker() {
	// 'm0M' = a signal that is both multiplexed (selector 0) and itself a switch.
	text := 'BO_ 401 ExtMux: 8 SUT\n SG_ Sub m0M : 0|8@1+ (1,0) [0|255] "" Tester\n'
	m := (parse_dbc(text) or { panic(err) }).lookup(401) or { panic('no msg') }
	s := m.signals[0]
	assert s.is_multiplexed && s.multiplexor_value == 0
	assert s.is_multiplexor
}

fn test_non_multiplexed_returns_all() {
	// blobly_net.dbc is not multiplexed: active_signals == all signals.
	pt := blobly_net_dbc().lookup(0x100) or { panic('no Powertrain') }
	assert pt.multiplexor_index() == -1
	assert pt.active_signals([]u8{len: 8}).len == pt.signals.len
}

fn test_dbc_decode_roundtrip_and_label() {
	pt := blobly_net_dbc().lookup(0x100) or { panic('no Powertrain') }
	mut data := []u8{len: 8}
	pt.signals[0].encode(mut data, 2000.0) // EngineSpeed
	pt.signals[1].encode(mut data, 88.0) // VehicleSpeed
	pt.signals[4].encode(mut data, 3.0) // Gear
	assert pt.signals[0].physical(data) == 2000.0
	assert pt.signals[1].physical(data) == 88.0
	assert pt.signals[4].label(data) == 'Third'
}

// BO_TX_BU_ declares ADDITIONAL transmitters for a message whose BO_ line names one. Ignoring
// the record meant the database stated that a node sends a message and the parser did not know
// — a wrong answer to "who sends this?", which is the question the rest-bus subtraction asks.
fn test_additional_transmitters_are_parsed() {
	src := 'VERSION ""\n\nBU_: ECM TCM SUT_ECU\n\nBO_ 256 Shared: 8 ECM\n SG_ A : 0|8@1+ (1,0) [0|255] "" TCM\n\nBO_TX_BU_ 256 : TCM,SUT_ECU;\n'
	db := parse_dbc(src) or {
		assert false, '${err}'
		return
	}
	m := db.lookup(256) or {
		assert false, 'message missing'
		return
	}
	assert m.sender == 'ECM', 'the BO_ transmitter is still the primary one'
	assert m.tx_nodes == ['TCM', 'SUT_ECU']
	// senders() is the question callers actually ask: every node that transmits it
	s := m.senders()
	assert s == ['ECM', 'TCM', 'SUT_ECU'], 'got ${s}'
}

// A message with no BO_TX_BU_ record reports exactly its BO_ transmitter, and the placeholder
// for "no transmitter" is not a node name.
fn test_senders_without_the_record() {
	src := 'VERSION ""\n\nBU_: ECM\n\nBO_ 300 Plain: 8 ECM\n SG_ A : 0|8@1+ (1,0) [0|255] "" Vector__XXX\n\nBO_ 301 Orphan: 8 Vector__XXX\n SG_ B : 0|8@1+ (1,0) [0|255] "" ECM\n'
	db := parse_dbc(src) or {
		assert false, '${err}'
		return
	}
	plain := db.lookup(300) or { return }
	assert plain.senders() == ['ECM']
	orphan := db.lookup(301) or { return }
	assert orphan.senders() == [], 'Vector__XXX is not a transmitter'
	// receivers: the SG_ list, with the placeholder normalised away, and written back sorted
	assert plain.signals[0].receivers == []
	assert orphan.signals[0].receivers == ['ECM']
	assert db.to_dbc().contains(' SG_ B : 0|8@1+ (1,0) [0|255] "" ECM')
	assert db.to_dbc().contains(' SG_ A : 0|8@1+ (1,0) [0|255] "" Vector__XXX')
}

// `BA_ "VFrameFormat" … J1939PG` is the only thing in a DBC that says a frame is J1939, and it
// is what the self-sent `verify:` notice needs before it will match on a PGN (#289). Both
// spellings, because an ENUM attribute's value in a BA_ record is the enum INDEX — 3 in Vector's
// ordering, which this repo's own ARXML export emits — but tools do write the quoted choice.
fn test_vframeformat_declares_j1939_in_either_spelling() {
	base := 'BO_ 2566844160 EEC1: 8 Ecu\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" Tester\n'
	for value in ['3', '"J1939PG"'] {
		db := candb.parse_dbc(base + 'BA_ "VFrameFormat" BO_ 2566844160 ${value};\n') or {
			assert false, err.msg()
			return
		}
		assert db.messages.len == 1
		assert db.messages[0].j1939, 'VFrameFormat ${value} must declare J1939'
	}
}

// Every other value of the attribute means NOT J1939 — and so does its absence, which is the
// common case: most J1939 databases carry no such attribute at all.
fn test_anything_but_j1939pg_leaves_the_frame_undeclared() {
	base := 'BO_ 2566844160 EEC1: 8 Ecu\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" Tester\n'
	no_attr := candb.parse_dbc(base) or {
		assert false, err.msg()
		return
	}
	assert !no_attr.messages[0].j1939, 'absence is not a declaration'

	// 0 StandardCAN, 1 ExtendedCAN, 14/15 the CAN-FD entries
	for value in ['0', '1', '14', '15', '"StandardCAN"', '"ExtendedCAN_FD"'] {
		db := candb.parse_dbc(base + 'BA_ "VFrameFormat" BO_ 2566844160 ${value};\n') or {
			assert false, err.msg()
			return
		}
		assert !db.messages[0].j1939, 'VFrameFormat ${value} is not J1939'
	}
}

// A malformed or unmatched record must not panic or claim anything.
fn test_a_broken_vframeformat_record_is_ignored() {
	base := 'BO_ 2566844160 EEC1: 8 Ecu\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" Tester\n'
	for line in ['BA_ "VFrameFormat" BO_ 2566844160;\n', 'BA_ "VFrameFormat";\n',
		'BA_ "VFrameFormat" SG_ 2566844160 3;\n', 'BA_ "VFrameFormat" BO_ 999 3;\n'] {
		db := candb.parse_dbc(base + line) or {
			assert false, '${line}: ${err.msg()}'
			return
		}
		assert db.messages.len == 1
		assert !db.messages[0].j1939, 'must not declare from: ${line}'
	}
}

// A DBC states an attribute's default once and overrides only the exceptions, so a J1939 database
// can declare J1939PG file-wide and carry no per-message record at all. Read as "no declaration",
// every frame in such a file came back not-J1939 (codex on #289).
fn test_the_file_wide_default_declares_j1939() {
	base := 'BO_ 2566844160 EEC1: 8 Ecu\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" Tester\n'
	db := candb.parse_dbc(base + 'BA_DEF_DEF_ "VFrameFormat" "J1939PG";\n') or {
		assert false, err.msg()
		return
	}
	assert db.messages[0].j1939, 'the file-wide default is a declaration'

	// …and a per-message record OVERRIDES it, in both directions
	back := candb.parse_dbc(base + 'BA_DEF_DEF_ "VFrameFormat" "J1939PG";\n' +
		'BA_ "VFrameFormat" BO_ 2566844160 0;\n') or {
		assert false, err.msg()
		return
	}
	assert !back.messages[0].j1939, 'an explicit StandardCAN beats the default'

	up := candb.parse_dbc(base + 'BA_DEF_DEF_ "VFrameFormat" "StandardCAN";\n' +
		'BA_ "VFrameFormat" BO_ 2566844160 3;\n') or {
		assert false, err.msg()
		return
	}
	assert up.messages[0].j1939, 'an explicit J1939PG beats the default'
}

// THE DECLARATION MUST SURVIVE A SAVE. The DBC editor writes through the canonical writer, and a
// declaration the parser reads but the writer drops is one a round trip silently deletes — which
// would disable the PGN matching it now gates on reload (codex on #289).
fn test_j1939_survives_a_write_and_reparse() {
	base := 'BO_ 2566844160 EEC1: 8 Ecu\n SG_ Speed : 0|16@1+ (1,0) [0|65535] "" Tester\n' +
		'BO_ 256 Plain: 8 Ecu\n SG_ X : 0|8@1+ (1,0) [0|255] "" Tester\n'
	db := candb.parse_dbc(base + 'BA_ "VFrameFormat" BO_ 2566844160 3;\n') or {
		assert false, err.msg()
		return
	}
	round := candb.parse_dbc(db.to_dbc()) or {
		assert false, 'reparse: ${err.msg()}'
		return
	}
	mut seen := 0
	for m in round.messages {
		if m.name == 'EEC1' {
			assert m.j1939, 'the declaration must survive a Save'
			seen++
		}
		if m.name == 'Plain' {
			assert !m.j1939, 'a frame that never declared it must not gain it'
			seen++
		}
	}
	assert seen == 2, 'both messages must survive'
	// one definition only — two emitters of one attribute would write two BA_DEF_ lines
	assert db.to_dbc().count('BA_DEF_ BO_ "VFrameFormat"') == 1
}

// The VFrameFormat definition's default is "StandardCAN", so emitting an override only for the
// J1939 frames leaves an ordinary 29-bit message inheriting a format that contradicts its own
// BO_ id. The ARXML exporter states a value for every frame for exactly this reason (codex #289).
fn test_an_extended_frame_is_not_left_at_the_standard_default() {
	src := 'BO_ 2566844160 EEC1: 8 Ecu\n SG_ A : 0|8@1+ (1,0) [0|255] "" Tester\n' +
		'BO_ 2147483904 PlainExt: 8 Ecu\n SG_ B : 0|8@1+ (1,0) [0|255] "" Tester\n' +
		'BO_ 256 PlainStd: 8 Ecu\n SG_ C : 0|8@1+ (1,0) [0|255] "" Tester\n' +
		'BA_ "VFrameFormat" BO_ 2566844160 3;\n'
	db := candb.parse_dbc(src) or {
		assert false, err.msg()
		return
	}
	out := db.to_dbc()
	assert out.contains('BA_ "VFrameFormat" BO_ 2566844160 3;'), 'the J1939 frame keeps its index'
	assert out.contains('BA_ "VFrameFormat" BO_ 2147483904 1;'), 'an ordinary extended frame must say ExtendedCAN'
	// a standard frame IS the default and needs no override
	assert !out.contains('BA_ "VFrameFormat" BO_ 256 '), 'a standard frame needs no override'

	// and the round trip still agrees about which one is J1939
	round := candb.parse_dbc(out) or {
		assert false, 'reparse: ${err.msg()}'
		return
	}
	for m in round.messages {
		assert m.j1939 == (m.name == 'EEC1'), '${m.name} j1939=${m.j1939}'
	}
}

// A purely standard-CAN database gains nothing from the attribute and must not grow one.
fn test_a_standard_only_database_emits_no_frame_format() {
	db := candb.parse_dbc('BO_ 256 Plain: 8 Ecu\n SG_ C : 0|8@1+ (1,0) [0|255] "" Tester\n') or {
		assert false, err.msg()
		return
	}
	assert !db.to_dbc().contains('VFrameFormat')
}

// THE FILE DECIDES WHAT ITS INDICES MEAN. A `BA_` record carries the enum INDEX, and a DBC that
// declares its own ordering means that ordering — read against Vector's, an explicitly J1939 file
// was silently undeclared, and an unrelated choice at Vector's index 3 was read AS J1939
// (codex on #289).
fn test_vframeformat_indices_resolve_through_the_files_own_enum() {
	base := 'BO_ 2566844160 EEC1: 8 Ecu\n SG_ A : 0|8@1+ (1,0) [0|255] "" Tester\n'
	short := 'BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","J1939PG";\n'

	// index 2 IS J1939PG in this file
	yes := candb.parse_dbc(base + short + 'BA_ "VFrameFormat" BO_ 2566844160 2;\n') or {
		assert false, err.msg()
		return
	}
	assert yes.messages[0].j1939, 'index 2 is J1939PG in this file'

	// …and Vector's 3 is not a choice here at all
	no := candb.parse_dbc(base + short + 'BA_ "VFrameFormat" BO_ 2566844160 3;\n') or {
		assert false, err.msg()
		return
	}
	assert !no.messages[0].j1939, 'index 3 is not J1939PG in this file'

	// an enum that never lists J1939PG: no index can mean it
	without := 'BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN";\n'
	none_db := candb.parse_dbc(base + without + 'BA_ "VFrameFormat" BO_ 2566844160 1;\n') or {
		assert false, err.msg()
		return
	}
	assert !none_db.messages[0].j1939

	// the quoted choice needs no ordering at all
	quoted := candb.parse_dbc(base + without + 'BA_ "VFrameFormat" BO_ 2566844160 "J1939PG";\n') or {
		assert false, err.msg()
		return
	}
	assert quoted.messages[0].j1939, 'the name is unambiguous whatever the enum says'
}

// The definition may follow the records it governs — a DBC does not promise the order — so the
// resolution happens after the whole file has been read.
fn test_the_enum_definition_may_come_after_the_records() {
	base := 'BO_ 2566844160 EEC1: 8 Ecu\n SG_ A : 0|8@1+ (1,0) [0|255] "" Tester\n'
	db := candb.parse_dbc(base + 'BA_ "VFrameFormat" BO_ 2566844160 2;\n' +
		'BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","J1939PG";\n') or {
		assert false, err.msg()
		return
	}
	assert db.messages[0].j1939, 'the ordering applies however late it is declared'
}

// A numeric value with NO enum definition is malformed DBC — an attribute's values are
// meaningless without its BA_DEF_. Vector's ordering is applied as a convention to a broken file,
// which is what our own writer and exporter emit.
fn test_a_numeric_value_without_a_definition_falls_back_to_vectors_ordering() {
	base := 'BO_ 2566844160 EEC1: 8 Ecu\n SG_ A : 0|8@1+ (1,0) [0|255] "" Tester\n'
	db := candb.parse_dbc(base + 'BA_ "VFrameFormat" BO_ 2566844160 3;\n') or {
		assert false, err.msg()
		return
	}
	assert db.messages[0].j1939
}
