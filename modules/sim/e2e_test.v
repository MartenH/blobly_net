module sim

import candb
import transport
import project

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
	ided := E2e{ crc: 'CRC', profile: 'crc8_j1850', data_id: u32(0x2A) }
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

// A counter or checksum is a RAW field value. If the DBC gives the signal a factor or offset —
// legal, and nothing prevents it — encoding it as a physical quantity would scale it, and the
// receiver would reject every frame while the config looked correct.
fn test_scaled_signals_still_carry_raw_values() {
	m := candb.Message{
		name: 'Scaled'
		id:   0x321
		dlc:  8
		signals: [
			candb.Signal{
				name:       'Cnt'
				start_bit:  0
				length:     8
				byte_order: .little_endian
				factor:     0.5 // a physical encode would write 2n
				offset:     10
			},
			candb.Signal{
				name:       'Chk'
				start_bit:  56
				length:     8
				byte_order: .little_endian
				factor:     2.0 // and would halve the checksum
			},
		]
	}
	e := E2e{ counter: 'Cnt', crc: 'Chk', profile: 'crc8_j1850' }
	mut d := []u8{len: 8}
	e.apply(m, mut d, 7)
	assert d[0] == 7, 'the counter must be the raw value, got ${d[0]}'

	mut expect := []u8{len: 8}
	expect[0] = 7
	assert d[7] == crc8_j1850(expect), 'the checksum must be the raw value'
}

// A request-driven response (period 0) is never seen by due_frames, so its counter only
// advances if on_frame does it. Without that the response repeats counter 0 forever and a
// receiver checking the sequence rejects every one.
fn test_responses_are_protected_and_advance() {
	m := protected_msg()
	mut resp_msg := m
	resp_msg.id = 0x102
	mut ecu := SimEcu{
		name:     'N'
		messages: [SimMessage{
			msg:       resp_msg
			period_ms: 0 // request-driven: due_frames will never touch it
			e2e:       E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
		}]
		rules: [ResponseRule{ req_id: 0x101, resp_id: 0x102, byte_index: 0, add: 1 }]
	}
	mut e := Engine{ ecus: [ecu] }
	req := transport.CanFrame{ id: 0x101, data: []u8{len: 8} }

	a := e.on_frame(req)
	b := e.on_frame(req)
	assert a.len == 1 && b.len == 1
	assert a[0].data[0] & 0x0F == 0, 'first response should carry counter 0'
	assert b[0].data[0] & 0x0F == 1, 'the counter must advance on the response path'
	assert a[0].data[7] != 0, 'the response must carry a checksum'
	assert a[0].data[7] != b[0].data[7], 'and it must cover the counter'
}

// Rebuilding the engine (any ECU checkbox toggled) must not restart counters for ECUs the
// user did not touch.
fn test_counters_survive_a_rebuild() {
	mk := fn () Engine {
		return Engine{
			ecus: [SimEcu{
				name:     'BCM'
				messages: [SimMessage{ msg: protected_msg(), period_ms: 10 }]
			}]
		}
	}
	mut old := mk()
	old.ecus[0].messages[0].send_n = 42

	mut fresh := mk()
	assert fresh.ecus[0].messages[0].send_n == 0
	fresh.adopt_counters(old)
	assert fresh.ecus[0].messages[0].send_n == 42, 'the counter restarted on rebuild'

	// a message that did not exist before starts at zero — it genuinely has not been sent
	mut added := mk()
	added.ecus[0].messages << SimMessage{ msg: candb.Message{ name: 'New', id: 0x999, dlc: 8 } }
	added.adopt_counters(old)
	assert added.ecus[0].messages[1].send_n == 0
}

// The whole data id must reach the checksum: appending only its low byte made ids that differ
// above bit 8 produce identical frames, which is precisely what the field exists to prevent.
fn test_full_data_id_reaches_the_checksum() {
	m := protected_msg()
	a := E2e{ crc: 'CRC', profile: 'crc8_j1850', data_id: u32(0x012A) }
	b := E2e{ crc: 'CRC', profile: 'crc8_j1850', data_id: u32(0x022A) }
	mut da := []u8{len: 8}
	mut db_ := []u8{len: 8}
	a.apply(m, mut da, 0)
	b.apply(m, mut db_, 0)
	assert da[7] != db_[7], 'ids differing above the low byte must not collide'
}

// A request shorter than its response must not truncate the protected reply: set_raw silently
// skips bits past the buffer end, so the frame would go out with no CRC at all while its
// counter advanced — unprotected traffic that looks protected from the sender's side.
fn test_protected_response_uses_the_response_dlc() {
	mut resp_msg := protected_msg() // 8 bytes, CRC in byte 7
	resp_msg.id = 0x102
	mut ecu := SimEcu{
		name:     'N'
		messages: [SimMessage{
			msg:       resp_msg
			period_ms: 0
			e2e:       E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
		}]
		rules: [ResponseRule{ req_id: 0x101, resp_id: 0x102, byte_index: 0, add: 1 }]
	}
	mut e := Engine{ ecus: [ecu] }
	// a 3-byte request against an 8-byte response
	out := e.on_frame(transport.CanFrame{ id: 0x101, data: [u8(0x41), 0x42, 0x43] })
	assert out.len == 1
	assert out[0].data.len == 8, 'the reply must carry the response DLC, got ${out[0].data.len}'
	assert out[0].data[7] != 0, 'the CRC byte is beyond the request length and was skipped'
	assert out[0].data[1] == 0x42 && out[0].data[2] == 0x43, 'request bytes should carry over'
}

