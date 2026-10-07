module script

import isotp
import uds

// "Copy as Lua": the script a recorded session becomes (golden), and that it RUNS — a session
// recorded against the native simulated server, replayed by cmd/script's interpreter against a
// fresh one, passes every test it wrote.

fn ent(seq u64, req []u8, resp []u8) uds.LogEntry {
	neg := resp.len == 3 && resp[0] == 0x7F
	return uds.LogEntry{
		seq:     seq
		clock:   '10:00:00.000'
		target:  'SUT  (0x7E0/0x7E8)'
		key:     'sut'
		outcome: if neg { uds.Outcome.negative } else { uds.Outcome.positive }
		req:     req
		resp:    resp
		nrc:     if neg { resp[2] } else { u8(0) }
	}
}

fn test_golden_script() {
	mut es := [
		uds.LogEntry{
			clock:   '10:00:00.000'
			target:  'SUT  (0x7E0/0x7E8)'
			key:     'sut'
			outcome: .connection
			text:    'opened ISO-TP on inproc:CAN1 (0x7E0/0x7E8)'
		},
		ent(1, [u8(0x10), 0x03], [u8(0x50), 0x03, 0x00, 0x32, 0x01, 0xF4]),
		ent(2, [u8(0x22), 0xF1, 0x90], '\x62\xF1\x90BLOB"LY'.bytes()),
		ent(3, [u8(0x22), 0xF1, 0x95], [u8(0x62), 0xF1, 0x95, 0x01, 0x00]),
		ent(4, [u8(0x22), 0xAB, 0xCD], [u8(0x7F), 0x22, 0x31]),
		ent(5, [u8(0x27), 0x01], [u8(0x67), 0x01, 0x11, 0x22]),
		ent(6, [u8(0x27), 0x02, 0xEE, 0xDD], [u8(0x67), 0x02]),
		ent(7, [u8(0x2E), 0xF1, 0x98, 0x41], [u8(0x6E), 0xF1, 0x98]),
		ent(8, [u8(0x14), 0xFF, 0xFF, 0xFF], [u8(0x54)]),
		ent(9, [u8(0x19), 0x02, 0xFF], [u8(0x59), 0x02, 0xFF]),
		ent(10, [u8(0x3E), 0x80], []u8{}),
		ent(11, [u8(0x31), 0x01, 0x02, 0x03], [u8(0x71), 0x01, 0x02, 0x03, 0x00]),
		ent(12, [u8(0x85), 0x02], [u8(0xC5), 0x02]),
	]
	es[3].pending = 1
	es[3].pending_us = 1500
	es[3].note = 'swVersion = 1.00'
	es << uds.LogEntry{
		seq:     13
		clock:   '10:00:01.000'
		target:  'SUT  (0x7E0/0x7E8)'
		key:     'sut'
		outcome: .no_answer
		req:     [u8(0x22), 0xF1, 0x8C]
		text:    'timeout'
	}
	got := lua_from_log(es, LuaOpts{
		project: '/p/sim-demo.blobnet'
		targets: [
			LuaTarget{
				key:     'sut'
				label:   'SUT  (0x7E0/0x7E8)'
				channel: 'CAN1'
				ids:     true
				tx:      0x7E0
				rx:      0x7E8
			},
		]
	})
	want := '-- Recorded in the blobly_net Diagnostics panel: 13 request(s).
-- Each request is one test, checking the answer the operator saw.
-- @project /p/sim-demo.blobnet

local diag  -- the connection the requests below go to

-- 10:00:00.000  SUT  (0x7E0/0x7E8)  [connection] opened ISO-TP on inproc:CAN1 (0x7E0/0x7E8)
diag = uds.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })  -- SUT  (0x7E0/0x7E8)

test("1: 10 03 Session extended", function()
  check.equal(tohex(diag:session(0x03)), "03 00 32 01 F4")
end)

