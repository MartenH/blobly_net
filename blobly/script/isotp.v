module script

import blobly.doip
import blobly.isotp
import blobly.lua
import blobly.uds
import blobly.udsconn

// IsotpConn is a raw ISO-TP channel a script opened (isotp.open): the engine's software ISO-TP on a
// CAN channel's id pair, with no UDS on top.
struct IsotpConn {
mut:
	ch     &isotp.SoftChannel
	chan   string
	closed bool
}

// register_isotp binds raw ISO-TP (isotp.open), a UDS connection's timing and the DoIP retarget.
fn (mut env Env) register_isotp() {
	env.st.register('__isotp_open', l_isotp_open)
	env.st.register('__isotp_send', l_isotp_send)
	env.st.register('__isotp_recv', l_isotp_recv)
	env.st.register('__isotp_close', l_isotp_close)
	env.st.register('__uds_timing', l_uds_timing)
	env.st.register('__uds_set_timing', l_uds_set_timing)
	env.st.register('__uds_timing_check', l_uds_timing_check)
	env.st.register('__uds_retarget', l_uds_retarget)
	env.st.register('__uds_target', l_uds_target)
}

// __isotp_open(channel, tx, rx): a raw ISO-TP channel on the channel named, by udsconn's rule (a
// CAN channel, both ids given), on the bus the opener gives
fn l_isotp_open(l lua.State) i32 {
	mut env := env_of(l)
	name := l.arg_str(1)
	has_tx := !l.arg_is_nil(2)
	has_rx := !l.arg_is_nil(3)
	txi := if has_tx { l.arg_int_exact(2) or { return l.fail('isotp.open("${name}"): tx is not an integer') } } else { 0 }
	rxi := if has_rx { l.arg_int_exact(3) or { return l.fail('isotp.open("${name}"): rx is not an integer') } } else { 0 }
	ask := udsconn.Ask{
		what:   'isotp.open'
		has_tx: has_tx
		tx:     txi
		has_rx: has_rx
		rx:     rxi
	}
	udsconn.check_ids(ask, name) or { return l.fail(err.msg()) }
	ci := env.find_chan(name) or { return l.fail(err.msg()) }
	info := env.chans[ci]
	t := udsconn.resolve_isotp(ask, name, info.carrier) or { return l.fail(err.msg()) }
	mut ch := udsconn.open_isotp(t, name, info.iface, env.opener) or { return l.fail(err.msg()) }
	if stop := env.deadline_stop() {
		ch.stop_requested = stop
	}
	env.isotps << IsotpConn{
		ch:   ch
		chan: name
	}
	l.push_int(env.isotps.len - 1)
	return 1
}

fn (mut env Env) isotp_conn(h i64) ?&IsotpConn {
	if h < 0 || h >= env.isotps.len || env.isotps[h].closed {
		return none
	}
	return unsafe { &env.isotps[h] }
}

// isotp_failed raises a raw ISO-TP call's failure: the run's deadline when it cut the wait.
fn isotp_failed(l lua.State, err IError) i32 {
	if env_of(l).expired() {
		return timeout_at(l)
	}
	return l.fail(err.msg())
}

// __isotp_send(h, data): one whole message, on the wire when it returns
fn l_isotp_send(l lua.State) i32 {
	mut env := env_of(l)
	mut c := env.isotp_conn(l.arg_int(1)) or { return l.fail('bad isotp handle') }
	c.ch.send(l.arg_bytes(2)) or { return isotp_failed(l, err) }
	return 0
}

// __isotp_recv(h, timeout_ms): the next whole message, or nil when none came in time
fn l_isotp_recv(l lua.State) i32 {
	mut env := env_of(l)
	mut c := env.isotp_conn(l.arg_int(1)) or { return l.fail('bad isotp handle') }
	ms := l.arg_int_exact(2) or { return l.fail('isotp recv: timeout_ms is not an integer') }
	if ms < 0 {
		return l.fail('isotp recv: a wait of ${ms} ms; 0 looks, more waits')
	}
	msg := c.ch.recv(int(env.bounded(ms))) or {
		if env.expired() {
			return timeout_at(l) // the wait was cut
		}
		if c.ch.ending_of(err, false) == .waited_out {
			l.push_nil()
			return 1
		}
		return l.fail(err.msg())
	}
	l.push_bytes(msg)
	return 1
}

