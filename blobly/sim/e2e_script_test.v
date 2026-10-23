module sim

import blobly.candb
import blobly.project
import blobly.transport

// blobly_emb overspeed's BrakeStatus: CRC byte 4, counter in byte 5's low nibble, Data ID
// 0x1244, a 100 ms E2ETimeout; the payload E8 03 5A 00 has the reference's CRCs (e2e_p01_test.v)
const script_dbc = 'BU_: Chassis Tester
BO_ 769 BrakeStatus: 6 Chassis
 SG_ BrakePressure : 0|16@1+ (1,0) [0|65535] "" Tester
 SG_ Pad : 16|8@1+ (1,0) [0|255] "" Tester
 SG_ BrakeCrc : 32|8@1+ (1,0) [0|255] "" Tester
 SG_ BrakeCounter : 40|4@1+ (1,0) [0|15] "" Tester
BO_ 770 Plain: 2 Chassis
 SG_ Value : 0|16@1+ (1,0) [0|65535] "" Tester
BO_ 771 Stamped: 4 Chassis
 SG_ Level : 0|8@1+ (1,0) [0|255] "" Tester
 SG_ LevelCrc : 16|8@1+ (1,0) [0|255] "" Tester
 SG_ LevelCounter : 24|4@1+ (1,0) [0|15] "" Tester
BA_DEF_ BO_ "E2EDataId" INT 0 65535;
BA_DEF_ BO_ "E2ETimeout" INT 0 65535;
BA_ "E2ECounterSignal" BO_ 769 "BrakeCounter";
BA_ "E2ECrcSignal" BO_ 769 "BrakeCrc";
BA_ "E2EProfile" BO_ 769 "P01";
BA_ "E2EDataId" BO_ 769 4676;
BA_ "E2ETimeout" BO_ 769 100;
'

const ref_both = [u8(0xE8), 0xF5, 0xD2, 0xCF, 0x9C, 0x81, 0xA6, 0xBB, 0x00, 0x1D, 0x3A, 0x27, 0x74,
	0x69, 0x4E]

fn script_db() candb.Database {
	return candb.parse_dbc(script_dbc) or { panic(err) }
}

fn brake_payload() []u8 {
	return [u8(0xE8), 0x03, 0x5A, 0x00, 0x00, 0x00]
}

// a frame of BrakeStatus at `t_ms`, stamped by the bus (placed) or timed by its reading
fn brake_frame(data []u8, t_ms i64, by_bus bool) (transport.CanFrame, i64) {
	t := t_ms * 1_000_000
	return transport.CanFrame{
		id:        0x301
		data:      data
		placed_ns: if by_bus { t } else { i64(0) }
	}, t
}

// a send by name carries the declared counter from 0 and the reference CRC, wrapping at 15
fn test_a_send_by_name_is_stamped_as_declared() {
	db := script_db()
	m := db.message_named('BrakeStatus') or { panic('no BrakeStatus') }
	mut st := E2eStamper{}
	for n in 0 .. 17 {
		mut d := brake_payload()
		assert st.stamp(m, mut d) or { panic(err) }
		assert d[5] & 0x0F == u8(n % 15), 'send ${n}'
		assert d[4] == ref_both[n % 15], 'send ${n}'
		assert d[..4] == brake_payload()[..4], 'a signal was overwritten'
	}
	plain := db.message_named('Plain') or { panic('no Plain') }
	mut d := [u8(1), 2]
	assert !(st.stamp(plain, mut d) or { panic(err) }) && d == [u8(1), 2], 'a message with no declaration was stamped'
	// a declaration that cannot be applied is refused, not sent unprotected
	broken := candb.Message{
		...m
		e2e: candb.E2eDecl{
			...m.e2e
			profile: 'P02'
		}
	}
	mut b := brake_payload()
	if _ := st.stamp(broken, mut b) {
		assert false, 'an unknown profile was stamped'
	} else {
		assert err.msg().contains('BrakeStatus declares E2E that cannot be stamped'), err.msg()
	}
	assert b == brake_payload()
}

// what a script reads is judged by the declaration: the stamper's frames pass, and the faults a
// receiver rejects are each named
fn test_a_reader_judges_by_the_declaration() {
	db := script_db()
	m := db.message_named('BrakeStatus') or { panic('no BrakeStatus') }
	mut r := new_e2e_reader(db, [], [])
	assert r.judges() == 1
	mut st := E2eStamper{}
	mut t := i64(0)
	mut sent := [][]u8{}
	for _ in 0 .. 4 {
		mut d := brake_payload()
		st.stamp(m, mut d) or { panic(err) }
		sent << d
		t += 10
		f, at := brake_frame(d, t, true)
		assert r.judge(f, at) or { panic('not judged') } == .ok
	}
	// the last frame again: its counter repeated
	f1, at1 := brake_frame(sent[3], t + 10, true)
	assert r.judge(f1, at1) or { panic('') } == .stalled_ctr
	mut bad := sent[3].clone()
	bad[4] ^= 0xFF
	f2, at2 := brake_frame(bad, t + 20, true)
	assert r.judge(f2, at2) or { panic('') } == .bad_crc
	f3, at3 := brake_frame(sent[3][..5], t + 30, true)
	assert r.judge(f3, at3) or { panic('') } == .truncated
	// no message of the id, a message with no E2E, a remote frame: no verdict
	assert r.judge(transport.CanFrame{ id: 0x7FF, data: [u8(0)] }, 0) == none
	assert r.judge(transport.CanFrame{ id: 0x302, data: [u8(0), 0] }, 0) == none
	assert r.judge(transport.CanFrame{ id: 0x301, rtr: true }, 0) == none
	assert r.judge(transport.CanFrame{ id: 0x7FF, data: [u8(0)] }, 0) == none, 'the remembered miss changed its answer'
}

