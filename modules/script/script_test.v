module script

import candb

// a tiny synthetic DBC: Powertrain 0x100 with a 16-bit EngineSpeed @ 0.25 rpm/bit.
fn sample_db() candb.Database {
	return candb.Database{
		messages: [
			candb.Message{
				name: 'Powertrain'
				id:   0x100
				dlc:  8
				signals: [
					candb.Signal{
						name:      'EngineSpeed'
						start_bit: 0
						length:    16
						factor:    0.25
					},
				]
			},
		]
	}
}

fn quiet_env() &Env {
	mut env := new_env([ChanInfo{
		name:  'CAN1'
		iface: 'inproc:UT'
		db:    sample_db()
	}]) or { panic(err) }
	env.on_output = fn (s string) {}
	return env
}

fn test_decode_and_framework() {
	mut env := quiet_env()
	defer { env.close() }
	env.run_source('
		test("decode EngineSpeed", function()
			-- 6400 little-endian (0x1900) * 0.25 = 1600 rpm
			local sig = decode("CAN1", 0x100, string.char(0x00, 0x19))
			check.equal(sig.EngineSpeed, 1600)
		end)
		test("tohex/fromhex round-trip", function()
			check.equal(tohex(fromhex("DE AD BE EF")), "DE AD BE EF")
		end)
		test("u16be helper", function()
			check.equal(u16be(string.char(0x06, 0x40)), 1600)
		end)
		test("a deliberate failure is counted", function()
			check.equal(1, 2, "one is not two")
		end)
	')!
	assert env.total() == 4
	assert env.passed() == 3
	assert env.failed() == 1
}

fn test_nrc_assertion_helper() {
	// check.nrc passes when the wrapped call raises a matching NRC error.
	mut env := quiet_env()
	defer { env.close() }
	env.run_source('
		test("nrc matches", function()
			check.nrc(0x31, function() error("UDS negative response: service 0x22 NRC 0x31 (requestOutOfRange)") end)
		end)
		test("nrc mismatch fails", function()
			check.nrc(0x31, function() error("NRC 0x11 serviceNotSupported") end)
		end)
	')!
	assert env.passed() == 1
	assert env.failed() == 1
}
