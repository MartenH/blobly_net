// script — the blobly_net scripting runtime: an embedded Lua 5.4 interpreter
// (modules/lua) wired to the GUI-free protocol stack so test scripts can drive
// diagnostics (UDS over ISO-TP), send/receive raw CAN frames, and decode/encode
// DBC signals. The professional ergonomics (test()/check/uds:/bus.) live in the
// Lua prelude; this file is the thin host side — it registers scalar/string
// primitives and owns the channels, ISO-TP connections and buses a script uses.
//
// It is deliberately GUI-free: both the headless runner (cmd/script) and the
// GUI Script panel construct an Env, point its output sink wherever they want
// (stdout vs a log panel), and run a file. The same script behaves identically.
module script

import sync
import time
import lua
import transport
import isotp
import doip
import sim
import uds
import candb
import project

// ChanInfo is one channel a script may address by name: its bus interface and
// the DBC catalog used for decode/encode on it.
pub struct ChanInfo {
pub:
	name string
	// The string a transport is OPENED with — it may carry a vendor bitrate suffix.
	iface string
	// The LOGICAL interface, without that suffix. Faults are keyed on this: the GUI opened
	// with `pcan:…@250000` and the simulation loop looks up `pcan:…`, so a scripted fault on a
	// vendor channel reported success and was stored under a key nothing would ever read.
	key_iface string
	db        candb.Database
	// The simulated nodes on this channel. Carried so a script can be told that a fault cannot
	// work — `bad_crc` on a message with no configured checksum changes no bits, and silently
	// succeeding there is the difference between a test that fails and a test that lies.
	nodes []project.NodeCfg
	// How UDS reaches this channel. uds.open() built an ISO-TP-over-CAN transport for every
	// channel whatever its type, so a DoIP channel failed with "No such device" from the CAN
	// layer: the tool could simulate a DoIP ECU it could not then test.
	carrier Carrier
}

// Carrier is the transport UDS rides on this channel. Derived from the project channel by
// carrier_of() rather than assembled by each caller — the runner and the GUI build ChanInfo
// separately, and a carrier only one of them filled in would make scripts behave differently
// depending on which one launched them.
pub struct Carrier {
pub:
	doip   bool
	host   string
	port   int
	tester u16
	ecu    u16
}

// carrier_of derives the UDS carrier from a project channel.
pub fn carrier_of(ch project.Channel) Carrier {
	if !ch.is_doip() {
		return Carrier{}
	}
	host, port := ch.doip_endpoint()
	return Carrier{
		doip:   true
		host:   host
		port:   port
		tester: ch.tester_addr
		ecu:    ch.ecu_addr
	}
}

// TestResult is one test() outcome collected during a run.
pub struct TestResult {
pub:
	name string
	ok   bool
	msg  string
}

struct UdsConn {
mut:
	// The INTERFACE, not the CAN implementation: a connection may ride ISO-TP or DoIP, and
	// uds.Client already accepts either (cmd/doip_smoke hands it a DoipClient directly).
	ch   isotp.Channel
	cli  uds.Client
	chan string // the channel this connection belongs to (DoIP reuse; see l_uds_open)
}

// Env is one scripting session: a Lua state plus the channels/connections it can
// reach. Construct with new_env, optionally set `on_output`, then run a script.
// Announcer fires one entity's announcement sequence. Registered by whoever hosts the entity.
//
// A startup burst is finite — three datagrams 500ms apart by default — so a suite that starts
// afterwards can miss it entirely however carefully the runner is sequenced. Rather than
// pretend otherwise, a script can ask for one: listen first, then trigger, then assert.
// Announcer runs a sequence that belongs to the cancellation generation given to it. The
// generation is read by the CALLER before spawning: read inside the worker, a cancel issued
// while it was still being scheduled was already folded into the value it saw.
pub type Announcer = fn (u64) !

// GenReader reads the current cancellation generation, before a worker is spawned.
pub type GenReader = fn () u64

// Canceller stops an in-flight sequence so a run can end without waiting it out.
pub type Canceller = fn ()

