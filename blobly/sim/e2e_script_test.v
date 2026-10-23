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

// a frame of BrakeStatus the bus stamped at `t_ms` in clock domain `clock` ('' for none)
fn brake_frame(data []u8, t_ms i64, clock string) transport.CanFrame {
	return transport.CanFrame{
		id:        0x301
		data:      data
		hw_ns:     if clock == '' { i64(0) } else { t_ms * 1_000_000 }
		hw_domain: clock
	}
}

const kernel = 'socketcan'

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
		f := brake_frame(d, t, kernel)
		assert r.judge(f) or { panic('not judged') } == .ok
	}
	// the last frame again: its counter repeated
	f1 := brake_frame(sent[3], t + 10, kernel)
	assert r.judge(f1) or { panic('') } == .stalled_ctr
	mut bad := sent[3].clone()
	bad[4] ^= 0xFF
	f2 := brake_frame(bad, t + 20, kernel)
	assert r.judge(f2) or { panic('') } == .bad_crc
	f3 := brake_frame(sent[3][..5], t + 30, kernel)
	assert r.judge(f3) or { panic('') } == .truncated
	// no message of the id, a message with no E2E, a remote frame: no verdict
	assert r.judge(transport.CanFrame{ id: 0x7FF, data: [u8(0)] }) == none
	assert r.judge(transport.CanFrame{ id: 0x302, data: [u8(0), 0] }) == none
	assert r.judge(transport.CanFrame{ id: 0x301, rtr: true }) == none
	assert r.judge(transport.CanFrame{ id: 0x7FF, data: [u8(0)] }) == none, 'the remembered miss changed its answer'
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
	f0 := brake_frame(next(mut st), 0, kernel)
	assert r.judge(f0) or { panic('') } == .ok
	f1 := brake_frame(next(mut st), 100, kernel) // at the limit: not late
	assert r.judge(f1) or { panic('') } == .ok
	d2 := next(mut st)
	f2 := brake_frame(d2, 201, kernel)
	assert r.judge(f2) or { panic('') } == .timeout
	// judged from the late frame on
	f3 := brake_frame(next(mut st), 210, kernel)
	assert r.judge(f3) or { panic('') } == .ok
	// a repeat restarts nothing: the sender is stuck, and stays timed out
	f4 := brake_frame(f3.data, 300, kernel)
	assert r.judge(f4) or { panic('') } == .stalled_ctr
	f5 := brake_frame(f3.data, 311, kernel)
	assert r.judge(f5) or { panic('') } == .timeout
	// a bad CRC is that, however late
	mut bad := next(mut st)
	bad[4] ^= 0xFF
	f6 := brake_frame(bad, 900, kernel)
	assert r.judge(f6) or { panic('') } == .bad_crc
}

// a frame with no stamp (a software bus) says nothing about when it was sent: a reader that
// paused is never read as a sender that stopped, and a valid one ends the gap being measured
fn test_a_frame_without_a_stamp_is_never_late_and_ends_the_gap() {
	db := script_db()
	m := db.message_named('BrakeStatus') or { panic('no BrakeStatus') }
	mut st := E2eStamper{}
	mut next := fn [m] (mut st E2eStamper) []u8 {
		mut d := brake_payload()
		st.stamp(m, mut d) or { panic(err) }
		return d
	}
	mut r := new_e2e_reader(db, [], [])
	for i, at in [i64(0), 500, 1000, 5000] {
		assert r.judge(brake_frame(next(mut st), at, '')) or { panic('') } == .ok, 'frame ${i}'
	}
	// stamped, unstamped, stamped 120 ms after the first: the gap is not measured across it
	mut q := new_e2e_reader(db, [], [])
	assert q.judge(brake_frame(next(mut st), 0, kernel)) or { panic('') } == .ok
	assert q.judge(brake_frame(next(mut st), 60, '')) or { panic('') } == .ok
	assert q.judge(brake_frame(next(mut st), 120, kernel)) or { panic('') } == .ok
	// nor across two clock domains
	assert q.judge(brake_frame(next(mut st), 500, 'bridge:wsl#2')) or { panic('') } == .ok
	assert q.judge(brake_frame(next(mut st), 650, 'bridge:wsl#2')) or { panic('') } == .timeout
}

