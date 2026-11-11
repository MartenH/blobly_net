module candb

import os

// A signal wider than the 64-bit scalar model: it loads and carries no number. One that starts on
// a byte boundary and is whole bytes long is read and written as bytes; any other is said in a
// load note, and nothing is read from it or written into it.

const wide_dbc = '
BO_ 1280 ConfigData: 64 A
 SG_ Mode : 0|8@1+ (1,0) [0|255] "" B
 SG_ Key : 8|128@1+ (1,0) [0|0] "" B
 SG_ Tail : 136|64@1+ (1,0) [0|0] "" B
 SG_ KeyBe : 207|72@0+ (1,0) [0|0] "" B
 SG_ Odd : 276|72@1+ (1,0) [0|0] "" B
 SG_ OddBe : 363|72@0+ (1,0) [0|0] "" B

BO_ 1281 MuxWide: 24 A
 SG_ Sel M : 0|8@1+ (1,0) [0|255] "" B
 SG_ Block m1 : 8|96@1+ (1,0) [0|0] "" B
 SG_ Small m1 : 104|8@1+ (1,0) [0|255] "" B
'

fn wide_db() Database {
	return parse_dbc(wide_dbc) or { panic('parse: ${err}') }
}

fn sig_of(db Database, msg string, name string) Signal {
	m := db.message_named(msg) or { panic('no ${msg}') }
	return m.signal_named(name) or { panic('no ${name}') }
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

fn test_signal_kind() {
	db := wide_db()
	kinds := (db.message_named('ConfigData') or { panic('') }).signals.map(it.kind().name())
	assert kinds == ['number', 'bytes', 'number', 'bytes', 'none', 'none']
	// Intel from a byte's bit 0, Motorola from a byte's bit 7, whole bytes, past 64 bits
	assert Signal{
		start_bit: 16
		length:    72
	}.is_bytes()
	assert !Signal{
		start_bit: 16
		length:    68
	}.is_bytes()
	assert !Signal{
		start_bit:  16
		length:     72
		byte_order: .big_endian
	}.is_bytes()
	assert Signal{
		start_bit:  23
		length:     72
		byte_order: .big_endian
	}.is_bytes()
	assert !Signal{
		start_bit: 8
		length:    64
	}.is_bytes()
	assert sig_of(db, 'ConfigData', 'Mode').bytes_refusal() == 'Mode is a number (8 bits), not bytes'
	assert sig_of(db, 'ConfigData', 'Odd').bytes_refusal() == 'Odd is 72 bits wide from bit 276: bytes are read from a signal past 64 bits that starts on a byte boundary and is whole bytes long'
	assert sig_of(db, 'ConfigData', 'Key').bytes_refusal() == ''
}

fn test_decode_carries_numbers_and_bytes_apart() {
	db := wide_db()
	m := db.message_named('ConfigData') or { panic('no ConfigData') }
	data := []u8{len: 64, init: u8(index)}
	assert m.active_signals(data).map(it.name) == ['Mode', 'Tail']
	assert m.carried(data) == [true, false, true, false, false, false]
	assert m.carried_bytes(data) == [false, true, false, true, false, false]
	assert m.byte_signals(data).map(it.name) == ['Key', 'KeyBe']
	c := m.carrier('Key') or { panic('no Key') }
	assert !c.carried_by(data)
	// a payload that holds Key whole and KeyBe not
	assert m.carried_bytes(data[..20]) == [false, true, false, false, false, false]
	mux := db.message_named('MuxWide') or { panic('no MuxWide') }
	mut sel := []u8{len: 24}
	sel[0] = 1
	assert mux.active_signals(sel).map(it.name) == ['Sel', 'Small']
	assert mux.carried(sel) == [true, false, true]
	assert mux.byte_signals(sel).map(it.name) == ['Block']
	sel[0] = 2
	assert mux.byte_signals(sel).len == 0
}

fn test_bytes_are_read_in_payload_order() {
	db := wide_db()
	data := []u8{len: 64, init: u8(index)}
	key := sig_of(db, 'ConfigData', 'Key')
	assert key.bytes_value(data)! == data[1..17]
	be := sig_of(db, 'ConfigData', 'KeyBe')
	assert be.bytes_value(data)! == data[25..34]
	// the same bits read as numbers: Intel little-endian from the first byte, Motorola big-endian
	intel := Signal{
		start_bit: 8
		length:    64
	}
	mut le := u64(0)
	for i in 0 .. 8 {
		le |= u64(data[1 + i]) << (8 * i)
	}
	assert intel.raw_value(data) == le
	moto := Signal{
		start_bit:  207
		length:     64
		byte_order: .big_endian
	}
	mut bev := u64(0)
	for i in 0 .. 8 {
		bev = bev << 8 | u64(data[25 + i])
	}
	assert moto.raw_value(data) == bev
	if _ := be.bytes_value(data[..30]) {
		assert false, 'a payload of 30 bytes holds KeyBe'
	} else {
		assert err.msg() == 'KeyBe is payload bytes 25 .. 33, past a payload of 30'
	}
	if _ := sig_of(db, 'ConfigData', 'Odd').bytes_value(data) {
		assert false, 'Odd read as bytes'
	}
}

fn test_set_bytes() {
	db := wide_db()
	mut data := []u8{len: 64}
	key := sig_of(db, 'ConfigData', 'Key')
	b := []u8{len: 16, init: u8(0xF0 + index)}
	key.set_bytes(mut data, b)!
	assert data[1..17] == b
	assert data[0] == 0 && data[17] == 0
	be := sig_of(db, 'ConfigData', 'KeyBe')
	be.set_bytes(mut data, []u8{len: 9, init: u8(index + 1)})!
	assert be.bytes_value(data)! == []u8{len: 9, init: u8(index + 1)}
	assert data[25] == 1 && data[33] == 9 && data[24] == 0 && data[34] == 0
	key.set_bytes(mut data, []u8{len: 15}) or {
		assert err.msg() == 'Key takes 16 bytes, not 15'
	}
	sig_of(db, 'ConfigData', 'Mode').set_bytes(mut data, [u8(1)]) or {
		assert err.msg() == 'Mode is a number (8 bits), not bytes'
	}
	mut short := []u8{len: 10}
	key.set_bytes(mut short, b) or { assert err.msg().contains('past a payload of 10') }
	assert short == []u8{len: 10}
}

fn test_encode_writes_nothing_into_a_wide_signal() {
	db := wide_db()
	m := db.message_named('ConfigData') or { panic('no ConfigData') }
	key := m.signal_named('Key') or { panic('no Key') }
	mut data := []u8{len: 64, init: u8(0xA5)}
	key.encode(mut data, 1.0)
	assert data == []u8{len: 64, init: u8(0xA5)}
	tail := m.signal_named('Tail') or { panic('no Tail') }
	tail.encode(mut data, 7.0)
	assert data[17] == 7
}

fn test_a_wide_signal_that_is_not_bytes_is_a_load_note() {
	note := 'bits wide, past the 64-bit scalar model and not whole bytes from a byte boundary — decode leaves it out and encode refuses it'
	assert wide_db().scalar_notes() == [
		'ConfigData: signal Odd is 72 ${note}',
		'ConfigData: signal OddBe is 72 ${note}',
	]
	dir := os.join_path(os.vtmp_dir(), 'scalar_notes_${os.getpid()}')
	os.mkdir_all(dir) or { panic(err) }
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'wide.dbc')
	os.write_file(path, wide_dbc) or { panic(err) }
	loaded := open_database(path) or { panic(err) }
	assert loaded.notes.len == 2
	assert loaded.notes[0] == 'wide.dbc: ConfigData: signal Odd is 72 ${note}'
}
