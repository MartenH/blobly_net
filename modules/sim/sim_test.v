module sim

import candb
import transport

// The cantester.dbc, loaded once. @VMODROOT resolves to the repo root regardless
// of CWD. The 'SUT' node's messages drive the reference ECU.
const dbc_path = @VMODROOT + '/dbc/cantester.dbc'

fn load_db() candb.Database {
	return candb.load_dbc_file(dbc_path) or { panic(err) }
}

fn hex(b []u8) string {
	mut s := ''
	for x in b {
		s += '${x:02X}'
	}
	return s
}

// Golden vectors captured from sut/can_sut.py encode_powertrain(t) — the native
// engine must reproduce them byte-for-byte (the verification-against-Python gate).
const powertrain_golden = {
	'0.0': '0019B504390B0000'
	'0.1': 'A41AD0F4E80A0000'
	'0.5': '092110A578090000'
	'1.3': '812BABE407100000'
	'2.7': '412F1132779B0000'
	'5.0': 'C7101501A9320000'
	'9.9': '2027A47168220000'
}

fn powertrain_msg(mut ecu SimEcu) &SimMessage {
	for i := 0; i < ecu.messages.len; i++ {
		if ecu.messages[i].msg.name == 'Powertrain' {
			return &ecu.messages[i]
		}
	}
	panic('no Powertrain message')
}

fn test_powertrain_matches_python_golden() {
	mut ecu := sut_ecu(load_db())
	mut pt := powertrain_msg(mut ecu)
	for ts, want in powertrain_golden {
		got := pt.build(ts.f64())
		assert hex(got.data) == want, 'Powertrain t=${ts}: got ${hex(got.data)} want ${want}'
		assert got.id == 0x100
	}
}

fn test_heartbeat_counter_sequence() {
	mut ecu := sut_ecu(load_db())
	mut hb := &SimMessage(unsafe { nil })
	for i := 0; i < ecu.messages.len; i++ {
		if ecu.messages[i].msg.name == 'Heartbeat' {
			hb = &ecu.messages[i]
		}
	}
	// counter starts at 0 and increments per send (send_n), wrapping at 256.
	for n in 0 .. 5 {
		hb.send_n = n
		f := hb.build(0.0)
		assert f.id == 0x700
		assert f.data == [u8(n)]
	}
	hb.send_n = 257
	assert hb.build(0.0).data == [u8(1)] // 257 % 256
}

fn test_response_rule() {
	ecu := sut_ecu(load_db())
	e := Engine{
		ecus: [ecu]
	}
	req := transport.CanFrame{ id: 0x101, data: [u8(0x41), 0x42, 0x43] }
	resp := e.on_frame(req)
	assert resp.len == 1
	assert resp[0].id == 0x102
	assert resp[0].data == [u8(0x42), 0x42, 0x43] // byte0 +1
	// a non-request frame yields nothing
	assert e.on_frame(transport.CanFrame{ id: 0x100, data: [u8(1)] }).len == 0
}

fn test_due_frames_cyclic_cadence() {
	mut e := Engine{
		ecus: [sut_ecu(load_db())]
	}
	// at t=0 both cyclic messages (Powertrain + Heartbeat, 100ms) are due
	first := e.due_frames(0)
	ids := first.map(it.id)
	assert 0x100 in ids
	assert 0x700 in ids
	assert first.len == 2
	// nothing due again until 100ms
	assert e.due_frames(50).len == 0
	assert e.due_frames(100).len == 2
	assert e.due_frames(150).len == 0
	assert e.due_frames(205).len == 2
}

fn test_generators() {
	assert gen_const(7).value(123, 9) == 7
	// counter wraps
	assert gen_counter(0, 1, 256).value(0, 300) == 44 // 300 % 256
	// stepmod staircase: gear = floor(t)%6 + 1
	assert gen_stepmod(1, 6, 1).value(0.4, 0) == 1
	assert gen_stepmod(1, 6, 1).value(5.9, 0) == 6
	assert gen_stepmod(1, 6, 1).value(6.1, 0) == 1
}
