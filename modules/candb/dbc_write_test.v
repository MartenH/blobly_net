module candb

// The serializer's contract: everything the parser reads survives a
// write→parse round trip, and the canonical form is a FIXPOINT —
// to_dbc(parse_dbc(to_dbc(db))) == to_dbc(db) — so an editor's save/load
// cycle can never drift a file, and git diffs show real changes only.

// a database exercising every serialized feature: extended + standard ids,
// Intel + Motorola, signed, scaling, ranges, units, value tables, comments,
// multiplexing (switch + selector), nodes, cycle times
fn full_db() Database {
	return Database{
		nodes:    ['ECU_B', 'ECU_A']
		messages: [
			Message{
				name:     'Engine'
				id:       0x100
				dlc:      8
				sender:   'ECU_A'
				cycle_ms: 20
				signals:  [
					Signal{
						name:      'Rpm'
						start_bit: 0
						length:    16
						factor:    0.25
						offset:    0
						maximum:   16383.75
						unit:      'rpm'
						desc:      'crank speed'
					},
					Signal{
						name:      'Temp'
						start_bit: 16
						length:    8
						factor:    1
						offset:    -40
						minimum:   -40
						maximum:   215
						unit:      'degC'
						is_signed: true
					},
					Signal{
						name:       'Gear'
						start_bit:  31
						length:     4
						byte_order: .big_endian
						values:     {
							u64(0): 'N'
							u64(1): 'First'
							u64(2): 'Second'
						}
					},
				]
			},
			Message{
				name:    'Diag'
				id:      0x18FF1234
				ext:     true
				dlc:     8
				signals: [
					Signal{
						name:           'Page'
						start_bit:      0
						length:         4
						is_multiplexor: true
					},
					Signal{
						name:              'Volt'
						start_bit:         8
						length:            8
						factor:            0.1
						is_multiplexed:    true
						multiplexor_value: 2
					},
				]
			},
		]
	}
}

fn test_write_parse_roundtrip_preserves_the_model() {
	db := full_db()
	text := db.to_dbc()
	back := parse_dbc(text) or { panic('reparse failed: ${err}') }

	assert back.nodes == ['ECU_A', 'ECU_B'] // canonical: sorted
	assert back.messages.len == 2

	eng := back.lookup(0x100) or { panic('Engine lost') }
	assert eng.name == 'Engine' && eng.dlc == 8 && eng.sender == 'ECU_A'
	assert eng.cycle_ms == 20
	assert !eng.ext
	assert eng.signals.len == 3
	rpm := eng.signals[0]
	assert rpm.name == 'Rpm' && rpm.length == 16 && rpm.factor == 0.25
	assert rpm.unit == 'rpm' && rpm.desc == 'crank speed'
	temp := eng.signals[1]
	assert temp.is_signed && temp.offset == -40 && temp.minimum == -40
	gear := eng.signals[2]
	assert gear.byte_order == .big_endian
	assert gear.values[u64(1)] == 'First' && gear.values.len == 3

	diag := back.lookup(0x18FF1234) or { panic('Diag lost (ext id / EFF flag)') }
	assert diag.ext
	page := diag.signals[0]
	assert page.is_multiplexor && !page.is_multiplexed
	volt := diag.signals[1]
	assert volt.is_multiplexed && volt.multiplexor_value == 2
	assert volt.factor == 0.1
}

fn test_canonical_form_is_a_fixpoint() {
	db := full_db()
	once := db.to_dbc()
	twice := (parse_dbc(once) or { panic(err) }).to_dbc()
	assert once == twice
}

fn test_message_and_signal_order_is_canonical() {
	// the same content declared in a different order serializes identically
	mut msgs := full_db().messages.reverse()
	shuffled := Database{
		nodes:    ['ECU_A', 'ECU_B']
		messages: msgs
	}
	assert shuffled.to_dbc() == full_db().to_dbc()
}

fn test_embedded_quotes_cannot_corrupt_the_file() {
	db := Database{
		messages: [
			Message{
				name:    'M'
				id:      1
				dlc:     1
				signals: [
					Signal{
						name:      'S'
						start_bit: 0
						length:    8
						unit:      'in"ch'
						desc:      'say "hi"'
					},
				]
			},
		]
	}
	back := parse_dbc(db.to_dbc()) or { panic('quote sanitization failed: ${err}') }
	assert back.messages[0].signals[0].unit == "in'ch"
	assert back.messages[0].signals[0].desc == "say 'hi'"
}

