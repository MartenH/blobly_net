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

import time
import lua
import transport
import isotp
import sim
import uds
import candb
import project

// ChanInfo is one channel a script may address by name: its bus interface and
// the DBC catalog used for decode/encode on it.
pub struct ChanInfo {
pub:
	name  string
	iface string
	db    candb.Database
	// The simulated nodes on this channel. Carried so a script can be told that a fault cannot
	// work — `bad_crc` on a message with no configured checksum changes no bits, and silently
	// succeeding there is the difference between a test that fails and a test that lies.
	nodes []project.NodeCfg
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
	ch  &isotp.SoftChannel
	cli uds.Client
}

// Env is one scripting session: a Lua state plus the channels/connections it can
// reach. Construct with new_env, optionally set `on_output`, then run a script.
pub struct Env {
mut:
	st    lua.State
	chans []ChanInfo
	conns []UdsConn
	buses map[string]transport.Bus
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
	env.st.do_file(path)!
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
	iface := env.chans[ci].iface
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
						if sim.can_force_out_of_range(m, cand.name) {
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
			sim.inject(iface, node, msg, sim.Fault{
				kind:         k
				signal:       sg
				remaining_ms: int(ms)
			})
			return 0
		}
		if k == .bad_crc && !has_protection(env.chans[ci].nodes, node, msg, 'crc') {
			return l.fail('"${msg}" on "${node}" has no configured checksum — bad_crc would change nothing')
		}
		if k == .freeze_ctr && !has_protection(env.chans[ci].nodes, node, msg, 'counter') {
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

// has_protection reports whether the project gives this message the E2E field a fault needs.
fn has_protection(nodes []project.NodeCfg, node string, msg string, field string) bool {
	for n in nodes {
		if n.name != node {
			continue
		}
		for p in n.protect {
			if p.message != msg {
				continue
			}
			return if field == 'crc' { p.crc != '' } else { p.counter != '' }
		}
	}
	return false
}

fn l_uds_open(l lua.State) int {
	mut env := env_of(l)
	name := l.arg_str(1)
	tx := u32(l.arg_int(2))
	rx := u32(l.arg_int(3))
	ci := env.find_chan(name) or { return l.fail('unknown channel "${name}"') }
	// 29-bit addressing is inferred from the ids, exactly as the server side infers it: an
	// address above 0x7FF cannot be 11-bit. Opened standard, SocketCAN masks 0x18DA10F1 to
	// 0x0F1, so a script could not reach a 29-bit server the runner had correctly started.
	ext := tx > 0x7FF || rx > 0x7FF
	ch := isotp.open_software(env.chans[ci].iface, tx, rx, ext) or {
		return l.fail('isotp open failed on ${name}: ${err}')
	}
	env.conns << UdsConn{
		ch:  ch
		cli: uds.new_client(ch)
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
