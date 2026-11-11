module candb

// The fill of the bits no signal covers (#671): Message.fill_unused and Database.filled.

fn test_fill_sets_only_the_bits_no_signal_covers() {
	db := parse_dbc('BO_ 291 Status: 8 Tester
 SG_ Mode : 0|4@1+ (1,0) [0|15] "" Receiver
')!
	mut m := db.messages[0]
	mut data := m.template()
	m.signal_named('Mode')?.encode(mut data, 5)
	m.fill_unused(mut data)
	assert data == [u8(5), 0, 0, 0, 0, 0, 0, 0], 'a fill of 0 leaves the payload as encoded'
	m.fill = 0xFF
	m.fill_unused(mut data)
	assert data == [u8(0xF5), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
	// a pattern bit for bit: a covered bit keeps its value, an uncovered one takes the pattern's
	m.fill = 0xA0
	mut d2 := m.template()
	m.fill_unused(mut d2)
	assert d2 == [u8(0xA0), 0xA0, 0xA0, 0xA0, 0xA0, 0xA0, 0xA0, 0xA0]
}

fn test_fill_follows_a_big_endian_signal() {
	// Motorola, MSB at bit 7 of byte 0, 12 bits: byte 0 whole and the top nibble of byte 1
	db := parse_dbc('BO_ 1 M: 3 N
 SG_ S : 7|12@0+ (1,0) [0|0] "" X
')!
	mut m := db.messages[0]
	m.fill = 0xFF
	mut data := m.template()
	m.fill_unused(mut data)
	assert data == [u8(0x00), 0x0F, 0xFF]
}

fn test_fill_counts_an_unselected_branch_as_uncovered() {
	db := parse_dbc('BO_ 1 M: 3 N
 SG_ Sw M : 0|4@1+ (1,0) [0|0] "" X
 SG_ A m1 : 8|16@1+ (1,0) [0|0] "" X
 SG_ B m2 : 8|4@1+ (1,0) [0|0] "" X
')!
	mut m := db.messages[0]
	m.fill = 0xFF
	mut d1 := m.template()
	m.signals[0].set_raw(mut d1, 1)
	m.fill_unused(mut d1)
	assert d1 == [u8(0xF1), 0, 0]
	mut d2 := m.template()
	m.signals[0].set_raw(mut d2, 2)
	m.fill_unused(mut d2)
	assert d2 == [u8(0xF2), 0xF0, 0xFF], 'the bits of A the switch does not select are filled'
}

fn test_a_row_fill_replaces_the_message_own() {
	mut db := parse_dbc('BO_ 1 M: 1 N
 SG_ S : 0|1@1+ (1,0) [0|0] "" X
')!
	db.messages[0].fill = 0xAA
	assert db.filled(db.messages[0]).fill == 0xAA, 'no row fill: the message keeps its own'
	row := Database{
		...db
		fill: u8(0x00)
	}
	assert row.filled(row.messages[0]).fill == 0
	assert db.messages[0].fill == 0xAA, 'the shared message is not changed'
}