fn test_backslashes_cannot_escape_the_closing_quote() {
	db := Database{
		messages: [
			Message{
				name:    'M'
				id:      1
				dlc:     1
				signals: [
					Signal{
						name:      'S'
						start_bit: 0
						length:    8
						unit:      'V\\'
						desc:      'path C:\\tmp'
					},
				]
			},
		]
	}
	back := parse_dbc(db.to_dbc()) or { panic('backslash sanitization failed: ${err}') }
	assert back.messages[0].signals[0].unit == 'V/'
	assert back.messages[0].signals[0].desc == 'path C:/tmp'
}

// a realistic hand-written file (the blobly_emb bus.dbc shape) reaches the
// fixpoint after ONE canonicalization pass
fn test_external_file_fixpoint() {
	src := 'VERSION ""

BU_: SENSE CTRL

BO_ 256 Powertrain: 8 SENSE
 SG_ EngineSpeed : 0|16@1+ (0.25,0) [0|16383.75] "rpm" Vector__XXX
 SG_ VehicleSpeed : 16|16@1+ (0.01,0) [0|655.35] "km/h" Vector__XXX

BO_ 512 LampFrame: 8 CTRL
 SG_ WarnLamp : 0|1@1+ (1,0) [0|1] "" Vector__XXX

BA_ "GenMsgCycleTime" BO_ 512 100;
VAL_ 512 WarnLamp 0 "Off" 1 "On" ;
'
	db := parse_dbc(src) or { panic(err) }
	once := db.to_dbc()
	twice := (parse_dbc(once) or { panic(err) }).to_dbc()
	assert once == twice
	back := parse_dbc(once) or { panic(err) }
	assert back.messages.len == 2
	lamp := back.lookup(512) or { panic('LampFrame lost') }
	assert lamp.cycle_ms == 100
	assert lamp.signals[0].values[u64(1)] == 'On'
}

fn test_signed_value_table_keys_round_trip() {
	db := Database{
		messages: [
			Message{
				name:    'M'
				id:      1
				dlc:     1
				signals: [
					Signal{
						name:      'Temp'
						start_bit: 0
						length:    8
						is_signed: true
						values:    {
							u64(-1):  'SensorFault'
							u64(0):   'Ok'
							u64(-40): 'Underflow'
						}
					},
				]
			},
		]
	}
	text := db.to_dbc()
	assert text.contains('VAL_ 1 Temp -40 "Underflow" -1 "SensorFault" 0 "Ok" ;'), text
	back := parse_dbc(text) or { panic(err) }
	// canonical keys are WIDTH-SIZED raw patterns: 8-bit -1 is 255, -40 is
	// 216 — exactly what raw_value produces, so label() actually works on a
	// parsed database (it did not before the canonicalization)
	vals := back.messages[0].signals[0].values.clone()
	assert vals[u64(255)] == 'SensorFault'
	assert vals[u64(216)] == 'Underflow'
	assert vals[u64(0)] == 'Ok'
	assert back.messages[0].signals[0].label([u8(255)]) == 'SensorFault'
}

fn test_unsigned_64bit_keys_above_i64_max_round_trip() {
	big := u64(0xFFFF_FFFF_FFFF_FFF0)
	db := Database{
		messages: [
			Message{
				name:    'M'
				id:      1
				dlc:     8
				signals: [
					Signal{
						name:      'Wide'
						start_bit: 0
						length:    64
						values:    {
							big: 'AlmostMax'
						}
					},
				]
			},
		]
	}
	back := parse_dbc(db.to_dbc()) or { panic(err) }
	assert back.messages[0].signals[0].values.clone()[big] == 'AlmostMax'
}

fn test_empty_sender_round_trips() {
	db := Database{
		messages: [
			Message{
				name:    'M'
				id:      1
				dlc:     1
				signals: [
					Signal{
						name:      'S'
						start_bit: 0
						length:    8
					},
				]
			},
		]
	}
	back := parse_dbc(db.to_dbc()) or { panic(err) }
	assert back.messages[0].sender == '' // Vector__XXX normalizes back to none
	assert db.to_dbc() == back.to_dbc()
}