pub struct Env {
mut:
	st    lua.State
	chans []ChanInfo
	conns []UdsConn
	buses map[string]transport.Bus
	// Entities this process hosts, by channel name, so a script can trigger their announcement
	// sequence rather than racing the startup burst.
	announcers map[string]Announcer
	gen_of     map[string]GenReader
	cancellers map[string]Canceller
	// Only the channels THIS run triggered are cancelled at teardown. Cancelling every
	// registered server truncated a power-on burst that had nothing to do with the script —
	// externally visible entity behaviour changed by an unrelated Lua file finishing.
	triggered map[string]bool
	mu         sync.Mutex
	async_errs []string // failures from spawned work, surfaced instead of dropped
	// Announcement workers started by doip.announce(). Joined before a run ends: otherwise the
	// runner tears the process down mid-sequence, and a failure recorded after the last flush
	// is never reported at all.
	announce_threads []thread
pub mut:
	results   []TestResult
	log_lines []string // every emitted line, buffered (the GUI reads this post-run)
	on_output fn (string) = fn (s string) {
		println(s)
	}
}

// new_env creates a scripting session over the given channels, loads the prelude
// and registers the host primitives. The returned pointer is stable (heap) so it
// can be stashed in the Lua state for the host callbacks to reach.
pub fn new_env(chans []ChanInfo) !&Env {
	mut env := &Env{
		st:    lua.new()
		chans: chans
	}
	env.st.set_ctx(env)
	env.register_all()
	env.st.do_string(prelude) or { return error('prelude load failed: ${err}') }
	return env
}

// run_file loads and executes a Lua script file (after the prelude).
pub fn (mut env Env) run_file(path string) ! {
	defer {
		// JOIN first, THEN flush: a worker still sleeping between datagrams would otherwise be
		// truncated by teardown, and a failure it recorded after the flush never reported.
		env.join_announcers()
		env.flush_async_errs()
	}
	env.st.do_file(path)!
}

// join_announcers waits for announcement workers a script started and did not wait for.
pub fn (mut env Env) join_announcers() {
	// CANCEL, then join. Joining alone held a run open for the sequence's whole duration —
	// 100 datagrams at 60s is a valid configuration and would have hung a suite for 99 minutes
	// at teardown, which is the same stall the bounded wait removed from the listener.
	// Cancelling first means the workers return at their next interval and their failures are
	// still recorded, so the join stays complete as well as quick.
	for name, _ in env.triggered {
		if c := env.cancellers[name] {
			c()
		}
	}
	env.triggered = map[string]bool{}
	ts := env.announce_threads.clone()
	env.announce_threads = []
	for t in ts {
		t.wait()
	}
}

// run_source loads and executes Lua source text (after the prelude).
pub fn (mut env Env) run_source(src string) ! {
	env.st.do_string(src)!
}

// passed/failed/total summarise the collected test() results.
pub fn (env &Env) passed() int {
	return env.results.filter(it.ok).len
}

pub fn (env &Env) failed() int {
	return env.results.filter(!it.ok).len
}

pub fn (env &Env) total() int {
	return env.results.len
}

// close tears down the ISO-TP connections, buses and the interpreter.
// register_announcer lets the host offer a channel announcement sequence to scripts.
// note_async_err records a failure from work a script started but did not wait for, so it
// surfaces in the output instead of vanishing into a spawned thread.
pub fn (mut env Env) note_async_err(msg string) {
	// RECORD ONLY. emit() appends to log_lines and calls on_output, both of which the
	// interpreter thread is using — emitting from a spawned trigger races the buffer it grows.
	// The script thread flushes these (flush_async_errs) at the next announce and at the end
	// of a run, so nothing is lost and nothing is written from two threads.
	env.mu.lock()
	env.async_errs << msg
	env.mu.unlock()
}

// emit_async_err flushes anything a previous async trigger reported, so it lands in the output
// near the test that caused it rather than at some arbitrary later point.
// flush_async_errs emits anything a spawned trigger reported. Script thread only.
pub fn (mut env Env) flush_async_errs() {
	env.mu.lock()
	pending := env.async_errs.clone()
	env.async_errs = []
	env.mu.unlock()
	for p in pending {
		env.emit('!! ${p}')
	}
}

