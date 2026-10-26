// Background sends and the UDS keep-alive from Lua: bus.send_cyclic / bus.send_message_cyclic
// (blobly/cyclic, each sender on a bus of its own, so no script handle is used from a second
// thread) and diag:keep_alive (uds.KeepAlive, under the connection's `mu`, which every exchange of
// its client holds).
module script

import blobly.cyclic
import blobly.lua
import blobly.transport
import blobly.uds

fn (mut env Env) register_cyclic() {
	env.st.register('__cyclic_start', l_cyclic_start)
	env.st.register('__cyclic_start_msg', l_cyclic_start_msg)
	env.st.register('__cyclic_data', l_cyclic_data)
	env.st.register('__cyclic_signals', l_cyclic_signals)
	env.st.register('__cyclic_period', l_cyclic_period)
	env.st.register('__cyclic_status', l_cyclic_status)
	env.st.register('__cyclic_stop', l_cyclic_stop)
	env.st.register('__uds_keep_alive', l_uds_keep_alive)
	env.st.register('__uds_keep_alive_status', l_uds_keep_alive_status)
}

// start_sender opens a bus of the sender's own on CAN channel `name` and starts `spec` on it.
fn (mut env Env) start_sender(name string, spec cyclic.Spec) !int {
	ci := env.find_chan(name)!
	ch := env.chans[ci]
	if k := ch.carrier.eth_kind() {
		return error('"${name}" is a ${k} channel — not a CAN bus; nothing is transmitted on it')
	}
	spec.check() or { return error('${name}: ${err.msg()}') }
	bus := transport.row_framed(env.opener(ch.iface, name)!, ch.framing)
	s := env.cyclic_host.start_cyclic(bus, spec) or { return error('${name}: ${err.msg()}') }
	env.senders << s
	return env.senders.len - 1
}

// stop_senders stops every background sender the script started: at close, and by a host after
// each script it runs, whose senders end with it.
pub fn (mut env Env) stop_senders() {
	left := cyclic.stop_all(mut env.senders)
	if left > 0 {
		env.emit('${left} background sender(s) still inside a send at close; they send nothing more')
	}
}

fn (mut env Env) sender(l lua.State) !&cyclic.Sender {
	h := handle_arg(l, 1, 'the sender handle')!
	if h >= env.senders.len {
		return error('the sender handle ${h} names no sender')
	}
	return env.senders[h]
}

// pairs_from reads name, value pairs from argument `i` on.
fn pairs_from(l lua.State, i int) !map[string]f64 {
	mut out := map[string]f64{}
	mut k := i
	for k + 1 <= l.nargs() {
		if !l.arg_is_num(k + 1) {
			return error('signal "${l.arg_str(k)}": a value is a number')
		}
		out[l.arg_str(k)] = l.arg_num(k + 1)
		k += 2
	}
	return out
}

// __cyclic_start(channel, id, ext, data, format, period_ms) -> handle
fn l_cyclic_start(l lua.State) i32 {
	mut env := env_of(l)
	ff := transport.parse_frame_format(l.arg_str(5)) or { return l.fail('bus.send_cyclic: ${err}') }
	id := can_id_arg(l, 2) or { return l.fail('bus.send_cyclic: ${err}') }
	period := int_arg(l, 6, 'period_ms', min_i32, max_i32) or {
		return l.fail('bus.send_cyclic: ${err}')
	}
	h := env.start_sender(l.arg_str(1), cyclic.Spec{
		id:        id
		ext:       l.arg_bool(3)
		data:      l.arg_bytes(4)
		format:    ff
		period_ms: int(period)
	}) or { return l.fail('bus.send_cyclic: ${err}') }
	l.push_int(h)
	return 1
}

// __cyclic_start_msg(channel, message, e2e, period_ms, name1, value1, ...) -> handle
fn l_cyclic_start_msg(l lua.State) i32 {
	mut env := env_of(l)
	name := l.arg_str(1)
	ci := env.find_chan(name) or { return l.fail('bus.send_message_cyclic: ${err}') }
	msg := env.chans[ci].db.message_named(l.arg_str(2)) or {
		return l.fail('bus.send_message_cyclic: unknown message "${l.arg_str(2)}"')
	}
	vals := pairs_from(l, 5) or { return l.fail('bus.send_message_cyclic: ${err}') }
	period := int_arg(l, 4, 'period_ms', min_i32, max_i32) or {
		return l.fail('bus.send_message_cyclic: ${err}')
	}
	h := env.start_sender(name, cyclic.Spec{
		by_message: true
		message:    msg
		values:     vals
		e2e:        l.arg_bool(3)
		period_ms:  int(period)
	}) or { return l.fail('bus.send_message_cyclic: ${err}') }
	l.push_int(h)
	return 1
}

fn l_cyclic_data(l lua.State) i32 {
	mut env := env_of(l)
	mut s := env.sender(l) or { return l.fail('sender: ${err}') }
	s.set_data(l.arg_bytes(2)) or { return l.fail('sender:update: ${err}') }
	return 0
}

fn l_cyclic_signals(l lua.State) i32 {
	mut env := env_of(l)
	mut s := env.sender(l) or { return l.fail('sender: ${err}') }
	vals := pairs_from(l, 2) or { return l.fail('sender:update: ${err}') }
	s.set_values(vals) or { return l.fail('sender:update: ${err}') }
	return 0
}