// __isotp_close(h): the channel let go; closing a closed one does nothing
fn l_isotp_close(l lua.State) i32 {
	mut env := env_of(l)
	h := l.arg_int(1)
	if h < 0 || h >= env.isotps.len {
		return l.fail('bad isotp handle')
	}
	if !env.isotps[h].closed {
		env.isotps[h].ch.close()
		env.isotps[h].closed = true
	}
	return 0
}

// __uds_timing(h): timeout_ms, p2_star_ms, margin_ms, pending_budget_ms as they stand
fn l_uds_timing(l lua.State) i32 {
	mut env := env_of(l)
	c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	t := c.cli.timing()
	l.push_int(t.timeout_ms)
	l.push_int(t.p2_star_ms)
	l.push_int(t.margin_ms)
	l.push_int(t.pending_budget_ms)
	return 4
}

// waits_args is the waits given in arguments first .. first + 3 (timeout_ms, p2_star_ms,
// margin_ms, pending_budget_ms; nil gives none).
fn waits_args(l lua.State, first int) !uds.Waits {
	mut given := []bool{len: 4}
	mut v := []int{len: 4}
	for i, name in ['timeout_ms', 'p2_star_ms', 'margin_ms', 'pending_budget_ms'] {
		if l.arg_is_nil(first + i) {
			continue
		}
		ms := l.arg_int_exact(first + i) or { return error('set_timing: ${name} is not an integer') }
		if ms < min_i32 || ms > max_i32 {
			return error('set_timing: ${name} ${ms} ms')
		}
		given[i] = true
		v[i] = int(ms)
	}
	return uds.Waits{
		timeout_ms:        if given[0] { ?int(v[0]) } else { none }
		p2_star_ms:        if given[1] { ?int(v[1]) } else { none }
		margin_ms:         if given[2] { ?int(v[2]) } else { none }
		pending_budget_ms: if given[3] { ?int(v[3]) } else { none }
	}
}

// __uds_set_timing(h, timeout_ms, p2_star_ms, margin_ms, pending_budget_ms): the waits given (nil
// keeps one), from the next request on; refused whole (uds.Client.state)
fn l_uds_set_timing(l lua.State) i32 {
	mut env := env_of(l)
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	w := waits_args(l, 2) or { return l.fail(err.msg()) }
	c.cli.state(w) or { return l.fail(err.msg()) }
	return 0
}

// __uds_timing_check(timeout_ms, p2_star_ms, margin_ms, pending_budget_ms): raises for waits a
// connection would refuse, each given one held to its range: uds.open asks before it opens
fn l_uds_timing_check(l lua.State) i32 {
	w := waits_args(l, 1) or { return l.fail(err.msg()) }
	mut probe := uds.Client{}
	probe.state(w) or { return l.fail(err.msg()) }
	return 0
}

// __uds_target(h): the logical address a DoIP connection's requests go to, a CAN one's request id
fn l_uds_target(l lua.State) i32 {
	mut env := env_of(l)
	c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	l.push_int(i64(c.ch.rx_id))
	return 1
}

// __uds_retarget(h, address): a DoIP connection's requests, and the answers it takes, to logical
// address `address` (nil: the channel's ecu_address); every handle of the connection moves with it,
// and another target starts again from the waits and sizes the script stated
fn l_uds_retarget(l lua.State) i32 {
	mut env := env_of(l)
	mut c := env.conn(int(l.arg_int(1))) or { return l.fail('bad uds handle') }
	if mut c.ch is doip.DoipClient {
		mut target := u16(0)
		if l.arg_is_nil(2) {
			ci := env.find_chan(c.chan) or { return l.fail(err.msg()) }
			target = env.chans[ci].carrier.ecu
		} else {
			a := l.arg_int_exact(2) or { return l.fail('retarget: the address is not an integer') }
			if a < 0 || a > 0xFFFF {
				return l.fail('retarget: ${a} is not a logical address (0 .. 0xFFFF)')
			}
			target = u16(a)
		}
		// under the connection's lock: a keep-alive is never in the middle of it
		c.mu.lock()
		if u32(target) != c.ch.rx_id {
			c.cli.another_ecu() // what it learned of the ECU before is that ECU's
		}
		c.ch.retarget(target)
		c.mu.unlock()
		return 0
	}
	return l.fail('retarget: a CAN connection reaches its ECU by its ids; retarget is a DoIP connection\'s')
}