fn test_cycle_time_stays_inside_the_declared_attribute_range() {
	db := Database{
		messages: [
			Message{
				name:     'M'
				id:       1
				dlc:      1
				cycle_ms: 5_000_000 // silly, but the model allows it
				signals:  [
					Signal{
						name:      'S'
						start_bit: 0
						length:    8
					},
				]
			},
		]
	}
	text := db.to_dbc()
	// the declared range stretches to cover the value; the value is VERBATIM
	assert text.contains('BA_DEF_ BO_ "GenMsgCycleTime" INT 0 5000000;')
	assert text.contains('BA_ "GenMsgCycleTime" BO_ 1 5000000;'), text
	back := parse_dbc(text) or { panic(err) }
	assert back.messages[0].cycle_ms == 5_000_000 // round-trip preserved
}

fn test_std_and_ext_frames_sharing_a_number_keep_their_aux_records() {
	db := Database{
		messages: [
			Message{
				name:     'StdFrame'
				id:       0x100
				dlc:      8
				cycle_ms: 10
				signals:  [
					Signal{
						name:      'A'
						start_bit: 0
						length:    8
						desc:      'std side'
						values:    {
							u64(1): 'StdOne'
						}
					},
				]
			},
			Message{
				name:     'ExtFrame'
				id:       0x100
				ext:      true
				dlc:      8
				cycle_ms: 500
				signals:  [
					Signal{
						name:      'B'
						start_bit: 0
						length:    8
						desc:      'ext side'
						values:    {
							u64(2): 'ExtTwo'
						}
					},
				]
			},
		]
	}
	back := parse_dbc(db.to_dbc()) or { panic(err) }
	assert back.messages.len == 2
	mut std_m := Message{}
	mut ext_m := Message{}
	for m in back.messages {
		if m.ext {
			ext_m = m
		} else {
			std_m = m
		}
	}
	assert std_m.cycle_ms == 10 && ext_m.cycle_ms == 500, 'cycle times crossed frames'
	assert std_m.signals[0].desc == 'std side' && ext_m.signals[0].desc == 'ext side'
	assert std_m.signals[0].values[u64(1)] == 'StdOne'
	assert ext_m.signals[0].values[u64(2)] == 'ExtTwo'
	// exact lookup respects the frame kind on the shared numeric id
	l_std := back.lookup_frame(0x100, false) or { panic('std lookup lost') }
	l_ext := back.lookup_frame(0x100, true) or { panic('ext lookup lost') }
	assert !l_std.ext && l_std.name == 'StdFrame'
	assert l_ext.ext && l_ext.name == 'ExtFrame'
}

fn test_line_breaks_cannot_split_records() {
	db := Database{
		messages: [
			Message{
				name:    'M'
				id:      1
				dlc:     1
				signals: [
					Signal{
						name:      'S'
						start_bit: 0
						length:    8
						unit:      'de\ngC'
						desc:      'line one\r\nline two'
						values:    {
							u64(0): 'multi\nline label'
						}
					},
				]
			},
		]
	}
	back := parse_dbc(db.to_dbc()) or { panic('newline sanitization failed: ${err}') }
	s := back.messages[0].signals[0]
	assert s.unit == 'de gC'
	assert s.desc == 'line one  line two'
	assert s.values[u64(0)] == 'multi line label'
}

// The writer must not delete what the parser reads. BO_TX_BU_ declares additional transmitters,
// and a save that dropped them turned a two-sender message into a one-sender message — which is
// exactly the input the rest-bus subtraction uses to decide what NOT to replay at the SUT.
fn test_additional_transmitters_survive_a_round_trip() {
	src := 'VERSION ""\n\nBU_: ECM TCM VCM_C\n\nBO_ 256 Shared: 8 ECM\n SG_ A : 0|8@1+ (1,0) [0|255] "" TCM\n\nBO_TX_BU_ 256 : TCM,VCM_C;\n'
	db := parse_dbc(src) or {
		assert false, '${err}'
		return
	}
	text := db.to_dbc()
	assert text.contains('BO_TX_BU_ 256 : TCM,VCM_C;'), 'the record was dropped on write'
	back := parse_dbc(text) or {
		assert false, 'rewritten file does not parse: ${err}'
		return
	}
	m := back.lookup(256) or {
		assert false, 'message lost'
		return
	}
	assert m.senders() == ['ECM', 'TCM', 'VCM_C'], 'got ${m.senders()}'
}
