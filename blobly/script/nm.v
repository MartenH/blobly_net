// Network management on a script's frames: every frame its handle on a channel reads goes
// through that channel's nm.Listener, made at its first frame where the host gave the channel an
// NM configuration (ChanInfo.nm: nm.configure, the panel's rule), or by nm.listen with a range the
// script states. The reading is as of the handle's latest read. Nothing is sent.
module script

import time
import blobly.lua
import blobly.nm
import blobly.transport

fn (mut env Env) register_nm() {
	env.st.register('__nm_listen', l_nm_listen)
	env.st.register('__nm_reading', l_nm_reading)
	env.st.register('__nm_wait', l_nm_wait)
}

// nm_saw feeds a frame the script's handle on `name` read, received at `t_ns`, to the channel's
// listener, made at its first frame where the channel has an NM configuration.
fn (mut env Env) nm_saw(name string, f transport.CanFrame, t_ns i64) {
	mut l := env.nm_rx[name] or {
		if name in env.nm_off {
			return
		}
		ci := env.find_chan(name) or { return }
		cfg := env.chans[ci].nm or {
			env.nm_off[name] = true
			return
		}
		l := nm.new_listener(cfg)
		env.nm_rx[name] = l
		l
	}
	l.feed(f.id, f.extended, f.rtr, f.data, clock_ms(t_ns))
}

// frame_read hands a frame the script's handle on `name` read, received at `t_ns`, to the
// channel's readings: J1939 and NM.
fn (mut env Env) frame_read(name string, f transport.CanFrame, t_ns i64) {
	env.j1939_saw(name, f)
	env.nm_saw(name, f, t_ns)
}

// read_idle: the handle on `name` had nothing queued; its readings move on to now.
fn (mut env Env) read_idle(name string) {
	env.j1939_idle(name)
	env.nm_idle(name)
}

// nm_idle: the handle on `name` had nothing queued, so its reading is complete to now.
fn (mut env Env) nm_idle(name string) {
	if mut l := env.nm_rx[name] {
		l.idle(clock_ms(i64(time.sys_mono_now())))
	}
}

// nm_of is the listener of channel `name`: the one reading, else one by the channel's
// configuration, refused where it has none.
fn (mut env Env) nm_of(name string) !&nm.Listener {
	env.bus_for(name)!
	if l := env.nm_rx[name] {
		return l
	}
	ci := env.find_chan(name)!
	cfg := env.chans[ci].nm or {
		return error('${name}: its wire has no NM configuration (a system.toml bus named like a row on it, the wire ARXML NM-PDU frames, or a row nm:); give nm.listen a range')
	}
	l := nm.new_listener(cfg)
	env.nm_rx[name] = l
	env.nm_off.delete(name)
	return l
}

// ReadOps is what read_loop does with a channel: receive within a wait (`recv`, an error
// 'timeout' for nothing, look_was_spent for a look stopped at its bound), hand a frame read to its
// readings (`frame`), say a read found nothing (`idle`), and whether the run's deadline has cut the
// wait (`expired`). Apart from the bus so a test drives the loop on synthetic events.
struct ReadOps {
	recv    fn (int) !transport.CanFrame @[required]
	frame   fn (transport.CanFrame)      @[required]
	idle    fn ()                        @[required]
	expired fn () bool                   @[required]
}

// read_loop reads until `deadline` (sys_mono_now) has passed or `done` holds. `done` is asked
// before every read, and so after every read, a frame or one that found nothing, and once more at
// the end: nothing a read changed goes unasked. With `read_first` the first read comes before the
// first ask and is a look (it waits for nothing), so a reading is brought up to now before it is
// asked. A read waits at most `slice_ms`; a deadline already past is one look. Answers whether
// `done` held; a wait the run's deadline cut is an error (timeout_note).
fn read_loop(ops ReadOps, deadline u64, read_first bool, slice_ms int, done fn () bool) !bool {
	mut first := true
	for {
		if !(first && read_first) && done() {
			return true
		}
		now := time.sys_mono_now()
		if now >= deadline && !first {
			return false
		}
		look := first && read_first
		first = false
		left := if now >= deadline || look { 0 } else { int((deadline - now) / 1_000_000) }
		f := ops.recv(if left < slice_ms { left } else { slice_ms }) or {
			if ops.expired() {
				return error(timeout_note)
			}
			if transport.look_was_spent(err) {
				continue
			}
			if err.msg() != 'timeout' {
				return err
			}
			ops.idle()
			if left == 0 && !look {
				// what a whole-millisecond wait cannot ask for is slept, not skipped
				rest := i64(deadline) - i64(time.sys_mono_now())
				if rest > 0 {
					time.sleep(rest * time.nanosecond)
				}
				return done()
			}
			continue
		}
		ops.frame(f)
	}
	return false
}