pub fn (mut env Env) register_announcer(chan_name string, f Announcer, g GenReader, c Canceller) {
	env.announcers[chan_name] = f
	env.gen_of[chan_name] = g
	env.cancellers[chan_name] = c
}

pub fn (mut env Env) close() {
	for mut c in env.conns {
		c.ch.close()
	}
	for _, mut b in env.buses {
		b.close()
	}
	env.st.close()
}

fn (mut env Env) emit(s string) {
	env.log_lines << s
	env.on_output(s)
}

fn (env &Env) find_chan(name string) ?int {
	for i, c in env.chans {
		if c.name == name {
			return i
		}
	}
	return none
}

// bus_for returns (opening once, lazily) a persistent monitor bus for the named
// channel, so bus.recv sees traffic from sims/other nodes on the same interface.
fn (mut env Env) bus_for(name string) !transport.Bus {
	ci := env.find_chan(name) or { return error('unknown channel "${name}"') }
	if b := env.buses[name] {
		return b
	}
	b := transport.open(env.chans[ci].iface)!
	env.buses[name] = b
	return b
}

fn find_msg(db candb.Database, name string) ?candb.Message {
	for m in db.messages {
		if m.name == name {
			return m
		}
	}
	return none
}

fn find_sig(m candb.Message, name string) ?candb.Signal {
	for s in m.signals {
		if s.name == name {
			return s
		}
	}
	return none
}

// register_all binds every host primitive the prelude relies on.
fn (mut env Env) register_all() {
	env.st.register('__report', l_report)
	env.st.register('__log', l_log)
	env.st.register('__sleep', l_sleep)
	env.st.register('__sim_fault', l_sim_fault)
	env.st.register('__uds_open', l_uds_open)
	env.st.register('__doip_discover', l_doip_discover)
	env.st.register('__doip_listen', l_doip_listen)
	env.st.register('__doip_announce', l_doip_announce)
	env.st.register('__uds_session', l_uds_session)
	env.st.register('__uds_read_did', l_uds_read_did)
	env.st.register('__uds_tester_present', l_uds_tester_present)
	env.st.register('__uds_raw', l_uds_raw)
	env.st.register('__bus_send', l_bus_send)
	env.st.register('__bus_recv', l_bus_recv)
	env.st.register('__msg_template', l_msg_template)
	env.st.register('__encode_signal', l_encode_signal)
	env.st.register('__decode', l_decode)
	env.st.register('__now_ms', l_now_ms)
	env.st.register('__uds_write_did', l_uds_write_did)
	env.st.register('__uds_sec_seed', l_uds_sec_seed)
	env.st.register('__uds_sec_key', l_uds_sec_key)
	env.st.register('__uds_read_dtc', l_uds_read_dtc)
}

// env_of recovers the &Env stashed in the Lua state by new_env.
fn env_of(l lua.State) &Env {
	return unsafe { &Env(l.get_ctx()) }
}

// ============================ host primitives ============================

fn l_report(l lua.State) int {
	mut env := env_of(l)
	name := l.arg_str(1)
	ok := l.arg_bool(2)
	msg := l.arg_str(3)
	env.results << TestResult{
		name: name
		ok:   ok
		msg:  msg
	}
	if ok {
		env.emit('  ok   ${name}')
	} else {
		env.emit('  FAIL ${name}: ${msg}')
	}
	return 0
}

fn l_log(l lua.State) int {
	mut env := env_of(l)
	env.emit(l.arg_str(1))
	return 0
}

fn l_sleep(l lua.State) int {
	ms := l.arg_int(1)
	if ms > 0 {
		time.sleep(ms * time.millisecond)
	}
	return 0
}

