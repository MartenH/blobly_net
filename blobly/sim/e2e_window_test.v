module sim

import blobly.candb
import blobly.project
import blobly.transport

// two signal groups in one frame, each its own Profile 1 window (#615); the torque group's
// receiver holds its sender to a 100 ms E2ETimeout
const group_dbc = 'BU_: Ecu
BO_ 291 EngineData: 8 Ecu
 SG_ Speed_CRC : 0|8@1+ (1,0) [0|255] "" X
 SG_ Speed_Counter : 8|4@1+ (1,0) [0|15] "" X
 SG_ Speed : 16|16@1+ (1,0) [0|65535] "" X
 SG_ Torque_CRC : 32|8@1+ (1,0) [0|255] "" X
 SG_ Torque_Counter : 40|4@1+ (1,0) [0|15] "" X
 SG_ Torque : 48|16@1+ (1,0) [0|65535] "" X
BA_ "E2ECrcSignal" SG_ 291 Speed_CRC "Speed_CRC";
BA_ "E2ECounterSignal" SG_ 291 Speed_CRC "Speed_Counter";
BA_ "E2EProfile" SG_ 291 Speed_CRC "P01";
BA_ "E2EDataId" SG_ 291 Speed_CRC 68;
BA_ "E2ECrcSignal" SG_ 291 Torque_CRC "Torque_CRC";
BA_ "E2ECounterSignal" SG_ 291 Torque_CRC "Torque_Counter";
BA_ "E2EProfile" SG_ 291 Torque_CRC "P01";
BA_ "E2EDataId" SG_ 291 Torque_CRC 69;
BA_ "E2ETimeout" SG_ 291 Torque_CRC 100;
SIG_GROUP_ 291 SpeedGroup 1 : Speed_CRC Speed_Counter Speed;
SIG_GROUP_ 291 TorqueGroup 1 : Torque_CRC Torque_Counter Torque;
'

fn group_db() candb.Database {
	return candb.parse_dbc(group_dbc) or { panic(err) }
}

// p01_window_ok: the CRC at the window's first byte is Profile 1's over the window's bytes alone
fn p01_window_ok(d []u8, at int, id u16) bool {
	w := d[at..at + 4]
	return w[0] == p01_crc_bytes(w, 0, id, '', w[1] & 0x0F) or { return false }
}

fn test_a_declared_group_is_stamped_in_its_own_window() {
	db := group_db()
	ws := declared_e2e(db.messages[0])
	assert ws.len == 2
	assert ws[0].group == 'SpeedGroup' && ws[0].offset == 0 && ws[0].length == 4
	assert ws[1].group == 'TorqueGroup' && ws[1].offset == 4 && ws[1].length == 4
	mut ecu := from_project(db, project.NodeCfg{ name: 'Ecu' })
	mut m := &ecu.messages[0]
	for n in 0 .. 20 {
		f := m.build(0)
		assert f.data[1] & 0x0F == u8(n % 15) && f.data[5] & 0x0F == u8(n % 15), 'send ${n}'
		assert p01_window_ok(f.data, 0, 68) && p01_window_ok(f.data, 4, 69), 'send ${n}'
		m.advance_e2e()
	}
	// over the window, not the frame: the whole-frame CRC is a different byte
	f := m.build(0)
	assert f.data[0] != p01_crc_bytes(f.data, 0, 68, '', f.data[1] & 0x0F) or { 0 }
}

fn test_each_window_is_judged_and_the_frame_reads_the_worst() {
	db := group_db()
	mut st := E2eStamper{}
	mut r := new_e2e_reader(db, [])
	m := db.messages[0]
	for _ in 0 .. 3 {
		mut d := m.template()
		assert st.stamp(m, mut d) or { panic(err) }
		assert r.judge(transport.CanFrame{ id: 291, data: d }) or { panic('not judged') } == .ok
		assert r.last_windows() == [WindowVerdict{'SpeedGroup', .ok},
			WindowVerdict{'TorqueGroup', .ok}]
	}
	mut d := m.template()
	assert st.stamp(m, mut d) or { panic(err) }
	d[4] ^= 0xFF
	assert r.judge(transport.CanFrame{ id: 291, data: d }) or { panic('not judged') } == .bad_crc
	assert r.last_windows() == [WindowVerdict{'SpeedGroup', .ok},
		WindowVerdict{'TorqueGroup', .bad_crc}]
	// a frame of no checked message leaves no window verdicts behind
	assert r.judge(transport.CanFrame{ id: 0x7FF, data: [u8(0)] }) == none
	assert r.last_windows().len == 0
}

