module sim

import candb
import project

// AUTOSAR E2E Profile 1, pinned by vectors from an INDEPENDENT implementation — autosar-e2e
// 1.0.0 (sut/e2e_oracle.py regenerates them) — on blobly_emb overspeed's BrakeStatus layout:
// payload E8 03 5A 00, the CRC in byte 4, the counter in byte 5's low nibble, Data ID 0x1244
// (distinct bytes, so ALT's choice of byte shows), counters 0..14.
const p01_vectors = {
	'both': [u8(0xE8), 0xF5, 0xD2, 0xCF, 0x9C, 0x81, 0xA6, 0xBB, 0x00, 0x1D, 0x3A, 0x27, 0x74,
		0x69, 0x4E]
	'low':  [u8(0x92), 0x8F, 0xA8, 0xB5, 0xE6, 0xFB, 0xDC, 0xC1, 0x7A, 0x67, 0x40, 0x5D, 0x0E,
		0x13, 0x34]
	'alt':  [u8(0x92), 0x42, 0xA8, 0x78, 0xE6, 0x36, 0xDC, 0x0C, 0x7A, 0xAA, 0x40, 0x90, 0x0E,
		0xDE, 0x34]
}

fn brake_status() candb.Message {
	return candb.Message{
		name:    'BrakeStatus'
		id:      0x301
		dlc:     6
		signals: [
			candb.Signal{
				name:       'BrakePressure'
				start_bit:  0
				length:     16
				byte_order: .little_endian
				factor:     1
			},
			candb.Signal{
				name:       'Pad'
				start_bit:  16
				length:     8
				byte_order: .little_endian
				factor:     1
			},
			candb.Signal{
				name:       'BrakeCrc'
				start_bit:  32
				length:     8
				byte_order: .little_endian
				factor:     1
			},
			candb.Signal{
				name:       'BrakeCounter'
				start_bit:  40
				length:     4
				byte_order: .little_endian
				factor:     1
			},
		]
	}
}

fn p01_e2e(mode string) E2e {
	return E2e{
		counter:      'BrakeCounter'
		crc:          'BrakeCrc'
		profile:      p01
		data_id:      u32(0x1244)
		data_id_mode: mode
	}
}

fn test_p01_matches_the_reference_in_every_supported_mode() {
	m := brake_status()
	for mode, want in p01_vectors {
		e := p01_e2e(mode)
		for n in 0 .. 15 {
			mut d := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
			e.apply(m, mut d, n)
			assert d[5] & 0x0F == u8(n)
			assert d[4] == want[n], '${mode} counter ${n}: 0x${d[4]:02X}, the reference says 0x${want[n]:02X}'
		}
	}
	// 'both' is the default mode
	mut a := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
	p01_e2e('').apply(m, mut a, 3)
	assert a[4] == p01_vectors['both'][3]
}

fn test_p01_counter_runs_0_to_14() {
	m := brake_status()
	e := p01_e2e('both')
	for n, want in {
		14: 14
		15: 0
		16: 1
		29: 14
		30: 0
	} {
		mut d := []u8{len: 6}
		e.apply(m, mut d, n)
		assert int(d[5] & 0x0F) == want, 'send ${n}'
	}
}

fn test_p01_verifier_accepts_its_own_frames_and_catches_the_rest() {
	m := brake_status()
	mut v := Verifier{
		msg: m
		e2e: p01_e2e('alt')
	}
	for n in 0 .. 40 { // across two wraps: 14 -> 0 is the next counter, not a skip
		mut d := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
		v.e2e.apply(m, mut d, n)
		assert v.check(d) == .ok, 'frame ${n}'
	}
	mut bad := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
	v.e2e.apply(m, mut bad, 40)
	bad[0] ^= 0x01
	assert v.check(bad) == .bad_crc
	// 15 is never a Profile 1 counter: a frame carrying it, correctly checksummed, is a skip
	mut fifteen := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x0F]
	sig := m.signals[2]
	fifteen[4] = v.e2e.checksum(m, sig, fifteen)
	assert v.check(fifteen) == .skipped_ctr
}

fn test_p01_refuses_what_it_cannot_stamp() {
	m := brake_status()
	assert p01_problem(m, p01_e2e('both')) == none
	mut e := p01_e2e('both')
	e.data_id = none
	assert (p01_problem(m, e) or { '' }).contains('needs a data_id')
	e = p01_e2e('both')
	e.data_id = u32(0x10000)
	assert (p01_problem(m, e) or { '' }).contains('16 bits')
	assert (p01_problem(m, p01_e2e('nibble')) or { '' }).contains('not both, low or alt')
	e = p01_e2e('both')
	e.crc = 'BrakePressure' // 16 bits
	assert (p01_problem(m, e) or { '' }).contains('one whole byte')
	e = p01_e2e('both')
	e.counter = 'Pad' // 8 bits
	assert (p01_problem(m, e) or { '' }).contains('4-bit counter')
	// a primitive is not Profile 1's to judge
	assert p01_problem(m, E2e{ crc: 'BrakePressure', profile: 'crc8_j1850' }) == none
}

