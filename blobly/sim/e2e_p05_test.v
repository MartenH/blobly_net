module sim

import blobly.candb
import blobly.project
import blobly.transport

// AUTOSAR E2E Profile 5, pinned by vectors from an INDEPENDENT implementation — autosar-e2e
// 1.0.0 (sut/e2e_oracle.py regenerates them). Two layouts: the header at byte 0 of an 8-byte
// frame (Data ID 0x1234), and at byte 3 of a 12-byte CAN-FD frame (Data ID 0x0BEE), so the CRC
// covers bytes on both sides of itself. The CRC of each frame at the counters below.
const p05_counters = [0, 1, 2, 3, 127, 128, 254, 255]
const p05_vectors_a = [u16(0x0821), 0x4FF2, 0x8787, 0xC054, 0x61EF, 0xF5A0, 0xDBBD, 0x9C6E]
const p05_vectors_b = [u16(0x8D87), 0x66A4, 0x4BE0, 0xA0C3, 0xBE08, 0x3235, 0xEA99, 0x01BA]
const p05_base_a = [u8(0), 0, 0, 0x11, 0x22, 0x33, 0x44, 0x55]
const p05_base_b = [u8(0xE8), 0x03, 0x5A, 0, 0, 0, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60]

fn le(name string, start int, len int) candb.Signal {
	return candb.Signal{
		name:       name
		start_bit:  start
		length:     len
		byte_order: .little_endian
		factor:     1
	}
}

fn p05_msg_a() candb.Message {
	return candb.Message{
		name:    'EngineData'
		id:      0x120
		dlc:     8
		signals: [le('Crc', 0, 16), le('Ctr', 16, 8), le('Lo', 24, 8), le('Hi', 32, 32)]
	}
}

fn p05_msg_b() candb.Message {
	return candb.Message{
		name:    'Chassis'
		id:      0x130
		dlc:     12
		signals: [le('Head', 0, 24), le('Crc', 24, 16), le('Ctr', 40, 8), le('Tail', 48, 48)]
	}
}

fn p05_e2e(id u32) E2e {
	return E2e{
		counter: 'Ctr'
		crc:     'Crc'
		profile: p05
		data_id: id
	}
}

fn test_crc16_ccitt_false_check_value() {
	assert crc16_ccitt_false('123456789'.bytes()) == 0x29B1
}

fn test_p05_matches_the_reference() {
	for layout in [
		[0x1234, 0, 1],
		[0x0BEE, 3, 2],
	] {
		m := if layout[2] == 1 { p05_msg_a() } else { p05_msg_b() }
		base := if layout[2] == 1 { p05_base_a } else { p05_base_b }
		want := if layout[2] == 1 { p05_vectors_a } else { p05_vectors_b }
		at := layout[1]
		e := p05_e2e(u32(layout[0]))
		for i, ctr in p05_counters {
			// the simulation, a send index that wraps onto the same counter, and the script helper
			for n in [ctr, ctr + 256] {
				mut d := base.clone()
				e.apply(m, mut d, n)
				assert d[at + 2] == u8(ctr)
				got := u16(d[at]) | u16(d[at + 1]) << 8
				assert got == want[i], 'layout ${layout} counter ${ctr}: 0x${got:04X}, the reference says 0x${want[i]:04X}'
			}
			f := p05_protect(base, layout[0], ctr, at) or { panic(err) }
			assert u16(f[at]) | u16(f[at + 1]) << 8 == want[i]
			assert f[at + 2] == u8(ctr)
			assert p05_frame_crc(f, layout[0], at) or { panic(err) } == want[i]
		}
	}
}

fn test_p05_verifier_judges_the_counter_over_0_to_255() {
	m := p05_msg_b()
	mut v := Verifier{
		msg: m
		e2e: p05_e2e(0x0BEE)
	}
	for n in 0 .. 300 { // across a wrap: 255 -> 0 is the next counter, not a skip
		mut d := p05_base_b.clone()
		v.e2e.apply(m, mut d, n)
		assert v.check(d) == .ok, 'frame ${n}'
	}
	mut bad := p05_base_b.clone()
	v.e2e.apply(m, mut bad, 300)
	bad[11] ^= 0x80 // a byte after the header
	assert v.check(bad) == .bad_crc
	mut hi := p05_base_b.clone()
	v.e2e.apply(m, mut hi, 300)
	hi[4] ^= 0x01 // the CRC's HIGH byte alone
	assert v.check(hi) == .bad_crc
	mut same := p05_base_b.clone()
	v.e2e.apply(m, mut same, 299)
	assert v.check(same) == .stalled_ctr
	mut skip := p05_base_b.clone()
	v.e2e.apply(m, mut skip, 302)
	assert v.check(skip) == .skipped_ctr
	// the CRC covers the declared 12 bytes only, not padding a frame is carried with
	mut padded := p05_base_b.clone()
	v.e2e.apply(m, mut padded, 303)
	padded << [u8(0xCC), 0xCC, 0xCC, 0xCC]
	assert v.check(padded) == .ok
}