fn test_a_window_is_timed_by_its_own_declaration() {
	db := group_db()
	m := db.messages[0]
	mut v := new_verifier(m, declared_e2e(m))
	mut st := E2eStamper{}
	mut a := m.template()
	st.stamp(m, mut a) or { panic(err) }
	assert v.check_at(a, 'k', 0) == .ok
	mut b := m.template()
	st.stamp(m, mut b) or { panic(err) }
	// 150 ms later: past the torque group's 100 ms, and the speed group declares none
	assert v.check_at(b, 'k', 150_000_000) == .timeout
	assert v.last == [Violation.ok, .timeout]
}

fn test_a_fault_acts_on_the_window_it_names() {
	db := group_db()
	t := FaultTarget{
		channel: 'CAN1'
		iface:   'inproc:e2e_window_fault'
		db:      db
		nodes:   [project.NodeCfg{
			name: 'Ecu'
		}]
	}
	defer {
		clear_all()
	}
	t.arm('Ecu', 'EngineData', 'bad_crc', 0, 'TorqueGroup') or { panic(err) }
	f := injected_fault(t.iface, 'Ecu', 'EngineData')
	assert f.kind == .bad_crc && f.group == 'TorqueGroup'
	mut ecu := from_project(db, project.NodeCfg{ name: 'Ecu' })
	mut fr := ecu.messages[0].build(0)
	assert f.apply_post(ecu.messages[0].msg, ecu.messages[0].e2e, mut fr.data)
	assert p01_window_ok(fr.data, 0, 68) && !p01_window_ok(fr.data, 4, 69)
	if _ := t.arm('Ecu', 'EngineData', 'bad_crc', 0, 'Nope') {
		assert false, 'a window the message does not have was armed'
	} else {
		assert err.msg().contains('no E2E window "Nope"') && err.msg().contains('TorqueGroup'), err.msg()
	}
	// a frozen window repeats its counter while the other goes on
	mut m := &ecu.messages[0]
	m.fault = Fault{
		kind:  .freeze_ctr
		group: 'TorqueGroup'
	}
	for n in 0 .. 3 {
		d := m.build(0).data
		assert d[1] & 0x0F == u8(n) && d[5] & 0x0F == 0, 'send ${n}'
		assert p01_window_ok(d, 0, 68) && p01_window_ok(d, 4, 69)
		m.advance_e2e()
	}
	// it resumes one step past what it repeated, across an engine rebuild too
	m.fault = Fault{}
	mut e := Engine{
		ecus: [ecu]
	}
	mut saved := Carry{}
	e.save_state(mut saved)
	mut again := Engine{
		ecus: [from_project(db, project.NodeCfg{ name: 'Ecu' })]
	}
	again.restore_state(saved)
	r := again.ecus[0].messages[0].build(0).data
	assert r[1] & 0x0F == 3 && r[5] & 0x0F == 1
	mut d := m.build(0).data
	assert d[1] & 0x0F == 3 && d[5] & 0x0F == 1
	m.advance_e2e()
	d = m.build(0).data
	assert d[1] & 0x0F == 4 && d[5] & 0x0F == 2
}

// a project's entries, each naming its window: Profile 1 in one, Profile 5 in the other
const mixed_dbc = 'BU_: Ecu
BO_ 292 Mixed: 8 Ecu
 SG_ A_CRC : 0|8@1+ (1,0) [0|255] "" X
 SG_ A_Ctr : 8|4@1+ (1,0) [0|15] "" X
 SG_ A : 16|16@1+ (1,0) [0|65535] "" X
 SG_ B_CRC : 32|16@1+ (1,0) [0|65535] "" X
 SG_ B_Ctr : 48|8@1+ (1,0) [0|255] "" X
 SG_ B : 56|8@1+ (1,0) [0|255] "" X