fn l_cyclic_period(l lua.State) i32 {
	mut env := env_of(l)
	mut s := env.sender(l) or { return l.fail('sender: ${err}') }
	ms := l.arg_int_exact(2) or { return l.fail('sender:period: a period is a whole number of ms') }
	s.set_period(int(ms)) or { return l.fail('sender:period: ${err}') }
	return 0
}

// __cyclic_status(h) -> sent, failed, error, period_ms, running
fn l_cyclic_status(l lua.State) i32 {
	mut env := env_of(l)
	mut s := env.sender(l) or { return l.fail('sender: ${err}') }
	i := s.info()
	l.push_int(i64(i.sent))
	l.push_int(i64(i.failed))
	l.push_str(i.error)
	l.push_int(i.period_ms)
	l.push_bool(i.running)
	return 5
}

// __cyclic_stop(h) -> true once its loop is out
fn l_cyclic_stop(l lua.State) i32 {
	mut env := env_of(l)
	mut s := env.sender(l) or { return l.fail('sender: ${err}') }
	l.push_bool(s.stop())
	return 1
}

// new_conn is `c` with its client's exchanges held by its `mu`.
fn new_conn(c UdsConn) UdsConn {
	mut out := c
	out.cli.serial = out.mu
	return out
}

// keep_alive starts the connection's keep-alive every `ms` (0: none), stopping one that runs.
fn (mut c UdsConn) keep_alive(ms int) ! {
	c.stop_keep_alive()
	if ms == 0 {
		return
	}
	mu := c.mu
	cli := c.cli
	c.ka = uds.keep_alive(ms, uds.KeepAliveHost{
		acquire: fn [mu, cli] () ?&uds.Client {
			mut m := unsafe { mu }
			m.lock()
			return cli
		}
		release: fn [mu] () {
			mut m := unsafe { mu }
			m.unlock()
		}
	})!
	c.ka_ms = ms
}

// stop_keep_alive ends the connection's keep-alive, a failure it had not said kept to be said;
// the period it had (0: none). A keep-alive still waiting for the lock when the stop's bound
// passes takes nothing once it gets it, and one inside a keep-alive holds the lock: close_held
// waits for that.
fn (mut c UdsConn) stop_keep_alive() int {
	ms := c.ka_ms
	if !isnil(c.ka) {
		mut k := c.ka
		if !k.stop() {
			c.ka_late << k // still inside a keep-alive: its failure, if it fails, is said later
		}
		if why := k.take_failure() {
			c.ka_said = why
		}
		c.ka = unsafe { nil }
	}
	c.ka_ms = 0
	return ms
}

// succeeded_by is `next`, the connection that replaces c in its slot, with what c's keep-alive has
// not said yet: its failure and the keep-alives still inside a send, said at the next call.
fn (c &UdsConn) succeeded_by(next UdsConn) UdsConn {
	return UdsConn{
		...next
		ka_said: c.ka_said
		ka_late: c.ka_late.clone()
	}
}

// close_held closes the connection's channel under its lock, never inside a keep-alive.
fn (mut c UdsConn) close_held() {
	c.mu.lock()
	c.ch.close()
	c.mu.unlock()
}

// say_keep_alive says, once, a keep-alive failure since the connection's previous call.
fn (mut env Env) say_keep_alive(mut c UdsConn) {
	if c.ka_said != '' {
		env.emit('${c.chan}: ${c.ka_said}')
		c.ka_said = ''
	}
	mut still := []&uds.KeepAlive{}
	for mut late in c.ka_late {
		out := late.is_out() // asked first: a failure recorded before it left is taken below
		if why := late.take_failure() {
			env.emit('${c.chan}: ${why}')
		}
		if !out {
			still << late
		}
	}
	c.ka_late = still
	if isnil(c.ka) {
		return
	}
	mut k := c.ka
	if why := k.take_failure() {
		env.emit('${c.chan}: ${why}')
	}
}

// __uds_keep_alive(h, period_ms): 0 stops it
fn l_uds_keep_alive(l lua.State) i32 {
	mut env := env_of(l)
	mut c, _ := env.conn_arg(l, 1) or { return l.fail('diag:keep_alive: ${err}') }
	ms := l.arg_int_exact(2) or { return l.fail('diag:keep_alive: a period is a whole number of ms') }
	if ms != 0 && (ms < uds.keepalive_min_ms || ms > uds.keepalive_max_ms) {
		return l.fail('diag:keep_alive: a period of ${ms} ms: give ${uds.keepalive_min_ms} .. ${uds.keepalive_max_ms}, or 0 to stop')
	}
	c.keep_alive(int(ms)) or { return l.fail('diag:keep_alive: ${err}') }
	return 0
}

// __uds_keep_alive_status(h) -> period_ms, sent, failures, running, failure
fn l_uds_keep_alive_status(l lua.State) i32 {
	mut env := env_of(l)
	c, _ := env.conn_arg(l, 1) or { return l.fail('diag:keep_alive_status: ${err}') }
	mut st := uds.KeepAliveStatus{}
	if !isnil(c.ka) {
		mut k := c.ka
		st = k.status()
	}
	l.push_int(st.period_ms)
	l.push_int(i64(st.sent))
	l.push_int(i64(st.failures))
	l.push_bool(st.running)
	l.push_str(st.failure)
	return 5
}
