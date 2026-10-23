// Replay and recording to a file (bb.h's "Replay and recording" block): blobly/replay, the
// sessions the Lua replay.start and record.start drive.
module main

import os
import blobly.headless
import blobly.replay

__global (
	// under bb_mu: a control call may come from any thread while the driver starts and stops
	bb_replays     map[int]&replay.Session
	bb_replay_next int
	bb_records     map[int]&replay.Recorder
	bb_record_next int
)

// run_rows is the run's CAN rows rows[0..n-1], refused for one that is not one.
fn run_rows(what string, rows &i32, n i32) ![]headless.Channel {
	if isnil(bb_run) {
		return error('${what}: not started — it plays onto rows of the run')
	}
	if n <= 0 || isnil(rows) {
		return error('${what}: no rows')
	}
	chans := bb_run.chans
	mut out := []headless.Channel{}
	for k in 0 .. int(n) {
		i := int(unsafe { rows[k] })
		if i < 0 || i >= chans.len {
			return error('${what}: no channel ${i}')
		}
		if chans[i].cfg.is_eth() {
			return error('${what}("${chans[i].cfg.name}"): a DoIP or SOME/IP row carries no CAN frames')
		}
		out << chans[i]
	}
	return out
}

@[export: 'bb_replay_defaults']
pub fn bb_replay_defaults(o &C.bb_replay_opts) i32 {
	if isnil(o) {
		return fail(bb_err, 'replay_defaults: nowhere to put the options')
	}
	unsafe {
		o.source = nil
		o.speed = 0
		o.loop = -1
		o.paused = 0
		o.exclude = nil
		o.bus = nil
	}
	return ok()
}

@[export: 'bb_replay_start']
pub fn bb_replay_start(rows &i32, n i32, o &C.bb_replay_opts) i32 {
	if isnil(o) {
		return fail(bb_err, 'replay_start: no options (bb_replay_defaults fills them)')
	}
	chans := run_rows('replay', rows, n) or {
		return fail(if isnil(bb_run) { bb_err_state } else { bb_err }, err.msg())
	}
	if o.loop < -1 || o.loop > 1 {
		return fail(bb_err, 'replay: loop ${o.loop} — 1, 0, or -1 for the rows\'')
	}
	if o.speed != o.speed {
		return fail(bb_err, 'replay: speed is not a number')
	}
	dir := os.dir(bb_path)
	exclude := vstr(o.exclude)
	s := replay.start_rows(chans.map(replay.Row{
		name:  it.cfg.name
		iface: it.cfg.iface_with_bitrate()
		db:    it.db
		cfg:   it.replay_cfg(dir)
	}),
		source:  vstr(o.source)
		speed:   if o.speed > 0 { o.speed } else { 0.0 }
		repeat:  i8(o.loop)
		paused:  o.paused != 0
		exclude: if isnil(o.exclude) {
			?[]string(none)
		} else {
			?[]string(exclude.split('\n').filter(it != ''))
		}
		bus:     vstr(o.bus)
	) or { return fail(bb_err, err.msg()) }
	bb_mu.lock()
	h := bb_replay_next
	bb_replay_next++
	bb_replays[h] = s
	bb_mu.unlock()
	ok()
	return i32(h)
}

fn session(r i32) ?&replay.Session {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	return bb_replays[int(r)] or { return none }
}

@[export: 'bb_replay_notes']
pub fn bb_replay_notes(r i32, buf &char, cap i32) i32 {
	s := session(r) or { return fail(bb_err_handle, 'no replay ${r}') }
	return put(s.notes.join('\n'), buf, cap)
}

// control is a command to replay `r`, applied before it returns.
fn control(r i32, cmd fn (mut s replay.Session) !) i32 {
	mut s := session(r) or { return fail(bb_err_handle, 'no replay ${r}') }
	cmd(mut s) or { return fail(bb_err, err.msg()) }
	return ok()
}

@[export: 'bb_replay_pause']
pub fn bb_replay_pause(r i32, paused i32) i32 {
	return control(r, fn [paused] (mut s replay.Session) ! {
		if paused != 0 {
			s.pause()!
		} else {
			s.resume()!
		}
	})
}

@[export: 'bb_replay_seek']
pub fn bb_replay_seek(r i32, pos f64) i32 {
	return control(r, fn [pos] (mut s replay.Session) ! {
		s.seek(pos)!
	})
}

@[export: 'bb_replay_speed']
pub fn bb_replay_speed(r i32, speed f64) i32 {
	return control(r, fn [speed] (mut s replay.Session) ! {
		s.set_speed(speed)!
	})
}