test("2: 22 F190 ReadDID VIN", function()
  check.equal(diag:read_did(0xF190), "BLOB\\"LY")
end)

test("3: 22 F195 ReadDID supplier ECU software version", function()
  -- answered after 1× 1.5 ms of responsePending (0x78)
  -- swVersion = 1.00
  check.equal(tohex(diag:read_did(0xF195)), "01 00")
end)

test("4: 22 ABCD ReadDID", function()
  check.nrc(0x31, function() diag:read_did(0xABCD) end)
end)

test("5: 27 01 SecurityAccess seed 1 + key", function()
  diag:security_access(1)  -- the seed varies; the key is the reference algorithm (seed XOR FF)
end)

test("7: 2E F198 41 WriteDID repair shop code", function()
  diag:write_did(0xF198, fromhex("41"))
end)

test("8: 14 FFFFFF ClearDTC all", function()
  diag:clear_dtcs()
end)

test("9: 19 02 FF ReadDTC byMask", function()
  check.equal(tohex(diag:read_dtcs(0xFF)), "FF")
end)

test("10: 3E 80 TesterPresent (suppressed)", function()
  check.equal(diag:raw_suppressed(fromhex("3E 00")), false)
end)

test("11: 31 01 0203 Routine", function()
  check.equal(tohex(diag:raw(fromhex("31 01 02 03"))), "71 01 02 03 00")
end)

test("12: 85 02 DTCSetting off", function()
  diag:dtc_setting(false)
end)

-- 22 F18C ReadDID ECU serial number: no answer: timeout — not replayed
'
	assert got == want, got
}

fn test_a_seed_or_a_key_on_its_own_is_not_compared() {
	t := [LuaTarget{
		key:     'sut'
		channel: 'CAN1'
	}]
	seed := lua_from_log([ent(1, [u8(0x27), 0x01], [u8(0x67), 0x01, 0x11, 0x22])], LuaOpts{
		targets: t
	})
	assert seed.contains('  diag:raw(fromhex("27 01"))  -- the seed varies: not compared'), seed
	key := lua_from_log([ent(2, [u8(0x27), 0x02, 0xEE], [u8(0x67), 0x02])], LuaOpts{
		targets: t
	})
	assert key.contains('-- 27 02 EE SecurityAccess key 1: a key without the seed it answered — not replayed'), key
	assert !key.contains('test(')
	// an all-zero seed is "already unlocked": deterministic, so compared
	zero := lua_from_log([ent(3, [u8(0x27), 0x01], [u8(0x67), 0x01, 0x00, 0x00])], LuaOpts{
		targets: t
	})
	assert zero.contains('check.equal(tohex(diag:raw(fromhex("27 01"))), "67 01 00 00")'), zero
}

fn test_unreachable_target_and_no_project_are_said() {
	got := lua_from_log([ent(1, [u8(0x3E), 0x00], [u8(0x7E), 0x00])], LuaOpts{})
	assert got.contains('-- (no project file: run it with --project')
	assert got.contains('-- SUT  (0x7E0/0x7E8): no project channel reaches it')
	assert got.contains('-- 3E 00 TesterPresent: no channel reaches SUT  (0x7E0/0x7E8) — not replayed')
	assert !got.contains('test(')
}