// l_sim_fault injects (or clears) a fault: sim_fault(node, message, kind [, ms [, signal]]).
//
// Injecting from a script is the point — a fault a human has to click is a demo, while a fault
// a test can raise and clear is a regression check: drop the frame, assert the DTC appears,
// clear it, assert it goes away.
fn l_sim_fault(l lua.State) int {
	mut env := env_of(l)
	chan_name := l.arg_str(1)
	node := l.arg_str(2)
	msg := l.arg_str(3)
	kind := l.arg_str(4)
	ms := l.arg_int(5)
	signal := l.arg_str(6)
	ci := env.find_chan(chan_name) or { return l.fail('unknown channel "${chan_name}"') }
	iface := env.chans[ci].fault_iface()
	k := match kind {
		'none', 'clear', '' { sim.FaultKind.none_ }
		'drop' { sim.FaultKind.drop }
		'bad_crc' { sim.FaultKind.bad_crc }
		'freeze_counter' { sim.FaultKind.freeze_ctr }
		'out_of_range' { sim.FaultKind.out_of_range }
		else { return l.fail('unknown fault kind "${kind}"') }
	}
	// Reject a target nothing will ever read. A misspelled node or message stored under a key
	// no engine looks at reports success and changes no traffic — which in an automated fault
	// experiment is indistinguishable from a fault that was armed and had no effect.
	if k != .none_ {
		mut known := false
		for m in env.chans[ci].db.messages_from(node) {
			if m.name == msg {
				known = true
				break
			}
		}
		if !known {
			return l.fail('"${node}" does not send "${msg}" on ${chan_name}')
		}
		if k == .out_of_range {
			mut sg := signal
			if sg == '' {
				// choose one, as the panel does, rather than succeeding and mutating nothing
				for m in env.chans[ci].db.messages_from(node) {
					if m.name != msg {
						continue
					}
					for cand in m.signals {
						if sim.can_force_out_of_range(m, cand.name, prot_of(env.chans[ci].nodes, node, msg)) {
							sg = cand.name
							break
						}
					}
					break
				}
			}
			if sg == '' {
				return l.fail('no signal on "${msg}" has a value outside its declared range')
			}
			// Validate a signal the caller NAMED as well. Only the auto-picked case was
			// checked, so a misspelled or full-width signal was stored happily and then
			// transmitted an unchanged frame — the exact "armed but does nothing" outcome the
			// rest of this validation exists to prevent.
			mut usable := false
			for m in env.chans[ci].db.messages_from(node) {
				if m.name == msg && sim.can_force_out_of_range(m, sg, prot_of(env.chans[ci].nodes, node, msg)) {
					usable = true
				}
			}
			if !usable {
				return l.fail('"${sg}" on "${msg}" has no value outside its declared range')
			}
			sim.inject(iface, node, msg, sim.Fault{
				kind:         k
				signal:       sg
				remaining_ms: int(ms)
			})
			return 0
		}
		if k == .bad_crc && !has_protection(env.chans[ci].db, env.chans[ci].nodes, node, msg, 'crc') {
			return l.fail('"${msg}" on "${node}" has no configured checksum — bad_crc would change nothing')
		}
		if k == .freeze_ctr && !has_protection(env.chans[ci].db, env.chans[ci].nodes, node, msg, 'counter') {
			// The E2E counter is what freezes; a `counter` GENERATOR is an ordinary signal and
			// keeps running by design. Without protection there is nothing to stall, and
			// arming it would report success and change nothing.
			return l.fail('"${msg}" on "${node}" has no E2E counter — freeze_counter would change nothing')
		}
	}
	sim.inject(iface, node, msg, sim.Fault{
		kind:         k
		signal:       signal
		remaining_ms: int(ms)
	})
	return 0
}

// fault_iface is the key faults are stored under — the logical interface, falling back to the
// transport string for channels that never had a separate one.
pub fn (c ChanInfo) fault_iface() string {
	return if c.key_iface != '' { c.key_iface } else { c.iface }
}