// read_until is read_loop on channel `name`: every frame read goes to the channel's readings
// (frame_read) and its E2E reader.
fn (mut env Env) read_until(name string, deadline u64, read_first bool, slice_ms int, done fn () bool) !bool {
	mut bus := env.bus_for(name)!
	ep := unsafe { &env }
	ops := ReadOps{
		recv:    fn [mut bus] (ms int) !transport.CanFrame {
			return bus.recv(ms)
		}
		frame:   fn [ep, name] (f transport.CanFrame) {
			mut e := unsafe { ep }
			e.frame_read(name, f, transport.received_now(f))
			_ = e.e2e_verdict(name, f) or { '' } // its message's E2E reader sees every frame the script reads
		}
		idle:    fn [ep, name] () {
			mut e := unsafe { ep }
			e.read_idle(name)
		}
		expired: fn [ep] () bool {
			return ep.expired()
		}
	}
	return read_loop(ops, deadline, read_first, slice_ms, done) or {
		if err.msg() == timeout_note {
			return err
		}
		return error('${name}: ${err.msg()}')
	}
}

// nm_read reads channel `name` into `lis` until `deadline` or `done` holds for its reading, which
// is asked after every read (read_loop); each read waits at most the cluster's timeout, so a node
// going silent is read as soon as it can be. Answers whether it held.
fn (mut env Env) nm_read(name string, lis &nm.Listener, deadline u64, done fn (nm.View) bool) !bool {
	slice := if lis.trk.cfg.timeout_ms < 100 { lis.trk.cfg.timeout_ms } else { 100 }
	return env.read_until(name, deadline, true, slice, nm_asks(lis, done))!
}

// nm_asks is a wait's question of `lis`, for read_loop: `done` of its reading as it is now, at
// every turn — nothing about the reading is cached, so nothing it changed goes unasked.
fn nm_asks(lis &nm.Listener, done fn (nm.View) bool) fn () bool {
	return fn [lis, done] () bool {
		return done(lis.reading())
	}
}

// __nm_listen(channel, lo, hi, ext, timeout_ms): read the channel as NM from now on, by its own
// configuration (lo below 0), else by the range given, a new reading
fn l_nm_listen(l lua.State) i32 {
	mut env := env_of(l)
	name := l.arg_str(1)
	lo := l.arg_int(2)
	if lo < 0 {
		if cur := env.nm_rx[name] {
			if cur.trk.cfg.source == .script {
				// back to the wire's own, a new reading; refused, the stated range reads on
				ci := env.find_chan(name) or { return l.fail(err.msg()) }
				if _ := env.chans[ci].nm {
				} else {
					return l.fail('${name}: its wire has no NM configuration to go back to; the stated range reads on')
				}
				env.nm_rx.delete(name)
			}
		}
		env.nm_of(name) or { return l.fail(err.msg()) }
		return 0
	}
	cfg := nm.explicit(lo, l.arg_int(3), l.arg_bool(4), l.arg_int(5)) or {
		return l.fail('nm.listen: ${err.msg()}')
	}
	env.bus_for(name) or { return l.fail(err.msg()) }
	env.nm_rx[name] = nm.new_listener(cfg)
	env.nm_off.delete(name)
	return 0
}

// __nm_reading(channel, window_ms) -> reading: the channel read for window_ms first (0: nothing)
fn l_nm_reading(l lua.State) i32 {
	mut env := env_of(l)
	name := l.arg_str(1)
	ms := env.bounded_window(ms_up(l, 2))
	deadline := time.sys_mono_now() + u64(if ms > 0 { ms } else { 0 }) * 1_000_000
	lis := env.nm_of(name) or { return l.fail(err.msg()) }
	if ms > 0 {
		env.nm_read(name, lis, deadline, fn (v nm.View) bool {
			return false
		}) or {
			if err.msg() == timeout_note {
				return timeout_at(l)
			}
			return l.fail(err.msg())
		}
	}
	push_nm_reading(l, lis)
	return 1
}

