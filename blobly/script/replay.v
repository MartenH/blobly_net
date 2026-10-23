// The prelude's `replay` and `record`: a recording played onto channels of the run, and channels
// recorded to a candump file, through blobly/replay (the C ABI's bb_replay_* / bb_record_* call
// the same).
module script

import os
import time
import blobly.lua
import blobly.replay

fn (mut env Env) register_replay() {
	env.st.register('__replay_start', l_replay_start)
	env.st.register('__replay_ctl', l_replay_ctl)
	env.st.register('__replay_status', l_replay_status)
	env.st.register('__replay_wait', l_replay_wait)
	env.st.register('__replay_stop', l_replay_stop)
	env.st.register('__replay_notes', l_replay_notes)
	env.st.register('__record_start', l_record_start)
	env.st.register('__record_counts', l_record_counts)
	env.st.register('__record_stop', l_record_stop)
}

// stop_replays stops the replays and recordings the scripts started and left running, and
// answers what went wrong with a recording no script stopped itself: a host calls it once a
// script has run, before it stops the project under them; close calls it too.
pub fn (mut env Env) stop_replays() []string {
	for mut s in env.replays {
		s.stop()
	}
	mut errs := []string{}
	for mut r in env.records {
		if r.stopped() {
			continue
		}
		r.stop() or { errs << '${err}' }
	}
	return errs
}

// rows_named is the CAN rows Lua arguments first.. name, as blobly/replay takes them.
// replays_ended is whether every replay and recording the scripts started has let go of its
// buses: a stop that ran out of time leaves one letting go, and a host whose taps it uses waits.
pub fn (mut env Env) replays_ended() bool {
	for mut s in env.replays {
		if !s.ended() {
			return false
		}
	}
	for mut r in env.records {
		if !r.ended() {
			return false
		}
	}
	return true
}

// script_file is a path a script names, relative to its own directory, joined but not normalised:
// `link/..` is the link target's parent, as the filesystem walks it, not the link's.
fn (env &Env) script_file(p string) string {
	if env.script_path == '' || os.is_abs_path(p) {
		return p
	}
	return os.dir(env.script_path) + os.path_separator + p
}

fn (env &Env) rows_named(l lua.State, what string, first int) ![]replay.Row {
	mut rows := []replay.Row{}
	for a in first .. l.nargs() + 1 {
		name := l.arg_str(a)
		ci := env.find_chan(name)!
		c := env.chans[ci]
		if k := c.carrier.eth_kind() {
			return error('${what}("${name}"): a ${k} channel carries no CAN frames')
		}
		rows << replay.Row{
			name:  c.name
			iface: c.iface
			db:    c.db
			cfg:   c.replay
		}
	}
	return rows
}

fn l_replay_start(l lua.State) i32 {
	mut env := env_of(l)
	// __replay_start(source, speed, loop, paused, exclude, bus, channel...)
	rows := env.rows_named(l, 'replay.start', 7) or { return l.fail(err.msg()) }
	if l.arg_str(1).contains_u8(0) || l.arg_str(5).contains_u8(0) {
		return l.fail('replay.start: a source or a node name cannot carry a NUL')
	}
	if !l.arg_is_nil(2) && !(l.arg_num(2) > 0) {
		return l.fail('replay.start: speed ${l.arg_num(2)} — a rate above 0')
	}
	mut s := replay.start_rows(rows,
		source:  if l.arg_is_nil(1) { '' } else { env.script_file(l.arg_str(1)) }
		speed:   if l.arg_is_nil(2) { 0.0 } else { l.arg_num(2) }
		repeat:  if l.arg_is_nil(3) { i8(-1) } else { i8(if l.arg_bool(3) { 1 } else { 0 }) }
		paused:  l.arg_bool(4)
		exclude: if l.arg_is_nil(5) {
			?[]string(none)
		} else {
			?[]string(l.arg_str(5).split('\n').filter(it != ''))
		}
		bus:     if l.arg_is_nil(6) { '' } else { l.arg_str(6) }
		give_up: if env.deadline != 0 {
			fn [env] () bool {
				return env.expired()
			}
		} else {
			unsafe { nil }
		}
		open:    if isnil(env.reproducer) { env.opener } else { env.reproducer }
	) or { return l.fail(err.msg()) }
	env.replays << s
	if env.expired() {
		s.stop() // a start that outlasted the run's deadline plays nothing past it
		return timeout_at(l)
	}
	l.push_int(env.replays.len - 1)
	return 1
}

fn (env &Env) session(l lua.State) ?&replay.Session {
	h := int(l.arg_int(1))
	if h < 0 || h >= env.replays.len {
		return none
	}
	return env.replays[h]
}

