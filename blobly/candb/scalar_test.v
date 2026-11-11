module candb

import os

// A signal wider than the 64-bit scalar model: it loads, a load note names it, decode leaves it
// out and encode writes nothing into it.

const wide_dbc = '
BO_ 1280 ConfigData: 48 A
 SG_ Mode : 0|8@1+ (1,0) [0|255] "" B
 SG_ Key : 8|128@1+ (1,0) [0|0] "" B
 SG_ Tail : 136|64@1+ (1,0) [0|0] "" B
 SG_ KeyBe : 207|72@0+ (1,0) [0|0] "" B

BO_ 1281 MuxWide: 24 A
 SG_ Sel M : 0|8@1+ (1,0) [0|255] "" B
 SG_ Block m1 : 8|96@1+ (1,0) [0|0] "" B
 SG_ Small m1 : 104|8@1+ (1,0) [0|255] "" B
'

fn wide_db() Database {
	return parse_dbc(wide_dbc) or { panic('parse: ${err}') }
}

fn test_scalar_width_rule() {
	assert Signal{
		name:   'One'
		length: 1
	}.is_scalar()
	assert Signal{
		name:   'Word'
		length: 64
	}.scalar_refusal() == ''
	assert !Signal{
		name:   'None'
		length: 0
	}.is_scalar()
	assert Signal{
		name:   'Key'
		length: 128
	}.scalar_refusal() == 'Key is 128 bits wide: a value is encoded into 1 .. 64'
}

fn test_decode_leaves_a_wide_signal_out() {
	db := wide_db()
	m := db.message_named('ConfigData') or { panic('no ConfigData') }
	data := []u8{len: 48, init: u8(index)}
	assert m.active_signals(data).map(it.name) == ['Mode', 'Tail']
	assert m.carried(data) == [true, false, true, false]
	c := m.carrier('Key') or { panic('no Key') }
	assert !c.carried_by(data)
	mux := db.message_named('MuxWide') or { panic('no MuxWide') }
	mut sel := []u8{len: 24}
	sel[0] = 1
	assert mux.active_signals(sel).map(it.name) == ['Sel', 'Small']
	assert mux.carried(sel) == [true, false, true]
}

fn test_encode_writes_nothing_into_a_wide_signal() {
	db := wide_db()
	m := db.message_named('ConfigData') or { panic('no ConfigData') }
	key := m.signal_named('Key') or { panic('no Key') }
	mut data := []u8{len: 48, init: u8(0xA5)}
	key.encode(mut data, 1.0)
	assert data == []u8{len: 48, init: u8(0xA5)}
	tail := m.signal_named('Tail') or { panic('no Tail') }
	tail.encode(mut data, 7.0)
	assert data[17] == 7
}

fn test_a_wide_signal_is_a_load_note() {
	assert wide_db().scalar_notes() == [
		'ConfigData: signal Key is 128 bits wide, past the 64-bit scalar model — decode leaves it out and encode refuses it',
		'ConfigData: signal KeyBe is 72 bits wide, past the 64-bit scalar model — decode leaves it out and encode refuses it',
		'MuxWide: signal Block is 96 bits wide, past the 64-bit scalar model — decode leaves it out and encode refuses it',
	]
	dir := os.join_path(os.vtmp_dir(), 'scalar_notes_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'wide.dbc')
	os.write_file(path, wide_dbc) or { panic(err) }
	loaded := open_database(path) or { panic(err) }
	assert loaded.notes.len == 3
	assert loaded.notes[0] == 'wide.dbc: ConfigData: signal Key is 128 bits wide, past the 64-bit scalar model — decode leaves it out and encode refuses it'
}