// has_protection reports whether this message really has the E2E field a fault needs.
//
// The named signal must EXIST in the DBC message, not merely be a non-empty string: the engine
// attaches a misspelled protection entry happily, and then neither the stamper nor the fault
// finds the signal — so `bad_crc` was accepted and changed no transmitted bits.
fn has_protection(db candb.Database, nodes []project.NodeCfg, node string, msg string, field string) bool {
	for n in nodes {
		if n.name != node {
			continue
		}
		for p in n.protect {
			if p.message != msg {
				continue
			}
			want := if field == 'crc' { p.crc } else { p.counter }
			if want == '' {
				return false
			}
			for m in db.messages_from(node) {
				if m.name != msg {
					continue
				}
				for sg in m.signals {
					if sg.name != want {
						continue
					}
					// A MULTIPLEXED protection field is only written when its selector is
					// active, and both the stamper and the fault walk active signals only — so
					// neither would touch it and the fault would change no transmitted bits.
					return !sg.is_multiplexed
				}
			}
			return false
		}
	}
	return false
}

// prot_of returns the protection configured for one message, so a range fault can be kept off
// the counter and checksum fields — a violation written there is overwritten when the checksum
// is stamped, and the frame goes out valid.
fn prot_of(nodes []project.NodeCfg, node string, msg string) sim.E2e {
	for n in nodes {
		if n.name != node {
			continue
		}
		for p in n.protect {
			if p.message == msg {
				return sim.E2e{
					counter: p.counter
					crc:     p.crc
					profile: p.profile
				}
			}
		}
	}
	return sim.E2e{}
}

fn l_uds_open(l lua.State) int {
	mut env := env_of(l)
	name := l.arg_str(1)
	// Presence is carried by nil, not by a magic value: 0 is a valid arbitration id, and a
	// negative one is a caller mistake — treating either as "omitted" silently redirects the
	// request to 0x7E0/0x7E8 and reports a result from an ECU the script never addressed.
	has_tx := !l.arg_is_nil(2)
	has_rx := !l.arg_is_nil(3)
	txi := l.arg_int(2)
	rxi := l.arg_int(3)
	if has_tx && (txi < 0 || txi > 0x1FFF_FFFF) {
		return l.fail('uds.open("${name}"): tx = ${txi} is not a CAN identifier (0..0x1FFFFFFF)')
	}
	if has_rx && (rxi < 0 || rxi > 0x1FFF_FFFF) {
		return l.fail('uds.open("${name}"): rx = ${rxi} is not a CAN identifier (0..0x1FFFFFFF)')
	}
	tx := u32(txi)
	rx := u32(rxi)
	ci := env.find_chan(name) or { return l.fail('unknown channel "${name}"') }
	// 29-bit addressing is inferred from the ids, exactly as the server side infers it: an
	// address above 0x7FF cannot be 11-bit. Opened standard, SocketCAN masks 0x18DA10F1 to
	// 0x0F1, so a script could not reach a 29-bit server the runner had correctly started.
	info := env.chans[ci]
	// A DoIP entity serves ONE TCP connection at a time — accept_and_serve stays inside the
	// accepted connection until the peer disconnects, and nothing here closes a connection
	// before the session ends. A second uds.open() on the same channel therefore connected and
	// then timed out waiting for a routing activation that would never come. Hand back the
	// live connection instead: it addresses the same entity, from the same tester address.
	if info.carrier.doip {
		// Argument check FIRST. Reusing before validating handed a bad call a good connection,
		// so the refusal below silently stopped applying to every open after the first.
		if has_tx || has_rx {
			return l.fail('uds.open("${name}"): DoIP addressing comes from the channel (tester_address/ecu_address); drop tx/rx')
		}
		for i, mut c in env.conns {
			if c.chan != name {
				continue
			}
			// Prove it is still there. The entity closes an idle connection after 60s
			// (server.v read_message), and handing back a dead socket would fail the next
			// request on a channel that is in fact accepting connections again.
			c.cli.tester_present() or {
				// A NEGATIVE RESPONSE is proof of life: the ECU received the request and
				// refused it (wrong session, service unavailable). Reconnecting on that would
				// tear down a healthy connection and reset the session and security state of
				// every handle sharing this slot, turning a legitimate refusal into a silently
				// unauthenticated retry. ONLY a transport failure means death.
				if !probe_says_dead(err) {
					l.push_int(i)
					return 1
				}
				// Stale: reconnect INTO THE SAME SLOT, so the handle a script is already
				// holding keeps working rather than being orphaned by the repair.
				c.ch.close()
				fresh := doip.open_doip(info.carrier.host, info.carrier.port, info.carrier.tester,
					info.carrier.ecu) or {
					return l.fail('doip reconnect failed on ${name} (${info.carrier.host}:${info.carrier.port}): ${err}')
				}
				env.conns[i] = UdsConn{
					ch:   fresh
					cli:  uds.new_client(fresh)
					chan: name
				}
				l.push_int(i)
				return 1
			}
			l.push_int(i)
			return 1
		}
	}
	// DoIP carries UDS over TCP with logical addresses, not over ISO-TP with CAN ids, so the
	// tx/rx arguments do not apply — the addresses come from the channel's configuration and
	// passing ids here is a mistake worth naming rather than ignoring.
	ch := if info.carrier.doip {
		isotp.Channel(doip.open_doip(info.carrier.host, info.carrier.port, info.carrier.tester,
			info.carrier.ecu) or {
			return l.fail('doip open failed on ${name} (${info.carrier.host}:${info.carrier.port}): ${err}')
		})
	} else {
		// Omitted, not zero: the standard physical pair is the CAN default.
		ctx := if has_tx { tx } else { u32(0x7E0) }
		crx := if has_rx { rx } else { u32(0x7E8) }
		ext := ctx > 0x7FF || crx > 0x7FF
		isotp.Channel(isotp.open_software(info.iface, ctx, crx, ext) or {
			return l.fail('isotp open failed on ${name}: ${err}')
		})
	}
	env.conns << UdsConn{
		ch:   ch
		cli:  uds.new_client(ch)
		chan: name
	}
	l.push_int(env.conns.len - 1)
	return 1
}