fn l_replay_ctl(l lua.State) i32 {
	mut env := env_of(l)
	mut s := env.session(l) or { return l.fail('replay: bad handle') }
	what := l.arg_str(2)
	match what {
		'pause' { s.pause() or { return l.fail(err.msg()) } }
		'resume' { s.resume() or { return l.fail(err.msg()) } }
		'seek' { s.seek(l.arg_num(3)) or { return l.fail(err.msg()) } }
		'speed' { s.set_speed(l.arg_num(3)) or { return l.fail(err.msg()) } }
		'loop' { s.set_loop(l.arg_bool(3)) or { return l.fail(err.msg()) } }
		else { return l.fail('replay: no command ${what}') }
	}
	if env.expired() {
		return timeout_at(l) // the control waited past the run's deadline
	}
	return 0
}

fn push_replay_status(l lua.State, st replay.Status) {
	l.new_table()
	l.set_str('state', st.state.str())
	l.set_num('position', st.pos_s)
	l.set_num('duration', st.dur_s)
	l.set_num('speed', st.speed)
	l.set_bool('loop', st.repeat)
	l.set_int('passes', st.passes)
	l.set_int('sent', i64(st.sent))
	l.set_int('failed', i64(st.failed))
	l.set_str('error', st.error)
	l.set_bool('ended', st.ended)
}

fn l_replay_status(l lua.State) i32 {
	mut s := env_of(l).session(l) or { return l.fail('replay: bad handle') }
	push_replay_status(l, s.status())
	return 1
}

// l_replay_wait waits at most its ms (negative: for ever) for the replay to finish, in slices so
// the run's deadline cuts it.
fn l_replay_wait(l lua.State) i32 {
	mut env := env_of(l)
	mut s := env.session(l) or { return l.fail('replay: bad handle') }
	ms := l.arg_int(2)
	until := time.sys_mono_now() + u64(if ms > 0 { ms } else { 0 }) * 1_000_000
	for {
		left := if ms < 0 { i64(100) } else { i64(until - time.sys_mono_now()) / 1_000_000 }
		part := if left > 0 { env.bounded(if left > 100 { 100 } else { left }) } else { 0 }
		done := s.wait_done(int(part))
		if env.expired() {
			return timeout_at(l) // asked first: a replay the deadline ended is not one that finished
		}
		if done {
			l.push_bool(true)
			return 1
		}
		if ms >= 0 && time.sys_mono_now() >= until {
			l.push_bool(false)
			return 1
		}
	}
	return 0
}

fn l_replay_stop(l lua.State) i32 {
	mut env := env_of(l)
	mut s := env.session(l) or { return l.fail('replay: bad handle') }
	st := s.stop()
	if env.expired() {
		return timeout_at(l) // the stop waited past the run's deadline; the worker still ends
	}
	push_replay_status(l, st)
	return 1
}

fn l_replay_notes(l lua.State) i32 {
	s := env_of(l).session(l) or { return l.fail('replay: bad handle') }
	l.new_table()
	for i, n in s.notes {
		l.push_str(n)
		l.set_index(i + 1)
	}
	return 1
}

fn l_record_start(l lua.State) i32 {
	mut env := env_of(l)
	// __record_start(path, channel...)
	rows := env.rows_named(l, 'record.start', 2) or { return l.fail(err.msg()) }
	if l.arg_str(1).contains_u8(0) {
		return l.fail('record.start: a path cannot carry a NUL')
	}
	mut r := replay.record(env.script_file(l.arg_str(1)), rows.map(replay.Target{
		name:  it.name
		iface: it.iface
	})) or { return l.fail(err.msg()) }
	mut rec := r
	if env.deadline != 0 {
		rec.give_up = fn [env] () bool {
			return env.expired()
		}
	}
	env.records << rec
	if env.expired() {
		rec.stop() or {} // a start that outlasted the run's deadline records nothing past it
		return timeout_at(l)
	}
	l.push_int(env.records.len - 1)
	return 1
}

fn (env &Env) recorder(l lua.State) ?&replay.Recorder {
	h := int(l.arg_int(1))
	if h < 0 || h >= env.records.len {
		return none
	}
	return env.records[h]
}

fn push_counts(l lua.State, c replay.Counts) {
	l.new_table()
	l.set_int('frames', i64(c.frames))
	l.set_int('ours', i64(c.ours))
	l.set_int('theirs', i64(c.theirs))
	l.set_int('missed', i64(c.missed))
	l.set_int('dropped', i64(c.dropped))
}

fn l_record_counts(l lua.State) i32 {
	mut r := env_of(l).recorder(l) or { return l.fail('record: bad handle') }
	push_counts(l, r.counts())
	return 1
}

fn l_record_stop(l lua.State) i32 {
	mut env := env_of(l)
	mut r := env.recorder(l) or { return l.fail('record: bad handle') }
	c := r.stop() or {
		if env.expired() {
			return timeout_at(l)
		}
		return l.fail('record: ${err}')
	}
	if env.expired() {
		return timeout_at(l) // the stop waited past the run's deadline; the readers still end
	}
	push_counts(l, c)
	return 1
}