// __nm_wait(channel, timeout_ms, state, check_keepers, name...) -> reading, matched: the channel
// read until the reading is in `state` (and, with check_keepers, kept awake by exactly the names
// given, in any order) or the wait has passed
fn l_nm_wait(l lua.State) i32 {
	mut env := env_of(l)
	name := l.arg_str(1)
	ms := env.bounded(ms_up(l, 2))
	deadline := time.sys_mono_now() + u64(if ms > 0 { ms } else { 0 }) * 1_000_000
	state := l.arg_str(3)
	check := l.arg_bool(4)
	mut want := []string{}
	for i in 5 .. l.nargs() + 1 {
		want << l.arg_str(i)
	}
	want.sort()
	lis := env.nm_of(name) or { return l.fail(err.msg()) }
	matched := env.nm_read(name, lis, deadline, fn [state, check, want] (v nm.View) bool {
		if v.state.str() != state {
			return false
		}
		if !check {
			return true
		}
		mut got := v.keepers.clone()
		got.sort()
		return got == want
	}) or {
		if err.msg() == timeout_note {
			return timeout_at(l)
		}
		return l.fail(err.msg())
	}
	push_nm_reading(l, lis)
	l.push_bool(matched)
	return 2
}

fn push_names(l lua.State, key string, names []string) {
	l.new_table()
	for i, n in names {
		l.push_str(n)
		l.set_index(i + 1)
	}
	l.set_field(key)
}

// push_nm_reading pushes the listener's reading as a table, the fields Python's NmReading has
fn push_nm_reading(l lua.State, lis &nm.Listener) {
	v := lis.reading()
	at := lis.at_ms
	l.new_table()
	l.set_str('state', v.state.str())
	push_names(l, 'kept_awake_by', v.keepers)
	if v.woke_row >= 0 {
		l.set_str('woken_by', v.woke)
		l.set_num('woken_ms', at - v.woke_ago)
	}
	l.set_bool('woken_active', v.woke_active)
	push_names(l, 'repeat_requested_by', v.repeaters)
	l.new_table()
	mut missing := []string{}
	mut unknown := []string{}
	for i, r in v.rows {
		l.new_table()
		l.set_str('name', r.name)
		if r.nid >= 0 {
			l.set_int('nid', r.nid)
		}
		if r.has_id {
			l.set_int('can_id', r.id)
		}
		l.set_bool('ext', r.ext)
		l.set_bool('missing', r.missing)
		l.set_bool('unknown', r.unknown)
		l.set_bool('live', !r.missing && !r.stale)
		l.set_bool('keeps_awake', i in v.keeper_rows)
		l.set_int('count', i64(r.count))
		if !r.missing {
			l.set_num('last_heard_ms', at - r.ago_ms)
			l.new_table()
			l.set_int('raw', r.cbv)
			l.set_bool('repeat_request', r.cbv & nm.cbv_repeat_request != 0)
			l.set_bool('ready_to_sleep', r.cbv & nm.cbv_ready_to_sleep != 0)
			l.set_bool('active_wakeup', r.cbv & nm.cbv_active_wakeup != 0)
			l.set_bool('pn_info', r.cbv & nm.cbv_pn_info != 0)
			l.set_field('bits')
		}
		if r.mean_ms > 0 {
			l.set_num('cadence_ms', r.mean_ms)
		}
		if r.last_iv_ms > 0 {
			l.set_num('last_interval_ms', r.last_iv_ms)
		}
		if r.has_pn {
			l.set_int('pn', i64(r.pn))
		}
		l.set_index(i + 1)
		if r.missing {
			missing << r.name
		}
		if r.unknown {
			unknown << r.name
		}
	}
	l.set_field('nodes')
	push_names(l, 'missing', missing)
	push_names(l, 'unknown', unknown)
	l.set_bool('heard', v.heard)
	if v.heard {
		l.set_num('last_heard_ms', at - v.last_ago)
	}
	l.set_int('frames', i64(v.frames))
	l.set_int('malformed', i64(v.malformed))
	l.set_str('last_error', v.last_error)
	l.set_int('dropped', i64(v.dropped))
	l.set_int('timeout_ms', v.cfg.timeout_ms)
	l.set_bool('timeout_default', v.cfg.timeout_default)
	l.set_str('source', v.cfg.source.str())
	l.set_str('origin', v.cfg.origin)
	l.set_str('cluster', v.cfg.describe())
	l.set_num('t_ms', if at > 0 { at } else { 0.0 })
}