fn (mut env Env) conn(h int) ?&UdsConn {
	if h < 0 || h >= env.conns.len {
		return none
	}
	return unsafe { &env.conns[h] }
}

fn l_uds_session(l lua.State) int {
	mut env := env_of(l)
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	params := c.cli.diagnostic_session(u8(l.arg_int(2))) or { return l.fail(err.msg()) }
	l.push_bytes(params)
	return 1
}

fn l_uds_read_did(l lua.State) int {
	mut env := env_of(l)
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	data := c.cli.read_data_by_identifier(u16(l.arg_int(2))) or { return l.fail(err.msg()) }
	l.push_bytes(data)
	return 1
}

// l_doip_discover asks a DoIP channel's endpoint to identify itself (ISO 13400 vehicle
// identification). Scriptable because the ANNOUNCED identity and the SERVED identity are
// separate values that can disagree — and a test that can only read DID 0xF190 cannot see
// half of that.
fn l_doip_discover(l lua.State) int {
	mut env := env_of(l)
	name := l.arg_str(1)
	ci := env.find_chan(name) or { return l.fail('unknown channel "${name}"') }
	info := env.chans[ci]
	if !info.carrier.doip {
		return l.fail('doip.discover("${name}"): not a DoIP channel')
	}
	v := doip.discover(info.carrier.host, info.carrier.port, 1200) or {
		return l.fail('doip.discover("${name}") on ${info.carrier.host}:${info.carrier.port}: ${err}')
	}
	l.push_str(v.vin)
	l.push_int(i64(v.logical_address))
	return 2
}

// probe_says_dead decides whether a failed liveness probe means the connection is gone.
//
// A NEGATIVE RESPONSE is proof of life: the ECU received the request and refused it (wrong
// session, service unavailable). Reconnecting on that tears down a healthy connection and
// resets the session and security state of every handle sharing the slot — turning a
// legitimate refusal into a silently unauthenticated retry. Only a TRANSPORT failure is death.
//
// A named predicate because the simulated server always answers 0x3E positively, so no project
// can reach this from a Lua suite: it fires against a real ECU on a bench, where it cannot be
// caught by CI. The distinction is at least pinned by a unit test.
fn probe_says_dead(err IError) bool {
	return err !is uds.NegativeResponse
}

