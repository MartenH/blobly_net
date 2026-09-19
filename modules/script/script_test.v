module script

import candb
import net
import someip
import testports
import time

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
	assert listen_port(0, '', 0, 13400, 'entity')! == 13400
	assert listen_port(13555, '', 0, 13400, 'entity')! == 13555
	// `from`: the channel's port, and a request that agrees is not a contradiction
	assert listen_port(0, 'Alt', 13555, 13400, 'entity')! == 13555
	assert listen_port(13555, 'Alt', 13555, 13400, 'entity')! == 13555
	// a request that disagrees is refused, naming both
	if p := listen_port(13400, 'Alt', 13555, 13400, 'entity') {
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

// send_someip_after writes datagrams to the listener once its window has opened; the window
// blocks the Lua thread, so the SUT stand-in is this thread.
fn send_someip_after(to string, delay time.Duration, datagrams [][]u8) {
	time.sleep(delay)
	mut s := net.dial_udp(to) or { return }
	defer {
		s.close() or {}
	}
	for d in datagrams {
		s.write(d) or { return }
	}
}

// someip.listen shapes what the host heard into fields a suite can assert on, byte-clean payload
// included, and hands the malformed count back beside them rather than folding it away.
fn test_someip_listen_shapes_messages_and_reports_malformed() {
	port := testports.someip.slot(2, 0)
	mut packed := someip.notification(0x0100, 0x8001, 1, [u8(0x11), 0x22, 0x33])
	packed << someip.request(0x0100, 0x0042, 0x00A5, 0x0001, 1, [u8(0xCA), 0xFE])
	mut env := quiet_env()
	defer { env.close() }
	// Spawned AFTER the env exists (a Lua state, the prelude, an inproc bus) so the delay covers
	// only the run_source compile before the listener binds; UDP to an unbound port is dropped,
	// so a sender that fires early makes the test fail as "heard nothing" on a loaded runner.
	t := spawn send_someip_after('127.0.0.1:${port}', 300 * time.millisecond, [
		packed,
		packed[..10], // a header fragment
	])
	env.run_source('
		test("a listening tester hears events and requests, decoded", function()
			local seen, malformed = someip.listen(1200, { port = ${port} })
			check.equal(malformed, 1)
			check.equal(#seen, 2)
			local ev, rq = seen[1], seen[2]
			check.equal(ev.service, 0x0100); check.equal(ev.method, 0x8001)
			check.truthy(ev.event, "an id with bit 15 set is an event")
			check.equal(ev.type, "notification"); check.equal(ev.iface, 1); check.equal(ev.rc, 0)
			check.equal(tohex(ev.payload), "11 22 33")
			check.truthy(ev.from:match("^127%.0%.0%.1:%d+$"), "lost the sender: " .. tostring(ev.from))
			check.truthy(ev.at_ms >= 0 and ev.at_ms <= 1200, "at_ms out of the window")
			check.equal(rq.type, "request"); check.truthy(not rq.event)
			check.equal(rq.client, 0x00A5); check.equal(rq.session, 1)
			check.equal(tohex(rq.payload), "CA FE")
		end)
		test("a group that is not an address is refused by the prelude", function()
			local ok, err = pcall(someip.listen, 10, { group = true })
			check.truthy(not ok and tostring(err):find("group must be", 1, true), tostring(err))
		end)
	')!
	t.wait()
	assert env.total() == 2
	assert env.passed() == 2, env.results.filter(!it.ok).map(it.msg).str()
}

// someip.listen's `from` names a channel and takes its port and group; what it cannot resolve
// or what contradicts it is refused. The success path binds the channel's own port.
fn test_someip_listen_from_resolves_or_refuses() {
	port := testports.someip.slot(2, 1)
	mut env := new_env([
		ChanInfo{
			name:  'CAN1'
			iface: 'inproc:UT'
			db:    sample_db()
		},
		ChanInfo{
			name:    'ETH1'
			iface:   'someip:0.0.0.0:${port}'
			carrier: Carrier{
				someip: true
				host:   '0.0.0.0'
				port:   port
			}
		},
	]) or { panic(err) }
	// A GUI row's claim, made the way someip_rx_loop makes it, so the Lua path meets the real
	// registry rather than a stand-in for it.
	held := someip.claim_endpoint('0.0.0.0', port + 7, 'channel ETH9', .row) or { panic(err) }
	defer {
		someip.release_endpoint(held, port + 7, 'channel ETH9')
	}
	env.on_output = fn (s string) {}
	defer { env.close() }
	t := spawn send_someip_after('127.0.0.1:${port}', 300 * time.millisecond, [
		someip.notification(0x0100, 0x8001, 1, [u8(0x11), 0x22, 0x33]),
	])
	env.run_source('
		local function refused(needle, ...)
			local ok, err = pcall(someip.listen, ...)
			check.truthy(not ok, "accepted: " .. tostring(needle))
			check.truthy(string.find(tostring(err), needle, 1, true), "wrong refusal: " .. tostring(err))
		end
		test("an unknown channel is refused by name", function()
			refused(\'unknown channel "Nope"\', 10, { from = "Nope" })
		end)
		test("a CAN channel has no SOME/IP port to listen on", function()
			refused("is not a SOME/IP channel", 10, { from = "CAN1" })
		end)
		test("a port that contradicts the channel is refused, not overruled", function()
			refused("contradicts", 10, { from = "ETH1", port = ${port + 1} })
		end)
		test("a fault on a SOME/IP channel is refused, not armed into nothing", function()
			local ok, err = pcall(sim.fault, "ETH1", "SUT", "Powertrain", "drop", 100)
			check.truthy(not ok and tostring(err):find("could never take effect", 1, true), tostring(err))
		end)
		test("uds.open on a SOME/IP channel is refused as not a diagnostics carrier", function()
			local ok, err = pcall(uds.open, "ETH1")
			check.truthy(not ok and tostring(err):find("not a diagnostics carrier", 1, true), tostring(err))
		end)
		test("an endpoint another listener in this process holds is refused, not split", function()
			-- claimed below as a GUI row would claim it; the refusal must name the holder
			-- whichever of the two started first (someip/claims.v owns that rule and its tests)
			local ok, err = pcall(someip.listen, 10, { port = ${port + 7} })
			check.truthy(not ok, "an overlapping window was accepted")
			check.truthy(tostring(err):find("SPLIT", 1, true), tostring(err))
			check.truthy(tostring(err):find("channel ETH9", 1, true), tostring(err))
		end)
		test("from takes the channel port", function()
			local seen = someip.listen(1200, { from = "ETH1" })
			check.equal(#seen, 1)
			check.equal(seen[1].method, 0x8001)
		end)
	')!
	t.wait()
	assert env.total() == 7
	assert env.passed() == 7, env.results.filter(!it.ok).map(it.msg).str()
}

// Nothing makes channel names unique, and the lookup used to take the first match — so a
// primitive acted on whichever row was written first, and a per-carrier refusal could reject a
// perfectly good row for not being one. Refused by name now, for every primitive.
fn test_a_duplicated_channel_name_is_refused_not_guessed() {
	port := testports.someip.slot(2, 1)
	mut env := new_env([
		ChanInfo{
			name:  'ETH'
			iface: 'inproc:UT'
			db:    sample_db()
		},
		ChanInfo{
			name:    'ETH'
			iface:   'someip:0.0.0.0:${port}'
			carrier: Carrier{
				someip: true
				host:   '0.0.0.0'
				port:   port
			}
		},
	]) or { panic(err) }
	env.on_output = fn (s string) {}
	defer { env.close() }
	env.run_source('
		local function refused(fn_, ...)
			local ok, err = pcall(fn_, ...)
			check.truthy(not ok, "an ambiguous name was accepted")
			check.truthy(string.find(tostring(err), "names more than one channel", 1, true),
				"wrong refusal: " .. tostring(err))
		end
		test("someip.listen refuses an ambiguous name rather than taking the first row", function()
			refused(someip.listen, 10, { from = "ETH" })
		end)
		test("and so does every other primitive that names a channel", function()
			refused(uds.open, "ETH")
			refused(sim.fault, "ETH", "SUT", "Powertrain", "drop", 10)
		end)
	')!
	assert env.total() == 2
	assert env.passed() == 2, env.results.filter(!it.ok).map(it.msg).str()
}