fn test_one_connection_at_a_time_opened_at_its_first_request() {
	mut b := ent(2, [u8(0x3E), 0x00], [u8(0x7E), 0x00])
	b.key = 'gw'
	mut c := ent(3, [u8(0x3E), 0x00], [u8(0x7E), 0x00])
	got := lua_from_log([ent(1, [u8(0x3E), 0x00], [u8(0x7E), 0x00]), b, c], LuaOpts{
		targets: [LuaTarget{
			key:     'sut'
			channel: 'DoIP1'
		}, LuaTarget{
			key:     'gw'
			channel: 'CAN1'
			ids:     true
			tx:      0x18DA10F1
			rx:      0x18DAF110
		}]
	})
	assert got.contains('
local diag  -- the connection the requests below go to

diag = uds.open("DoIP1")

test("1: 3E 00 TesterPresent", function()
  diag:tester_present()
end)

diag:close()  -- the requests move to another target
diag = uds.open("CAN1", { tx = 0x18DA10F1, rx = 0x18DAF110 })

test("2: 3E 00 TesterPresent", function()
  diag:tester_present()
end)

diag:close()  -- the requests move to another target
diag = uds.open("DoIP1")
'), got
	assert !got.contains('diag2')
}

fn test_a_seed_and_key_pair_only_when_adjacent_in_the_log() {
	t := [LuaTarget{
		key:     'sut'
		channel: 'CAN1'
	}]
	seed := ent(5, [u8(0x27), 0x01], [u8(0x67), 0x01, 0x11, 0x22])
	// a selection that skipped what came between: seq 5 and 9 are not one exchange pair
	got := lua_from_log([seed, ent(9, [u8(0x27), 0x02, 0xEE, 0xDD], [u8(0x67), 0x02])], LuaOpts{
		targets: t
	})
	assert !got.contains('security_access'), got
	assert got.contains('diag:raw(fromhex("27 01"))  -- the seed varies: not compared'), got
	assert got.contains('-- 27 02 EE DD SecurityAccess key 1: a key without the seed'), got
	paired := lua_from_log([seed, ent(6, [u8(0x27), 0x02, 0xEE, 0xDD], [u8(0x67), 0x02])], LuaOpts{
		targets: t
	})
	assert paired.contains('diag:security_access(1)'), paired
}

fn test_an_answer_the_panel_could_not_decode_is_compared_raw() {
	mut bad := ent(4, [u8(0x19), 0x02, 0xFF], [u8(0x59), 0x02, 0xFF, 0x12, 0x34])
	bad.failed = true
	bad.note = '0x19 02 FF: 0x19 02 answer of 5 bytes is not a whole number of DTC records'
	got := lua_from_log([bad], LuaOpts{
		targets: [LuaTarget{
			key:     'sut'
			channel: 'CAN1'
		}]
	})
	assert got.contains('test("4: 19 02 FF ReadDTC byMask", function()
  -- 0x19 02 FF: 0x19 02 answer of 5 bytes is not a whole number of DTC records
  check.equal(tohex(diag:raw(fromhex("19 02 FF"))), "59 02 FF 12 34")  -- the answer the panel could not decode, compared as it came
end)'), got
	assert !got.contains('read_dtcs'), 'a helper would raise on the same answer'
}

fn test_a_target_is_reached_by_a_channel_the_script_is_given() {
	// the script's channels: the ENABLED runtime rows only — a disabled CAN1a on inproc:CAN1 is
	// not among them, so the default target on that wire is reached by CAN1b
	chans := [ChanInfo{
		name:      'CAN1b'
		iface:     'inproc:CAN1'
		key_iface: 'inproc:CAN1'
	}, ChanInfo{
		name:      'DoIP1'
		iface:     'doip:127.0.0.1:13400'
		key_iface: 'doip:127.0.0.1:13400'
	}, ChanInfo{
		name:      'PC'
		iface:     'pcan:PCAN_USBBUS1@500000'
		key_iface: 'pcan:PCAN_USBBUS1'
	}]
	assert channel_for('', 'inproc:CAN1', chans) == 'CAN1b'
	assert channel_for('', 'pcan:PCAN_USBBUS1', chans) == 'PC', 'by the logical interface'
	assert channel_for('DoIP1', 'doip:127.0.0.1:13400', chans) == 'DoIP1'
	assert channel_for('CAN1a', 'inproc:CAN1', chans) == '', 'a disabled own channel is not opened'
	assert channel_for('', 'inproc:CAN9', chans) == ''
	assert channel_for('', '', chans) == ''
}

fn test_a_suppressed_request_checks_whether_an_answer_came() {
	t := [LuaTarget{
		key:     'sut'
		channel: 'CAN1'
	}]
	quiet := lua_from_log([ent(1, [u8(0x3E), 0x80], []u8{})], LuaOpts{ targets: t })
	assert quiet.contains('check.equal(diag:raw_suppressed(fromhex("3E 00")), false)'), quiet
	answered := lua_from_log([ent(1, [u8(0x3E), 0x80], [u8(0x7E), 0x00])], LuaOpts{
		targets: t
	})
	assert answered.contains('check.equal(diag:raw_suppressed(fromhex("3E 00")), true)'), answered
	mut owed := ent(1, [u8(0x3E), 0x80], [u8(0x7E), 0x00])
	owed.pending = 1 // the answer after a 0x78 is owed, not "came anyway"
	assert lua_from_log([owed], LuaOpts{ targets: t }).contains(', false)')
}

// serve_recorded is the native simulated server cmd/script hosts on 0x7E0 / 0x7E8, on a channel
// opened BEFORE its thread is spawned, so no request can go out ahead of its subscription.
fn server_channel(iface string) isotp.Channel {
	return isotp.open_software(iface, 0x7E8, 0x7E0, false) or { panic(err) }
}

fn serve_recorded(ch_ isotp.Channel, stop &bool) {
	mut ch := ch_
	mut srv := uds.default_server()
	for !*stop {
		req := ch.recv(20) or { continue }
		resp := srv.handle(req)
		if resp.len > 0 {
			ch.send(resp) or {}
		}
	}
	ch.close()
}

@[heap]
struct Recorded {
mut:
	entries []uds.LogEntry
}

fn test_a_recorded_session_replays_as_a_passing_script() {
	// record: the requests an operator makes, through a client that reports each exchange
	mut stop := false
	t := spawn serve_recorded(server_channel('inproc:RECLUA1'), &stop)
	mut ch := isotp.open_software('inproc:RECLUA1', 0x7E0, 0x7E8, false) or { panic(err) }
	mut rec := &Recorded{}
	mut cli := uds.new_client(ch)
	cli.on_exchange = fn [mut rec] (x uds.Exchange) {
		mut e := uds.entry_of(x)
		e.key = 'sut'
		e.target = 'SUT'
		rec.entries << e
	}
	cli.raw([u8(0x10), 0x03]) or { panic(err) }
	cli.read_data_by_identifier(0xF190) or { panic(err) }
	cli.read_data_by_identifier(0xF195) or { panic(err) }
	cli.read_data_by_identifier(0xABCD) or {}
	seed := cli.security_request_seed(0x01) or { panic(err) }
	cli.security_send_key(0x02, uds.security_key(seed)) or { panic(err) }
	cli.write_data_by_identifier(0xF198, 'BENCH'.bytes()) or { panic(err) }
	cli.read_data_by_identifier(0xF198) or { panic(err) }
	cli.dtc_count(0xFF) or { panic(err) }
	cli.raw([u8(0x19), 0x02, 0xFF]) or { panic(err) }
	cli.clear_dtc(0xFFFFFF) or { panic(err) }
	cli.raw([u8(0x19), 0x02, 0xFF]) or { panic(err) }
	cli.raw_suppressed([u8(0x3E), 0x00]) or { panic(err) }
	cli.raw([u8(0x85), 0x07]) or {} // subFunctionNotSupported
	cli.control_dtc_setting(false) or { panic(err) }
	cli.ecu_reset(0x01) or { panic(err) }
	ch.close()
	stop = true
	t.wait()
	mut l := uds.ExchangeLog{}
	for e in rec.entries {
		l.push(e)
	}
	assert l.entries.len == 16
	src := lua_from_log(l.entries, LuaOpts{
		targets: [LuaTarget{
			key:     'sut'
			channel: 'CAN1'
			ids:     true
			tx:      0x7E0
			rx:      0x7E8
		}]
	})
	// replay: the script against a fresh server, as cmd/script runs it
	mut env := new_env([ChanInfo{
		name:  'CAN1'
		iface: 'inproc:RECLUA2'
	}]) or { panic(err) }
	env.on_output = fn (s string) {}
	defer { env.close() }
	mut stop2 := false
	t2 := spawn serve_recorded(server_channel('inproc:RECLUA2'), &stop2)
	env.run_source(src)!
	stop2 = true
	t2.wait()
	// the seed and its key are one test
	assert env.total() == 15, src
	assert env.passed() == 15, env.results.filter(!it.ok).map(it.msg).str() + '\n' + src
	assert src.contains('check.equal(diag:read_did(0xF198), "BENCH")')
	assert src.contains('check.equal(diag:dtc_count(0xFF), ')
	assert src.contains('check.nrc(0x12, ')
}