// l_doip_listen collects UNSOLICITED announcements — discovery the way a real tester does it,
// by listening rather than asking. Returns "vin|0xADDR" lines; the prelude shapes them.
// l_doip_announce triggers a hosted entity's announcement sequence on demand.
fn l_doip_announce(l lua.State) int {
	mut env := env_of(l)
	name := l.arg_str(1)
	f := env.announcers[name] or {
		return l.fail('doip.announce("${name}"): not an entity this process hosts')
	}
	// NON-BLOCKING. The sequence takes count × interval (1.5s by default); returning only when
	// it finished meant a script could never listen for its own trigger — every datagram was
	// already sent by the time doip.listen() bound its socket, and the test passed having
	// heard nothing at all.
	//
	// A failure is REPORTED, not swallowed. This API exists to drive an external listening
	// tester, so a send that never happened would otherwise be blamed on that tester.
	env.flush_async_errs()
	// Generation BEFORE the spawn, and mark the channel as ours so teardown cancels this one
	// and not somebody else's startup burst.
	gen := if r := env.gen_of[name] { r() } else { u64(0) }
	env.triggered[name] = true
	env.announce_threads << spawn fn (g Announcer, gn u64, mut e Env, nm string) {
		g(gn) or { e.note_async_err('doip.announce("${nm}"): ${err}') }
	}(f, gen, mut env, name)
	return 0
}

fn l_doip_listen(l lua.State) int {
	mut env := env_of(l)
	port := int(l.arg_int(1))
	window := int(l.arg_int(2))
	ip6 := l.arg_bool(3)
	mut from_chan := l.arg_str(4)
	mut use_port := port
	mut use_ip6 := ip6
	if from_chan != '' {
		if ci := env.find_chan(from_chan) {
			// The triggered channel's OWN port AND family. Deriving the port but not the family
			// left an IPv6 entity listened for on 0.0.0.0 while it announced over IPv6 —
			// an empty result unless the caller happened to pass ip6 = true as well.
			if use_port == 0 {
				use_port = env.chans[ci].carrier.port
			}
			if env.chans[ci].carrier.host.contains(':') {
				use_ip6 = true
			}
		}
	}
	if use_port == 0 {
		use_port = 13400
	}
	// With a channel named, BIND FIRST and trigger that entity from inside — a script that
	// triggers and then listens cannot close the race when announce_count is 1 or the interval
	// is 0: the whole sequence can be gone before the socket exists.
	found := if from_chan != '' {
		f := env.announcers[from_chan] or {
			return l.fail('doip.listen(from: "${from_chan}"): not an entity this process hosts')
		}
		// Wrapped so a failure ARRIVING LATE — after the grace window — is still recorded; the
		// channel inside doip only carries what is ready in time. The thread is kept so
		// run_file joins it before the final flush.
		nm := from_chan
		mut e := env
		gen := if r := env.gen_of[nm] { r() } else { u64(0) } // before the spawn inside doip
		env.triggered[nm] = true
		wrapped := fn [f, gen, mut e, nm] () ! {
			f(gen) or {
				e.note_async_err('doip.listen(from: "${nm}"): ${err}')
				return err
			}
		}
		got, th := doip.collect_announcements_triggered(use_port, window, use_ip6, wrapped) or {
			return l.fail('doip.listen(${use_port}): ${err}')
		}
		env.announce_threads << th
		got
	} else {
		doip.collect_announcements_af(use_port, window, use_ip6) or {
			return l.fail('doip.listen(${port}): ${err}')
		}
	}
	mut out := []string{}
	for f in found {
		// the sender endpoint travels with it: a tester that discovers an ECU passively still
		// has to dial it, and vin+address are not routable
		out << '${f.info.vin}|0x${f.info.logical_address:04X}|${f.from}'
	}
	l.push_str(out.join('\n'))
	return 1
}

fn l_uds_tester_present(l lua.State) int {
	mut env := env_of(l)
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	c.cli.tester_present() or { return l.fail(err.msg()) }
	return 0
}