@[export: 'bb_replay_loop']
pub fn bb_replay_loop(r i32, on i32) i32 {
	return control(r, fn [on] (mut s replay.Session) ! {
		s.set_loop(on != 0)!
	})
}

fn put_status(out &C.bb_replay_info, st replay.Status) {
	if isnil(out) {
		return
	}
	unsafe {
		out.state = i32(match st.state {
			.stopped { C.BB_REPLAY_STOPPED }
			.playing { C.BB_REPLAY_PLAYING }
			.paused { C.BB_REPLAY_PAUSED }
			.finished { C.BB_REPLAY_FINISHED }
		})
		out.loop = u8(st.repeat)
		out.ended = u8(st.ended)
		out.passes = i32(st.passes)
		out.position_s = st.pos_s
		out.duration_s = st.dur_s
		out.speed = st.speed
		out.sent = i64(st.sent)
		out.failed = i64(st.failed)
	}
}

@[export: 'bb_replay_status']
pub fn bb_replay_status(r i32, out &C.bb_replay_info) i32 {
	mut s := session(r) or { return fail(bb_err_handle, 'no replay ${r}') }
	put_status(out, s.status())
	return ok()
}

@[export: 'bb_replay_error']
pub fn bb_replay_error(r i32, buf &char, cap i32) i32 {
	mut s := session(r) or { return fail(bb_err_handle, 'no replay ${r}') }
	return put(s.status().error, buf, cap)
}

@[export: 'bb_replay_wait']
pub fn bb_replay_wait(r i32, timeout_ms i32) i32 {
	mut s := session(r) or { return fail(bb_err_handle, 'no replay ${r}') }
	if s.wait_done(int(timeout_ms)) {
		return ok()
	}
	ok()
	return bb_none
}

// bb_replay_stop keeps the handle: what it did stays readable, and its controls refuse
@[export: 'bb_replay_stop']
pub fn bb_replay_stop(r i32, out &C.bb_replay_info) i32 {
	mut s := session(r) or { return fail(bb_err_handle, 'no replay ${r}') }
	put_status(out, s.stop())
	return ok()
}

@[export: 'bb_record_start']
pub fn bb_record_start(rows &i32, n i32, path &char) i32 {
	if isnil(path) || vstr(path) == '' {
		return fail(bb_err, 'record_start: no path')
	}
	chans := run_rows('record', rows, n) or {
		return fail(if isnil(bb_run) { bb_err_state } else { bb_err }, err.msg())
	}
	rec := replay.record(vstr(path), chans.map(replay.Target{
		name:  it.cfg.name
		iface: it.cfg.iface_with_bitrate()
	})) or { return fail(bb_err, err.msg()) }
	bb_mu.lock()
	h := bb_record_next
	bb_record_next++
	bb_records[h] = rec
	bb_mu.unlock()
	ok()
	return i32(h)
}

fn put_counts(out &C.bb_record_report, c replay.Counts) {
	if isnil(out) {
		return
	}
	unsafe {
		out.frames = i64(c.frames)
		out.ours = i64(c.ours)
		out.theirs = i64(c.theirs)
		out.missed = i64(c.missed)
		out.dropped = i64(c.dropped)
	}
}

@[export: 'bb_record_counts']
pub fn bb_record_counts(h i32, out &C.bb_record_report) i32 {
	bb_mu.lock()
	mut rec := bb_records[int(h)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no recording ${h}')
	}
	bb_mu.unlock()
	put_counts(out, rec.counts())
	return ok()
}

// bb_record_stop keeps the handle, as bb_replay_stop does: its counts stay readable
@[export: 'bb_record_stop']
pub fn bb_record_stop(h i32, out &C.bb_record_report) i32 {
	bb_mu.lock()
	mut rec := bb_records[int(h)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no recording ${h}')
	}
	bb_mu.unlock()
	c := rec.stop() or {
		put_counts(out, rec.counts())
		return fail(bb_err, err.msg())
	}
	put_counts(out, c)
	return ok()
}

// replays_stop stops every replay and recording (bb_stop), so none plays into or records the next
// run.
fn replays_stop() {
	bb_mu.lock()
	mut ss := bb_replays.values()
	mut rs := bb_records.values()
	bb_mu.unlock()
	for mut s in ss {
		s.stop()
	}
	for mut r in rs {
		r.stop() or {}
	}
}

// replays_released is whether every replay and recording has let go of its buses: a stop that ran
// out of time leaves one letting go, and the next run waits for it.
fn replays_released() bool {
	bb_mu.lock()
	mut ss := bb_replays.values()
	mut rs := bb_records.values()
	bb_mu.unlock()
	for mut s in ss {
		if !s.ended() {
			return false
		}
	}
	for mut r in rs {
		if !r.ended() {
			return false
		}
	}
	return true
}