'

fn mixed_entries() []project.ProtectCfg {
	return [
		project.ProtectCfg{
			message: 'Mixed'
			crc:     'A_CRC'
			counter: 'A_Ctr'
			profile: p01
			data_id: u32(0x44)
			offset:  0
			length:  4
		},
		project.ProtectCfg{
			message: 'Mixed'
			crc:     'B_CRC'
			counter: 'B_Ctr'
			profile: p05
			data_id: u32(0x1234)
			offset:  4
			length:  4
		},
	]
}

fn test_protect_entries_name_their_windows() {
	db := candb.parse_dbc(mixed_dbc) or { panic(err) }
	node := project.NodeCfg{
		name:    'Ecu'
		protect: mixed_entries()
	}
	assert validate_protection(db, node).len == 0, validate_protection(db, node).str()
	ws := protection_for(node, db.messages[0])
	assert ws.map(it.group) == ['A_CRC', 'B_CRC'], 'named by the CRC signal when no group holds it'
	mut ecu := from_project(db, node)
	mut set := verifiers_for(db, [node], [])
	mut v := set.by_key[vkey(292, false)] or { panic('not verified') }
	for n in 0 .. 300 {
		d := ecu.messages[0].build(0).data
		assert p01_window_ok(d, 0, 0x44), 'send ${n}'
		assert u16(d[4]) | u16(d[5]) << 8 == p05_crc_bytes(d[4..8], 0, 0x1234) or { 0 }, 'send ${n}'
		assert d[6] == u8(n % 256)
		assert v.check(d) == .ok, 'send ${n}'
		ecu.messages[0].advance_e2e()
	}
	// the same entries as verify: judge what the node sends
	mut rv := receive_checks(db, mixed_entries())
	mut w := rv.by_key[vkey(292, false)] or { panic('verify: built nothing') }
	assert w.check(ecu.messages[0].build(0).data) == .ok
	assert validate_verify(db, mixed_entries()).len == 0
}

fn test_windows_that_overlap_or_miss_their_fields_are_said() {
	db := candb.parse_dbc(mixed_dbc) or { panic(err) }
	mut over := mixed_entries()
	over[0].length = 5
	node := project.NodeCfg{
		name:    'Ecu'
		protect: over
	}
	assert validate_protection(db, node).any(it.contains('overlaps')), validate_protection(db,
		node).str()
	assert protection_for(node, db.messages[0]).len == 1
	assert validate_verify(db, over).any(it.contains('overlaps the one of A_CRC'))
	// a window that does not hold its CRC is refused, not stamped
	mut miss := mixed_entries()
	miss[1].offset = 5
	miss[1].length = 3
	assert (shape_problem(db.messages[0], e2e_of(miss[1])) or { '' }).contains('is not inside its window')
	assert protection_for(project.NodeCfg{ name: 'Ecu', protect: miss }, db.messages[0]).len == 1
	// several entries where one names no window: the first applies, as before windows
	mut whole := mixed_entries()
	whole[0].offset = none
	whole[0].length = none
	nw := project.NodeCfg{
		name:    'Ecu'
		protect: whole
	}
	assert validate_protection(db, nw).any(it.contains('only the first applies'))
	got := protection_for(nw, db.messages[0])
	assert got.len == 1 && got[0].length == 0
}

// two windows whose CRCs one signal group holds would share its name, which a script reads
// their verdicts and a fault targets them by: the second is refused
fn test_two_windows_of_one_name_are_refused() {
	db := candb.parse_dbc(mixed_dbc + 'SIG_GROUP_ 292 Both 1 : A_CRC B_CRC;\n') or { panic(err) }
	node := project.NodeCfg{
		name:    'Ecu'
		protect: mixed_entries()
	}
	assert protection_for(node, db.messages[0]).map(it.group) == ['Both']
	assert validate_protection(db, node).any(it.contains('named Both, as another one is')), validate_protection(db,
		node).str()
	assert validate_verify(db, mixed_entries()).any(it.contains('named Both, as another one is'))
	v := receive_checks(db, mixed_entries()).by_key[vkey(292, false)] or { panic('not verified') }
	assert v.windows.len == 1
}