fn l_uds_raw(l lua.State) int {
	mut env := env_of(l)
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	resp := c.cli.raw(l.arg_bytes(2)) or { return l.fail(err.msg()) }
	l.push_bytes(resp)
	return 1
}

fn l_uds_write_did(l lua.State) int {
	mut env := env_of(l)
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	c.cli.write_data_by_identifier(u16(l.arg_int(2)), l.arg_bytes(3)) or { return l.fail(err.msg()) }
	return 0
}

fn l_uds_sec_seed(l lua.State) int {
	mut env := env_of(l)
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	seed := c.cli.security_request_seed(u8(l.arg_int(2))) or { return l.fail(err.msg()) }
	l.push_bytes(seed)
	return 1
}

fn l_uds_sec_key(l lua.State) int {
	mut env := env_of(l)
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	c.cli.security_send_key(u8(l.arg_int(2)), l.arg_bytes(3)) or { return l.fail(err.msg()) }
	return 0
}

fn l_uds_read_dtc(l lua.State) int {
	mut env := env_of(l)
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	dtcs := c.cli.read_dtc_by_status_mask(u8(l.arg_int(2))) or { return l.fail(err.msg()) }
	l.push_bytes(dtcs)
	return 1
}

// l_now_ms returns a monotonic millisecond clock for the prelude's expect/run/timers.
fn l_now_ms(l lua.State) int {
	l.push_int(time.ticks())
	return 1
}

fn l_bus_send(l lua.State) int {
	mut env := env_of(l)
	name := l.arg_str(1)
	mut bus := env.bus_for(name) or { return l.fail(err.msg()) }
	bus.send(transport.CanFrame{
		id:       u32(l.arg_int(2))
		extended: l.arg_bool(3)
		data:     l.arg_bytes(4)
	}) or { return l.fail('send failed on ${name}: ${err}') }
	return 0
}

fn l_bus_recv(l lua.State) int {
	mut env := env_of(l)
	name := l.arg_str(1)
	mut bus := env.bus_for(name) or { return l.fail(err.msg()) }
	frame := bus.recv(int(l.arg_int(2))) or {
		l.push_nil()
		return 1
	}
	l.push_int(frame.id)
	l.push_bool(frame.extended)
	l.push_bytes(frame.data)
	return 3
}

fn l_msg_template(l lua.State) int {
	mut env := env_of(l)
	ci := env.find_chan(l.arg_str(1)) or { return l.fail('unknown channel "${l.arg_str(1)}"') }
	msg := find_msg(env.chans[ci].db, l.arg_str(2)) or {
		return l.fail('unknown message "${l.arg_str(2)}"')
	}
	l.push_int(msg.id)
	l.push_bool(msg.ext)
	l.push_bytes([]u8{len: msg.dlc})
	return 3
}

fn l_encode_signal(l lua.State) int {
	mut env := env_of(l)
	ci := env.find_chan(l.arg_str(1)) or { return l.fail('unknown channel "${l.arg_str(1)}"') }
	msg := find_msg(env.chans[ci].db, l.arg_str(2)) or {
		return l.fail('unknown message "${l.arg_str(2)}"')
	}
	sig := find_sig(msg, l.arg_str(3)) or {
		return l.fail('unknown signal "${l.arg_str(3)}" in ${l.arg_str(2)}')
	}
	mut data := l.arg_bytes(5)
	sig.encode(mut data, l.arg_num(4))
	l.push_bytes(data)
	return 1
}

fn l_decode(l lua.State) int {
	mut env := env_of(l)
	ci := env.find_chan(l.arg_str(1)) or { return l.fail('unknown channel "${l.arg_str(1)}"') }
	data := l.arg_bytes(4)
	msg := env.chans[ci].db.lookup_frame(u32(l.arg_int(2)), l.arg_bool(3)) or {
		l.push_nil()
		return 1
	}
	l.new_table()
	for s in msg.active_signals(data) {
		l.set_num(s.name, s.physical(data))
	}
	return 1
}
