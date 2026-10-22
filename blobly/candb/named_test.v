module candb

// The lookups a script and libblobly share: a message by name, a signal by name, the payload an
// encoding starts from, and a frame's message as a position (frame_index, which lookup_frame is).

const named_dbc = '
BO_ 256 Status: 4 A
 SG_ Speed : 0|16@1+ (0.5,0) [0|100] "km/h" B
 SG_ Mode : 16|4@1+ (1,0) [0|15] "" B

BO_ 2147483904 StatusExt: 8 A
 SG_ Level : 0|8@1+ (1,0) [0|255] "" B

BO_ 2364540158 EEC1: 8 A
 SG_ EngineSpeed : 24|16@1+ (0.125,0) [0|8031.875] "rpm" B

BO_ 512 Status: 2 A
 SG_ Other : 0|8@1+ (1,0) [0|255] "" B

BO_ 768 Odd: -1 A

BO_ 1024 Muxed: 3 A
 SG_ Mode M : 0|8@1+ (1,0) [0|255] "" B
 SG_ TempA m0 : 8|16@1+ (0.1,0) [0|0] "degC" B
 SG_ PressB m1 : 8|16@1+ (0.5,0) [0|0] "kPa" B
'

fn named_db() Database {
	return parse_dbc(named_dbc) or { panic('parse: ${err}') }
}

struct FrameCase {
	id   u32
	ext  bool
	want int // the position of the message it decodes as; -1 none
}

fn test_frame_index_is_lookup_frame_by_position() {
	db := named_db()
	cases := [
		FrameCase{0x100, false, 0}, // Status, standard
		FrameCase{0x100, true, 1}, // StatusExt: the same number, the other kind
		FrameCase{0x0CF004FE, true, 2}, // EEC1 exactly
		FrameCase{0x0CF00400, true, 2}, // EEC1 by PGN, another source address
		FrameCase{0x18F00427, true, 2}, // and another priority
		FrameCase{0x0CF004FE, false, -1}, // a standard frame never takes the PGN fallback
		FrameCase{0x200, false, 3}, // the second Status, by its own id
		FrameCase{0x7FF, false, -1},
	]
	for c in cases {
		got := db.frame_index(c.id, c.ext) or { -1 }
		assert got == c.want, 'frame_index(0x${c.id:X}, ${c.ext})'
		if m := db.lookup_frame(c.id, c.ext) {
			assert c.want >= 0 && m.name == db.messages[c.want].name
				&& m.id == db.messages[c.want].id
		} else {
			assert c.want == -1
		}
	}
}

fn test_a_name_is_its_first_message() {
	db := named_db()
	m := db.message_named('Status') or { panic('no Status') }
	assert m.id == 0x100 // the first of the two
	assert db.message_named('status') == none // names are exact
	assert m.signal_named('Mode')?.start_bit == 16
	assert m.signal_named('Other') == none // the second Status's
}

fn test_the_template_is_the_dlc_at_zero() {
	db := named_db()
	assert db.message_named('Status')?.template() == [u8(0), 0, 0, 0]
	assert db.message_named('Odd')?.template() == []u8{} // a negative DLC is none, not a panic
	assert db.message_named('Odd')?.payload_len() == 0
	assert db.message_named('Status')?.payload_len() == 4
	// an encoding is the template with the named signals set, every other at raw 0
	m := db.message_named('Status')?
	mut data := m.template()
	m.signal_named('Speed')?.encode(mut data, 50.0)
	assert data == [u8(100), 0, 0, 0]
}

fn test_carried_is_active_signals_by_position() {
	db := named_db()
	m := db.message_named('Muxed')?
	for mode in [u8(0), 1, 2] {
		data := [mode, 0x10, 0]
		on := m.carried(data)
		assert on == [true, mode == 0, mode == 1]
		mut names := []string{}
		for i, s in m.signals {
			if on[i] {
				names << s.name
			}
		}
		assert names == m.active_signals(data).map(it.name)
	}
	plain := db.message_named('Status')?
	assert plain.carried([]u8{len: 4}) == [true, true]
}

fn test_a_short_payload_carries_only_what_it_holds_whole() {
	db := named_db()
	plain := db.message_named('Status')?
	// Mode is 16|4: a two-byte payload holds Speed whole and none of Mode
	assert plain.carried([u8(1), 2]) == [true, false]
	assert plain.active_signals([u8(1), 2]).map(it.name) == ['Speed']
	assert plain.carrier('Speed')?.carried_by([u8(1), 2])
	assert !plain.carrier('Mode')?.carried_by([u8(1), 2])
	assert plain.carrier('Other') == none
	assert plain.active_signals([u8(1)]) == []
	muxed := db.message_named('Muxed')?
	// the switch held, the selected branch cut short
	assert muxed.carried([u8(0), 0x10]) == [true, false, false]
	// no switch at all: no branch is selected, not branch 0
	assert muxed.carried([]u8{}) == [false, false, false]
	for i, s in muxed.signals {
		c := muxed.carrier(s.name)?
		assert !c.carried_by([]u8{})
		assert c.carried_by([u8(1), 0x10, 0]) == (i != 1)
	}
}