fn test_p05_refuses_what_it_cannot_stamp() {
	m := p05_msg_a()
	assert p05_problem(m, p05_e2e(0x1234)) == none
	assert autosar_problem(m, p05_e2e(0x1234)) == none
	mut e := p05_e2e(0)
	e.data_id = none
	assert (p05_problem(m, e) or { '' }).contains('needs a data_id')
	assert (p05_problem(m, p05_e2e(0x10000)) or { '' }).contains('16 bits')
	e = p05_e2e(1)
	e.counter = ''
	assert (p05_problem(m, e) or { '' }).contains('counter')
	e = p05_e2e(1)
	e.crc = 'Lo' // 8 bits
	assert (autosar_problem(m, e) or { '' }).contains('16 bits, little-endian')
	e = p05_e2e(1)
	e.counter = 'Lo' // a whole byte, but not the one after the CRC
	assert (p05_problem(m, e) or { '' }).contains('byte after the CRC')
	e = p05_e2e(1)
	e.counter = 'Hi' // 32 bits
	assert (p05_problem(m, e) or { '' }).contains('8-bit byte-aligned counter')
	// a big-endian CRC puts its high byte first, which is not Profile 5's field
	mut be := p05_msg_a()
	be.signals[0] = candb.Signal{
		...be.signals[0]
		byte_order: .big_endian
		start_bit:  7
	}
	assert (p05_problem(be, p05_e2e(1)) or { '' }).contains('little-endian')
	// a 16-bit CRC is Profile 5's width, and only its
	assert declared_problem(m, p05_e2e(1)) == ''
	assert declared_problem(m, E2e{ ...p05_e2e(1), profile: 'crc8_j1850' }).contains('produces 8')
	// a primitive is not Profile 5's to judge
	assert p05_problem(m, E2e{ crc: 'Crc', profile: 'crc8_j1850' }) == none
}

fn test_p05_script_helpers_refuse_what_is_not_profile_5() {
	if _ := p05_protect(p05_base_a, 0x1234, 256, 0) {
		assert false, 'a counter of 256 was stamped'
	}
	if _ := p05_protect(p05_base_a, 0x10000, 1, 0) {
		assert false, 'a 17-bit Data ID was accepted'
	}
	if _ := p05_frame_crc(p05_base_a, 0x1234, 6) {
		assert false, 'a header past the frame was accepted'
	}
	if _ := p05_frame_crc(p05_base_a, 0x1234, -1) {
		assert false, 'a negative offset was accepted'
	}
	// the last place a 3-byte header fits
	assert p05_frame_crc(p05_base_a, 0x1234, 5) or { panic(err) } > 0
}

// a DBC declaring P05 is stamped by its sender with no protect: entry; a valid protect: entry
// draws no warning
fn test_dbc_declared_p05_is_stamped() {
	text := 'BO_ 288 EngineData: 8 Engine
 SG_ Crc : 0|16@1+ (1,0) [0|65535] "" X
 SG_ Ctr : 16|8@1+ (1,0) [0|255] "" X
 SG_ Lo : 24|8@1+ (1,0) [0|255] "" X
 SG_ Hi : 32|32@1+ (1,0) [0|4294967295] "" X
BA_DEF_ BO_ "E2EProfile" STRING;
BA_DEF_ BO_ "E2ECrcSignal" STRING;
BA_DEF_ BO_ "E2ECounterSignal" STRING;
BA_DEF_ BO_ "E2EDataId" INT 0 65535;
BA_ "E2EProfile" BO_ 288 "PROFILE_05";
BA_ "E2ECrcSignal" BO_ 288 "Crc";
BA_ "E2ECounterSignal" BO_ 288 "Ctr";
BA_ "E2EDataId" BO_ 288 4660;
'
	db := candb.parse_dbc(text) or { panic(err) }
	m := db.messages[0]
	e := protection_for(project.NodeCfg{ name: 'Engine' }, m) or { panic('P05 was not stamped') }
	assert e.profile == p05
	mut d := m.template()
	d[3] = 0x11
	d[4] = 0x22
	d[5] = 0x33
	d[6] = 0x44
	d[7] = 0x55
	e.apply(m, mut d, 1)
	assert u16(d[0]) | u16(d[1]) << 8 == p05_vectors_a[1]
	cfg := project.NodeCfg{
		name:    'Engine'
		protect: [project.ProtectCfg{
			message: 'EngineData'
			counter: 'Ctr'
			crc:     'Crc'
			profile: 'autosar_p05'
			data_id: u32(0x1234)
		}]
	}
	assert validate_protection(db, cfg) == []
	// a script's send stamps it and a script's read judges it, across the counter's wrap
	mut st := E2eStamper{}
	mut rd := new_e2e_reader(db, [])
	for n in 0 .. 260 {
		mut f := m.template()
		assert st.stamp(m, mut f) or { panic(err) }
		assert f[2] == u8(n % 256)
		got := rd.judge(transport.CanFrame{ id: m.id, data: f }) or { panic('not judged') }
		assert got == .ok, 'send ${n}: ${got}'
	}
}