// A protect: entry that matches nothing must be REPORTED. Silently doing nothing while the
// panel shows a protection count is the failure mode this feature can least afford.
fn test_validate_protection_catches_names_that_match_nothing() {
	// a synthetic one-node database: SUT sends Protected(0x123) with AliveCounter/Payload/CRC
	db := candb.Database{
		nodes:    ['SUT']
		messages: [candb.Message{
			...protected_msg()
			sender: 'SUT'
		}]
	}
	ok := project.NodeCfg{
		name:    'SUT'
		protect: [project.ProtectCfg{ message: 'Protected', counter: 'AliveCounter', profile: 'crc8_j1850' }]
	}
	assert validate_protection(db, ok).len == 0, '${validate_protection(db, ok)}'

	bad_msg := project.NodeCfg{
		name:    'SUT'
		protect: [project.ProtectCfg{ message: 'Nonexistent', counter: 'Counter' }]
	}
	assert validate_protection(db, bad_msg).len == 1
	assert validate_protection(db, bad_msg)[0].contains('not sent by SUT')

	bad_sig := project.NodeCfg{
		name:    'SUT'
		protect: [project.ProtectCfg{ message: 'Protected', counter: 'NoSuch', crc: 'AlsoNoSuch', profile: 'crc8_j1850' }]
	}
	assert validate_protection(db, bad_sig).len == 2

	bad_profile := project.NodeCfg{
		name:    'SUT'
		protect: [project.ProtectCfg{ message: 'Protected', crc: 'CRC', profile: 'typo' }]
	}
	assert validate_protection(db, bad_profile).len == 1
	assert validate_protection(db, bad_profile)[0].contains('unknown profile')
}

// Two entries for one message: the engine keys protection by message name, so the second
// replaces the first. Splitting counter and crc across entries reads fine and loses one.
fn test_validate_protection_catches_duplicates_and_empty_entries() {
	db := candb.Database{
		nodes:    ['SUT']
		messages: [candb.Message{
			...protected_msg()
			sender: 'SUT'
		}]
	}
	dup := project.NodeCfg{
		name:    'SUT'
		protect: [
			project.ProtectCfg{ message: 'Protected', counter: 'AliveCounter', profile: 'crc8_j1850' },
			project.ProtectCfg{ message: 'Protected', crc: 'CRC', profile: 'crc8_j1850' },
		]
	}
	w := validate_protection(db, dup)
	assert w.len == 1, '${w}'
	assert w[0].contains('more than once')

	empty := project.NodeCfg{
		name:    'SUT'
		protect: [project.ProtectCfg{ message: 'Protected', profile: 'crc8_j1850' }]
	}
	e := validate_protection(db, empty)
	assert e.len == 1, '${e}'
	assert e[0].contains('neither counter nor crc')
}

// One signal used for BOTH fields: apply() writes the counter, zeroes that field to compute
// the checksum, then writes the checksum there. The counter is gone and both name checks pass.
fn test_validate_protection_catches_counter_and_crc_sharing_a_signal() {
	db := candb.Database{
		nodes:    ['SUT']
		messages: [candb.Message{
			...protected_msg()
			sender: 'SUT'
		}]
	}
	same := project.NodeCfg{
		name:    'SUT'
		protect: [project.ProtectCfg{
			message: 'Protected'
			counter: 'CRC'
			crc:     'CRC'
			profile: 'crc8_j1850'
		}]
	}
	w := validate_protection(db, same)
	assert w.len == 1, '${w}'
	assert w[0].contains('overwrites the counter')
}

// An explicitly configured data_id of 0 must round-trip as PRESENT: omitting its four zero
// bytes gives a different checksum, so "0" and "unset" are different configurations.
fn test_zero_data_id_is_preserved_and_changes_the_checksum() {
	m := protected_msg()
	none_id := E2e{ crc: 'CRC', profile: 'crc8_j1850' }
	zero_id := E2e{ crc: 'CRC', profile: 'crc8_j1850', data_id: u32(0) }
	mut a := []u8{len: 8}
	mut b := []u8{len: 8}
	none_id.apply(m, mut a, 0)
	zero_id.apply(m, mut b, 0)
	assert a[7] != b[7], 'an explicit data_id of 0 must contribute its four zero bytes'
}