// E2ETimeout: a frame later than it after the last valid one is `timeout`; a repeat is not a
// valid frame, so a sender stuck on one counter stays timed out
fn test_a_late_frame_is_a_timeout_by_the_bus_time() {
	db := script_db()
	m := db.message_named('BrakeStatus') or { panic('no BrakeStatus') }
	mut r := new_e2e_reader(db, [], [])
	mut st := E2eStamper{}
	mut next := fn [m] (mut st E2eStamper) []u8 {
		mut d := brake_payload()
		st.stamp(m, mut d) or { panic(err) }
		return d
	}
	f0, t0 := brake_frame(next(mut st), 0, true)
	assert r.judge(f0, t0) or { panic('') } == .ok
	f1, t1 := brake_frame(next(mut st), 100, true) // at the limit: not late
	assert r.judge(f1, t1) or { panic('') } == .ok
	d2 := next(mut st)
	f2, t2 := brake_frame(d2, 201, true)
	assert r.judge(f2, t2) or { panic('') } == .timeout
	// judged from the late frame on
	f3, t3 := brake_frame(next(mut st), 210, true)
	assert r.judge(f3, t3) or { panic('') } == .ok
	// a repeat restarts nothing: the sender is stuck, and stays timed out
	f4, t4 := brake_frame(f3.data, 300, true)
	assert r.judge(f4, t4) or { panic('') } == .stalled_ctr
	f5, t5 := brake_frame(f3.data, 311, true)
	assert r.judge(f5, t5) or { panic('') } == .timeout
	// a bad CRC is that, however late
	mut bad := next(mut st)
	bad[4] ^= 0xFF
	f6, t6 := brake_frame(bad, 900, true)
	assert r.judge(f6, t6) or { panic('') } == .bad_crc
}

// a frame timed by its reading (a software bus) says nothing about when it was sent: a reader
// that paused is never read as a sender that stopped
fn test_a_frame_timed_by_its_reading_is_never_late() {
	db := script_db()
	m := db.message_named('BrakeStatus') or { panic('no BrakeStatus') }
	mut r := new_e2e_reader(db, [], [])
	mut st := E2eStamper{}
	for i, at in [i64(0), 500, 1000, 5000] {
		mut d := brake_payload()
		st.stamp(m, mut d) or { panic(err) }
		f, t := brake_frame(d, at, false)
		assert r.judge(f, t) or { panic('') } == .ok, 'frame ${i}'
	}
}

// verify: entry, then the declaration, then a simulated node's protect: — one contract per
// message, each with its message's E2ETimeout
fn test_receive_checks_take_the_contract_in_order() {
	db := script_db()
	stamped := project.ProtectCfg{
		message: 'Stamped'
		counter: 'LevelCounter'
		crc:     'LevelCrc'
		profile: 'crc8_j1850'
	}
	node := project.NodeCfg{
		name:    'Chassis'
		protect: [
			stamped,
			project.ProtectCfg{
				message: 'BrakeStatus'
				counter: 'BrakeCounter'
				crc:     'BrakeCrc'
				profile: 'sum8'
			},
		]
	}
	s := receive_checks(db, [node], [])
	assert s.by_key.len == 2
	brake := s.by_key[vkey(0x301, false)] or { panic('no BrakeStatus') }
	assert brake.e2e.profile == p01, 'a protect: entry overrode the declaration'
	level := s.by_key[vkey(0x303, false)] or { panic('no Stamped') }
	assert level.e2e.profile == 'crc8_j1850'
	// an entry that protects nothing stamps nothing, so there is nothing to judge
	idle := project.NodeCfg{
		name:    'Chassis'
		protect: [project.ProtectCfg{
			message: 'Stamped'
		}]
	}
	assert receive_checks(db, [idle], []).by_key.len == 1, 'an inactive protect: entry was judged'
	verify := [
		project.ProtectCfg{
			message: 'BrakeStatus'
			counter: 'BrakeCounter'
			crc:     'BrakeCrc'
			profile: 'xor8'
		},
	]
	v := receive_checks(db, [node], verify)
	mut brake2 := v.by_key[vkey(0x301, false)] or { panic('no BrakeStatus') }
	assert brake2.e2e.profile == 'xor8', 'the verify: entry did not win'
	// judged by the message's E2ETimeout all the same
	mut d := brake_payload()
	brake2.e2e.apply(brake2.msg, mut d, 0)
	assert brake2.check_at(d, 0, true) == .ok
	brake2.e2e.apply(brake2.msg, mut d, 1)
	assert brake2.check_at(d, 101_000_000, true) == .timeout, 'the verify: entry lost the message timeout'
	assert receive_checks(candb.Database{}, [], []).by_key.len == 0
}

// the names a script reads, one per verdict
fn test_every_verdict_has_its_own_name() {
	all := [Violation.ok, .truncated, .bad_crc, .stalled_ctr, .skipped_ctr, .timeout]
	names := all.map(it.name())
	assert names == ['ok', 'truncated', 'bad_crc', 'repeated', 'skipped', 'timeout']
	assert Violation.timeout.str() == '!TIMEOUT'
}