fn test_p01_needs_a_counter_and_covers_the_dlc_only() {
	m := brake_status()
	mut e := p01_e2e('alt')
	e.counter = ''
	assert (p01_problem(m, e) or { '' }).contains('counter')
	// a frame carried longer than its DBC length (padding): the CRC covers the 6 declared bytes
	mut d := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
	p01_e2e('both').apply(m, mut d, 0)
	mut padded := d.clone()
	padded << [u8(0xCC), 0xCC]
	mut v := Verifier{
		msg: m
		e2e: p01_e2e('both')
	}
	assert v.check(padded) == .ok
	assert d[4] == p01_vectors['both'][0]
}

fn test_p01_counter_fifteen_is_wrong_even_first() {
	m := brake_status()
	mut v := Verifier{
		msg: m
		e2e: p01_e2e('both')
	}
	mut d := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x0F]
	d[4] = v.e2e.checksum(m, m.signals[2], d)
	assert v.check(d) == .skipped_ctr
}

// a Profile 1 entry that cannot be stamped as specified is said, and not stamped at all; a
// data_id_mode where nothing reads it is said
fn test_p01_problems_are_reported_and_not_stamped() {
	db := candb.Database{
		nodes:    ['Chassis']
		messages: [candb.Message{
			...brake_status()
			sender: 'Chassis'
		}]
	}
	bad := project.NodeCfg{
		name:    'Chassis'
		protect: [project.ProtectCfg{
			message: 'BrakeStatus'
			counter: 'BrakeCounter'
			crc:     'BrakeCrc'
			profile: 'autosar_p01'
		}]
	}
	w := validate_protection(db, bad)
	assert w.any(it.contains('needs a data_id') && it.contains('not applied')), '${w}'
	ecu := from_project(db, bad)
	assert ecu.messages.all(!it.e2e.active()), 'an unstampable Profile 1 entry was applied'
	stray := project.NodeCfg{
		name:    'Chassis'
		protect: [project.ProtectCfg{
			message:      'BrakeStatus'
			counter:      'BrakeCounter'
			crc:          'BrakeCrc'
			profile:      'crc8_j1850'
			data_id_mode: 'alt'
		}]
	}
	assert validate_protection(db, stray).any(it.contains('data_id_mode'))
}

// #271: a node with NO protect: entry stamps what its DBC declares — the reference vector — and a
// protect: entry that differs, or a declaration that cannot be applied, is said
fn test_dbc_declared_e2e_is_stamped_and_checked() {
	mut m := candb.Message{
		...brake_status()
		sender: 'Chassis'
		e2e:    candb.E2eDecl{
			counter:     'BrakeCounter'
			crc:         'BrakeCrc'
			profile:     'autosar_p01'
			data_id:     0x1244
			has_data_id: true
		}
	}
	db := candb.Database{
		nodes:    ['Chassis']
		messages: [m]
	}
	e := declared_e2e(m) or { panic('a usable declaration was refused') }
	mut d := [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
	e.apply(m, mut d, 5)
	assert d[4] == p01_vectors['both'][5]
	ecu := from_project(db, project.NodeCfg{ name: 'Chassis' })
	assert ecu.messages.any(it.msg.name == 'BrakeStatus' && it.e2e.profile == 'autosar_p01')
	differs := project.NodeCfg{
		name:    'Chassis'
		protect: [project.ProtectCfg{
			message: 'BrakeStatus'
			counter: 'BrakeCounter'
			crc:     'BrakeCrc'
			profile: 'autosar_p01'
			data_id: u32(0x99)
		}]
	}
	assert validate_protection(db, differs).any(it.contains('differs from the E2E the DBC declares'))
	m.e2e.data_id = 0x10000 // not a Profile 1 Data ID
	bad := candb.Database{
		nodes:    ['Chassis']
		messages: [m]
	}
	assert declared_e2e(m) == none
	assert validate_protection(bad, project.NodeCfg{ name: 'Chassis' }).any(it.contains('cannot be applied'))
}

// a declaration is applied with no warning, so every shape an entry is warned about is refused;
// an entry overrides the declaration
fn test_declarations_are_exact_and_entries_override_them() {
	base := candb.Message{
		...brake_status()
		sender: 'Chassis'
		e2e:    candb.E2eDecl{
			counter:     'BrakeCounter'
			crc:         'BrakeCrc'
			profile:     'crc8_j1850'
			data_id:     7
			has_data_id: true
		}
	}
	assert declared_e2e(base) != none
	mut same := base
	same.e2e.crc = 'BrakeCounter'
	assert declared_problem(same, e2e_of_decl(same.e2e)).contains('both counter and crc')
	mut wide := base
	wide.e2e.crc = 'BrakePressure'
	assert declared_problem(wide, e2e_of_decl(wide.e2e)).contains('16 bits')
	mut bad := base
	bad.e2e.has_data_id = false
	bad.e2e.bad_data_id = '0x2A'
	assert declared_problem(bad, e2e_of_decl(bad.e2e)).contains('0x2A')
	// protection_for: the declaration, or the node's own entry over it
	assert (protection_for(project.NodeCfg{ name: 'Chassis' }, base) or { E2e{} }).profile == 'crc8_j1850'
	own := project.NodeCfg{
		name:    'Chassis'
		protect: [project.ProtectCfg{
			message: 'BrakeStatus'
			counter: 'BrakeCounter'
			profile: 'crc8_j1850'
		}]
	}
	e := protection_for(own, base) or { panic('the entry was lost') }
	assert e.crc == '', 'the declaration leaked past the entry'
}
