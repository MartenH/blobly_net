module sim

import candb

// The published check values for these algorithms: the CRC of the ASCII string '123456789'.
// Pinned because a checksum that is merely self-consistent is worthless — it has to match what
// the ECU on the other end computes, and these constants are how that is verified without one.
fn test_crc_check_values() {
	nine := '123456789'.bytes()
	assert crc8_j1850(nine) == 0x4B // CRC-8/SAE-J1850
	assert crc8_autosar(nine) == 0xDF // CRC-8/AUTOSAR (poly 0x2F)
	assert sum8([u8(0x01), 0x02, 0x03]) == 0x06
	assert xor8([u8(0x0F), 0xF0]) == 0xFF
	assert sum8([u8(0xFF), 0x02]) == 0x01 // wraps at 8 bits, does not saturate
	assert crc8_j1850([]) == 0x00 // init 0xFF ^ final 0xFF
}

// A protected message: 8 bytes, counter in byte 0, CRC in byte 7, payload between.
fn protected_msg() candb.Message {
	return candb.Message{
		name: 'Protected'
		id:   0x123
		dlc:  8
		signals: [
			candb.Signal{
				name:       'AliveCounter'
				start_bit:  0
				length:     4
				byte_order: .little_endian
				factor:     1
			},
			candb.Signal{
				name:       'Payload'
				start_bit:  8
				length:     16
				byte_order: .little_endian
				factor:     1
			},
			candb.Signal{
				name:       'CRC'
				start_bit:  56
				length:     8
				byte_order: .little_endian
				factor:     1
			},
		]
	}
}

fn test_counter_wraps_at_the_signal_width() {
	m := protected_msg()
	e := E2e{ counter: 'AliveCounter' }
	// a 4-bit counter must wrap at 16 — taken from the DBC signal, never configured separately
	for n in [0, 1, 15, 16, 17, 31, 32] {
		mut d := []u8{len: 8}
		e.apply(m, mut d, n)
		assert d[0] & 0x0F == u8(n % 16), 'n=${n} gave ${d[0] & 0x0F}'
	}
}

fn test_crc_covers_the_counter() {
	m := protected_msg()
	e := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	mut a := []u8{len: 8}
	mut b := []u8{len: 8}
	e.apply(m, mut a, 3)
	e.apply(m, mut b, 4)
	// only the counter differs, so a checksum that did not cover it would be identical —
	// which is exactly the hole that lets a stale frame be replayed
	assert a[7] != b[7]
}

fn test_crc_is_independent_of_its_previous_value() {
	m := protected_msg()
	e := E2e{ crc: 'CRC', profile: 'crc8_j1850' }
	mut fresh := []u8{len: 8}
	mut dirty := []u8{len: 8}
	dirty[7] = 0xAA // whatever the last cycle left behind
	e.apply(m, mut fresh, 0)
	e.apply(m, mut dirty, 0)
	assert fresh[7] == dirty[7], 'the CRC field must be zeroed before it is computed'
}

fn test_data_id_changes_the_checksum_without_using_payload() {
	m := protected_msg()
	plain := E2e{ crc: 'CRC', profile: 'crc8_j1850' }
	ided := E2e{ crc: 'CRC', profile: 'crc8_j1850', data_id: 0x2A }
	mut a := []u8{len: 8}
	mut b := []u8{len: 8}
	plain.apply(m, mut a, 0)
	ided.apply(m, mut b, 0)
	assert a[7] != b[7], 'the data id must reach the checksum'
	assert a.len == 8 && b.len == 8, 'the data id must NOT consume payload space'
	assert a[0..7] == b[0..7], 'only the CRC byte may differ'
}

fn test_inactive_e2e_leaves_the_payload_untouched() {
	m := protected_msg()
	e := E2e{}
	assert !e.active()
	mut d := [u8(1), 2, 3, 4, 5, 6, 7, 8]
	e.apply(m, mut d, 99)
	assert d == [u8(1), 2, 3, 4, 5, 6, 7, 8]
}

fn test_unknown_profile_falls_back_rather_than_going_silent() {
	m := protected_msg()
	e := E2e{ crc: 'CRC', profile: 'typo-here' }
	mut d := []u8{len: 8}
	e.apply(m, mut d, 0)
	// a config typo must not stop the frame being built: a wrong checksum is visible on the
	// bus, a message that stopped transmitting looks like a dead simulation
	assert e.checksum_of([u8(1), 2, 3]) == sum8([u8(1), 2, 3])
}

fn test_missing_signal_names_are_ignored() {
	m := protected_msg()
	e := E2e{ counter: 'NoSuchCounter', crc: 'NoSuchCrc', profile: 'crc8_j1850' }
	mut d := []u8{len: 8}
	e.apply(m, mut d, 5) // names that are not in the message must not panic or corrupt
	assert d == []u8{len: 8}
}