// a counter the profile never sends (Profile 1's 15) is not new data: the gap runs on across it
fn test_a_reserved_counter_does_not_restart_the_gap() {
	db := script_db()
	m := db.message_named('BrakeStatus') or { panic('no BrakeStatus') }
	mut st := E2eStamper{}
	mut r := new_e2e_reader(db, [], [])
	mut first := brake_payload()
	st.stamp(m, mut first) or { panic(err) }
	assert r.judge(brake_frame(first, 0, kernel)) or { panic('') } == .ok
	mut reserved := brake_payload()
	reserved[5] = 0x0F
	reserved[4] = p01_crc_bytes(reserved, 4, 0x1244, '', 15) or { panic(err) }
	assert r.judge(brake_frame(reserved, 90, kernel)) or { panic('') } == .skipped_ctr
	mut next := brake_payload()
	st.stamp(m, mut next) or { panic(err) }
	assert r.judge(brake_frame(next, 150, kernel)) or { panic('') } == .timeout
}

// the gap is the frames' own stamps, never their placement on the host clock, which an
// improving estimate can move: 150 ms apart on the wire is late, however close they were placed
fn test_the_gap_is_measured_between_raw_stamps() {
	db := script_db()
	m := db.message_named('BrakeStatus') or { panic('no BrakeStatus') }
	mut st := E2eStamper{}
	mut r := new_e2e_reader(db, [], [])
	mut a := brake_payload()
	st.stamp(m, mut a) or { panic(err) }
	mut b := brake_payload()
	st.stamp(m, mut b) or { panic(err) }
	f0 := transport.CanFrame{
		...brake_frame(a, 0, 'bridge:wsl#1')
		placed_ns: 140_000_000
	}
	f1 := transport.CanFrame{
		...brake_frame(b, 150, 'bridge:wsl#1')
		placed_ns: 151_000_000
	}
	assert r.judge(f0) or { panic('') } == .ok
	assert r.judge(f1) or { panic('') } == .timeout
}

// a primitive checksum covers the message's payload, never the padding an FD length rounds a
// 9-byte message up to
fn test_a_primitive_checksum_does_not_cover_fd_padding() {
	db := candb.parse_dbc('BU_: Chassis
BO_ 800 Long: 9 Chassis
 SG_ LongCrc : 0|8@1+ (1,0) [0|255] "" Vector__XXX
 SG_ LongCounter : 8|4@1+ (1,0) [0|15] "" Vector__XXX
 SG_ Value : 16|16@1+ (1,0) [0|65535] "" Vector__XXX
BA_ "E2ECounterSignal" BO_ 800 "LongCounter";
BA_ "E2ECrcSignal" BO_ 800 "LongCrc";
BA_ "E2EProfile" BO_ 800 "crc8_j1850";
') or {
		panic(err)
	}
	m := db.messages[0]
	mut st := E2eStamper{}
	mut r := new_e2e_reader(db, [], [])
	for n in 0 .. 3 {
		mut d := m.template()
		d[2] = u8(0x40 + n)
		st.stamp(m, mut d) or { panic(err) }
		d << [u8(0), 0, 0] // as the wire pads it to 12
		assert r.judge(transport.CanFrame{ id: 800, data: d, fd: true }) or { panic('') } == .ok, 'frame ${n}'
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
	assert brake2.check_at(d, kernel, 0) == .ok
	brake2.e2e.apply(brake2.msg, mut d, 1)
	assert brake2.check_at(d, kernel, 101_000_000) == .timeout, 'the verify: entry lost the message timeout'
	assert receive_checks(candb.Database{}, [], []).by_key.len == 0
}

// the names a script reads, one per verdict
fn test_every_verdict_has_its_own_name() {
	all := [Violation.ok, .truncated, .bad_crc, .stalled_ctr, .skipped_ctr, .timeout]
	names := all.map(it.name())
	assert names == ['ok', 'truncated', 'bad_crc', 'repeated', 'skipped', 'timeout']
	assert Violation.timeout.str() == '!TIMEOUT'
}