// An extended response message must be found by the protected-response lookup. ResponseCfg has
// no format field, so the flag is resolved from the DBC — left false, the reply went out as an
// unprotected STANDARD frame while validation reported nothing wrong.
fn test_extended_response_resolves_its_frame_format() {
	mut ext_msg := protected_msg()
	ext_msg.id = 0x102
	ext_msg.ext = true
	ext_msg.name = 'ExtResponse'
	db := candb.Database{
		nodes:    ['SUT']
		messages: [candb.Message{
			...ext_msg
			sender: 'SUT'
		}]
	}
	cfg := project.NodeCfg{
		name:      'SUT'
		responses: [project.ResponseCfg{ request: 0x101, response: 0x102, byte: 0, add: 1 }]
		protect:   [project.ProtectCfg{
			message: 'ExtResponse'
			counter: 'AliveCounter'
			crc:     'CRC'
			profile: 'crc8_j1850'
		}]
	}
	ecu := from_project(db, cfg)
	assert ecu.rules.len == 1
	assert ecu.rules[0].resp_ext, 'the rule must inherit the DBC message format'

	mut e := Engine{ ecus: [ecu] }
	out := e.on_frame(transport.CanFrame{ id: 0x101, data: []u8{len: 8} })
	assert out.len == 1
	assert out[0].extended, 'the reply must go out extended'
	assert out[0].data[7] != 0, 'and it must be protected'
}

// A checksum in an INACTIVE multiplexed branch must not be written: branches may reuse the
// same payload bits, so stamping the wrong one corrupts the branch that is actually present.
fn test_protection_ignores_inactive_multiplex_branches() {
	m := candb.Message{
		name: 'Muxed'
		id:   0x200
		dlc:  8
		signals: [
			candb.Signal{
				name:           'Mux'
				start_bit:      0
				length:         8
				byte_order:     .little_endian
				factor:         1
				is_multiplexor: true
			},
			candb.Signal{
				name:              'CrcA'
				start_bit:         56
				length:            8
				byte_order:        .little_endian
				factor:            1
				is_multiplexed:    true
				multiplexor_value: 0
			},
			candb.Signal{
				name:              'CrcB'
				start_bit:         56 // same bits as CrcA — a legal multiplexed reuse
				length:            8
				byte_order:        .little_endian
				factor:            1
				is_multiplexed:    true
				multiplexor_value: 1
			},
		]
	}
	// payload selects branch 1, but protection names branch 0's checksum
	mut d := []u8{len: 8}
	d[0] = 1
	d[7] = 0x5A // branch B's data, which must survive
	e := E2e{ crc: 'CrcA', profile: 'crc8_j1850' }
	e.apply(m, mut d, 0)
	assert d[7] == 0x5A, 'an inactive branch checksum must not overwrite the active branch'

	// and when its branch IS selected, it is written
	mut d2 := []u8{len: 8}
	d2[0] = 0
	e.apply(m, mut d2, 0)
	assert d2[7] != 0, 'the active branch checksum must be written'
}

// Same numeric id as both a standard and an extended message: the one named by protect: is
// the one meant, and the ambiguity is reported either way.
fn test_ambiguous_response_id_prefers_the_protected_message() {
	mut std_msg := protected_msg()
	std_msg.id = 0x102
	std_msg.name = 'StdResp'
	std_msg.sender = 'SUT'
	mut ext_msg := protected_msg()
	ext_msg.id = 0x102
	ext_msg.name = 'ExtResp'
	ext_msg.ext = true
	ext_msg.sender = 'SUT'
	db := candb.Database{
		nodes:    ['SUT']
		messages: [std_msg, ext_msg] // standard first, so first-match would pick it
	}
	cfg := project.NodeCfg{
		name:      'SUT'
		responses: [project.ResponseCfg{ request: 0x101, response: 0x102, byte: 0, add: 1 }]
		protect:   [project.ProtectCfg{
			message: 'ExtResp'
			counter: 'AliveCounter'
			crc:     'CRC'
			profile: 'crc8_j1850'
		}]
	}
	ecu := from_project(db, cfg)
	assert ecu.rules[0].resp_ext, 'the protected message names the intended format'

	w := validate_protection(db, cfg)
	assert w.any(it.contains('both a standard and an extended')), '${w}'
}

// Configuration that displays and serializes as protection but reaches the wire as nothing.
fn test_validate_protection_catches_inert_configurations() {
	db := candb.Database{
		nodes:    ['SUT']
		messages: [candb.Message{
			...protected_msg()
			sender: 'SUT'
		}]
	}
	// a data id with no checksum to mix it into
	id_only := project.NodeCfg{
		name:    'SUT'
		protect: [project.ProtectCfg{
			message: 'Protected'
			counter: 'AliveCounter'
			data_id: u32(42)
			profile: 'crc8_j1850'
		}]
	}
	w := validate_protection(db, id_only)
	assert w.len == 1, '${w}'
	assert w[0].contains('data_id but no crc')

	// a checksum field that is not 8 bits: every profile produces a u8
	narrow := project.NodeCfg{
		name:    'SUT'
		protect: [project.ProtectCfg{ message: 'Protected', crc: 'AliveCounter', profile: 'crc8_j1850' }]
	}
	n := validate_protection(db, narrow)
	assert n.len == 1, '${n}'
	assert n[0].contains('is 4 bits')
}
