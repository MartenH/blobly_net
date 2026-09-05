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

// doip.listen's `from` option was documented and passed by the prelude while the host ignored it
// (#233): a listener asked for a channel's own port sat on the default. The host now resolves
// it, and refuses what it cannot resolve — the refusals need no socket, so they are pinned here;
// the success path (hearing AltPort on its own port) is tests/doip_announce.lua.
fn test_doip_listen_from_resolves_or_refuses() {
	mut env := new_env([
		ChanInfo{
			name:  'CAN1'
			iface: 'inproc:UT'
			db:    sample_db()
		},
		ChanInfo{
			name:    'Alt'
			iface:   'doip:127.0.0.4:13555'
			carrier: Carrier{
				doip: true
				host: '127.0.0.4'
				port: 13555
			}
		},
	]) or { panic(err) }
	env.on_output = fn (s string) {}
	defer { env.close() }
	env.run_source('
		local function refused(needle, ...)
			local ok, err = pcall(doip.listen, ...)
			check.truthy(not ok, "accepted: " .. tostring(needle))
			check.truthy(string.find(tostring(err), needle, 1, true), "wrong refusal: " .. tostring(err))
		end
		test("an unknown channel is refused by name", function()
			refused(\'unknown channel "Nope"\', 10, { from = "Nope" })
		end)
		test("a CAN channel has no DoIP port to listen on", function()
			refused("is not a DoIP channel", 10, { from = "CAN1" })
		end)
		test("a port that contradicts the channel is refused, not overruled", function()
			local ok, err = pcall(doip.listen, 10, { from = "Alt", port = 13400 })
			check.truthy(not ok, "a contradicting port was accepted")
			-- both ports named, whatever the sentence around them: the operator sees the two answers
			for _, tok in ipairs({ "contradicts", "13400", "13555", "Alt" }) do
				check.truthy(string.find(tostring(err), tok, 1, true), "refusal lacks " .. tok .. ": " .. tostring(err))
			end
		end)
		test("a from that is not a name is refused by the prelude, not read as absent", function()
			refused("from must be a channel name", 10, { from = true })
			refused("from must be a channel name", 10, { from = { channel = "Alt" } })
			refused("from must be a channel name", 10, { from = "" })   -- an unset variable, say
		end)
	')!
	assert env.total() == 4
	assert env.passed() == 4, env.results.filter(!it.ok).map(it.msg).str()
}

// The port rule itself, every branch, without a VM in between.
fn test_listen_port_rule() {
	// no `from`: the request, or the DoIP default
	assert listen_port(0, '', 0)! == 13400
	assert listen_port(13555, '', 0)! == 13555
	// `from`: the channel's port, and a request that agrees is not a contradiction
	assert listen_port(0, 'Alt', 13555)! == 13555
	assert listen_port(13555, 'Alt', 13555)! == 13555
	// a request that disagrees is refused, naming both
	if p := listen_port(13400, 'Alt', 13555) {
		assert false, 'accepted a contradicting port: ${p}'
	} else {
		assert err.msg().contains('contradicts')
		assert err.msg().contains('13400')
		assert err.msg().contains('13555')
	}
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
