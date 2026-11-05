// lin.v — bb.h's LIN block: the run's LIN buses (blobly/headless's rows), and a handle that is a
// tap on one of them or a lin.Row of its own on an address, as the Lua lin.open is. Handles as
// isotp.v's: a table under bb_mu, deleted on close, counted while a call is inside, a close
// ending the wait in progress. LIN is not a channel: nothing here touches a bus handle or bb_rows.
module main

import math
import sync.stdatomic
import time
import blobly.lin
import blobly.lindb
import blobly.transport

@[heap]
struct LinHandle {
	name string // the bus's name, or the address
	own  bool   // a row of the handle's own, stopped at close; else a tap on a run's bus
	gen  u64    // the run whose bus it taps
mut:
	row     &lin.Row
	tap     &lin.Tap
	ldf     ?lindb.Ldf
	users   i64
	closing i64
	// the last bb_lin_decode and the last bb_lin_read_status, which their accessors read
	frame_name string
	sigs       []lindb.SignalValue
	view       lin.RowView
	has_view   bool
}

__global (
	bb_lins     map[int]&LinHandle
	bb_lin_next int
)

// LinClosed is a receive bb_lin_close ended.
struct LinClosed {
	Error
}

// lin_rows is the run's LIN buses; refused before bb_start and after bb_stop.
fn lin_rows() ![]&lin.Row {
	if isnil(bb_run) {
		return error_with_code("not started: the LIN buses are the run's, from bb_start until bb_stop",
			int(bb_err_state))
	}
	return bb_run.lin_rows()
}

fn lin_row(r i32) !&lin.Row {
	rows := lin_rows()!
	if r < 0 || int(r) >= rows.len {
		return error('no LIN bus ${r} (the run has ${rows.len})')
	}
	return rows[int(r)]
}

// lin_role_code is bb.h's enum bb_lin_role for a role, by variant.
fn lin_role_code(r lin.Role) i32 {
	return i32(match r {
		.master { C.BB_LIN_ROLE_MASTER }
		.slave { C.BB_LIN_ROLE_SLAVE }
		.monitor { C.BB_LIN_ROLE_MONITOR }
	})
}

fn lin_role_of(v i32) !lin.Role {
	return if v == i32(C.BB_LIN_ROLE_MASTER) {
		lin.Role.master
	} else if v == i32(C.BB_LIN_ROLE_SLAVE) {
		lin.Role.slave
	} else if v == i32(C.BB_LIN_ROLE_MONITOR) {
		lin.Role.monitor
	} else {
		error('role ${v} is not an enum bb_lin_role (master, slave or monitor)')
	}
}

fn lin_state_code(s lin.State) i32 {
	return i32(match s {
		.active { C.BB_LIN_STATE_ACTIVE }
		.sleep { C.BB_LIN_STATE_SLEEP }
		.short { C.BB_LIN_STATE_SHORT }
	})
}

fn lin_event_code(e lin.Event) i32 {
	return i32(match e {
		.frame { C.BB_LIN_EVENT_FRAME }
		.wakeup { C.BB_LIN_EVENT_WAKEUP }
		.sleep { C.BB_LIN_EVENT_SLEEP }
	})
}

fn lin_origin_code(s lin.Src) i32 {
	return i32(match s {
		.remote { C.BB_LIN_ORIGIN_RX }
		.tester { C.BB_LIN_ORIGIN_TX }
		.sim { C.BB_LIN_ORIGIN_TX_S }
	})
}

fn lin_model_code(m lin.Model) i32 {
	return i32(match m {
		.classic { C.BB_LIN_MODEL_CLASSIC }
		.enhanced { C.BB_LIN_MODEL_ENHANCED }
	})
}

// lin_errs_bits is bb.h's BB_LIN_ERR_* bits for a set, flag by flag.
fn lin_errs_bits(e lin.Errs) u32 {
	mut b := u32(0)
	if e.has(.sync) {
		b |= u32(C.BB_LIN_ERR_SYNC)
	}
	if e.has(.parity) {
		b |= u32(C.BB_LIN_ERR_PARITY)
	}
	if e.has(.checksum) {
		b |= u32(C.BB_LIN_ERR_CHECKSUM)
	}
	if e.has(.framing) {
		b |= u32(C.BB_LIN_ERR_FRAMING)
	}
	if e.has(.short) {
		b |= u32(C.BB_LIN_ERR_SHORT)
	}
	if e.has(.no_response) {
		b |= u32(C.BB_LIN_ERR_NO_RESPONSE)
	}
	if e.has(.collision) {
		b |= u32(C.BB_LIN_ERR_COLLISION)
	}
	if e.has(.bit) {
		b |= u32(C.BB_LIN_ERR_BIT)
	}
	if e.has(.long) {
		b |= u32(C.BB_LIN_ERR_LONG)
	}
	return b
}

@[export: 'bb_lin_count']
pub fn bb_lin_count() i32 {
	rows := lin_rows() or { return refused(err) }
	ok()
	return i32(rows.len)
}

@[export: 'bb_lin_info']
pub fn bb_lin_info(r i32, out &C.bb_lin_bus) i32 {
	if isnil(out) {
		return fail(bb_err, 'lin_info: nowhere to put it')
	}
	lr := lin_row(r) or { return refused(err) }
	unsafe {
		out.role = lin_role_code(lr.spec.role)
		out.baud = i32(lr.baud)
	}
	return ok()
}

@[export: 'bb_lin_text']
pub fn bb_lin_text(r i32, which i32, buf &char, cap i32) i32 {
	lr := lin_row(r) or { return refused(err) }
	s := if which == i32(C.BB_LIN_TEXT_NAME) {
		lr.spec.name
	} else if which == i32(C.BB_LIN_TEXT_ADDRESS) {
		lr.spec.address
	} else if which == i32(C.BB_LIN_TEXT_LDF) {
		lr.spec.ldf
	} else {
		return fail(bb_err, 'lin_text: ${which} is not an enum bb_lin_text')
	}
	return put(s, buf, cap)
}

@[export: 'bb_lin_open']
pub fn bb_lin_open(r i32, address &char, role i32, ldf &char, baud i32) i32 {
	mut hd := &LinHandle{
		row: unsafe { nil }
		tap: unsafe { nil }
	}
	if r >= 0 {
		if !isnil(address) || !isnil(ldf) || role != i32(C.BB_LIN_ROLE_PROJECT) || baud != 0 {
			return fail(bb_err, "lin_open: a run's LIN bus has its role, LDF and rate from the project file; give NULL, BB_LIN_ROLE_PROJECT, NULL, 0")
		}
		mut lr := lin_row(r) or { return refused(err) }
		tap := lr.tap() or { return fail(bb_err, 'lin_open: ${err.msg()}') }
		bb_mu.lock()
		gen := bb_run_gen
		bb_mu.unlock()
		hd = &LinHandle{
			name: lr.spec.name
			gen:  gen
			row:  lr
			tap:  tap
			ldf:  lr.ldf()
		}
	} else if r == -1 {
		if isnil(address) {
			return fail(bb_err, 'lin_open: row -1 opens an address, and none was given')
		}
		addr := unsafe { cstring_to_vstring(address) }
		ro := lin_role_of(role) or { return fail(bb_err, 'lin_open: ${err.msg()}') }
		mut lr := lin.start_row(lin.RowSpec{
			name:    addr
			address: addr
			baud:    int(baud)
			ldf:     if isnil(ldf) { '' } else { unsafe { cstring_to_vstring(ldf) } }
			role:    ro
		}, lin.RowOpts{}) or { return fail(bb_err, 'lin_open: ${err.msg()}') }
		tap := lr.tap() or {
			lr.stop()
			return fail(bb_err, 'lin_open: ${err.msg()}')
		}
		hd = &LinHandle{
			name: addr
			own:  true
			row:  lr
			tap:  tap
			ldf:  lr.ldf()
		}
	} else {
		return fail(bb_err, "lin_open: row ${r}: a run's LIN bus is 0 or more, an address -1")
	}
	bb_mu.lock()
	h := bb_lin_next
	bb_lin_next++
	bb_lins[h] = hd
	bb_mu.unlock()
	ok()
	return i32(h)
}

// with_lin runs `call` on the open handle `h`, counted in use; a tap on a run's bus that has
// stopped is refused.
fn with_lin(h i32, call fn (mut hd LinHandle) i32) i32 {
	bb_mu.lock()
	mut hd := bb_lins[int(h)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no open LIN handle ${h}')
	}
	live := hd.own || (bb_dbs_live && bb_run_gen == hd.gen)
	stdatomic.add_i64(&hd.users, 1)
	bb_mu.unlock()
	defer {
		stdatomic.add_i64(&hd.users, -1)
	}
	if stdatomic.load_i64(&hd.closing) != 0 {
		return fail(bb_err_handle, 'the LIN handle was closed')
	}
	if !live {
		return fail(bb_err_state, "LIN handle ${h} taps ${hd.name} of a run that has stopped; open one on this run's bus")
	}
	return call(mut hd)
}

// lin_failed is bb.h's code for a call on `hd` that failed: a run's bus stopped under it is
// BB_ERR_STATE, anything else (a role refused, a value refused, a port gone) BB_ERR.
fn lin_failed(hd &LinHandle, err IError) i32 {
	if err is LinClosed {
		return fail(bb_err_handle, 'the LIN handle was closed')
	}
	if err is transport.CarrierGone && !hd.own {
		bb_mu.lock()
		live := bb_dbs_live && bb_run_gen == hd.gen
		bb_mu.unlock()
		if !live {
			return fail(bb_err_state, '${hd.name}: its run has stopped')
		}
	}
	return fail(bb_err, '${hd.name}: ${err.msg()}')
}

// recv is the tap's next frame within `ms` (0 a look, < 0 for ever), asked in slices of
// recv_slice_ms so a close on another thread ends it.
fn (mut hd LinHandle) recv(ms int) !lin.Frame {
	if ms == 0 {
		return hd.tap.recv(0)
	}
	until := time.sys_mono_now() + u64(if ms > 0 { ms } else { 0 }) * 1_000_000
	for {
		if stdatomic.load_i64(&hd.closing) != 0 {
			return LinClosed{}
		}
		mut part := recv_slice_ms
		if ms > 0 {
			now := time.sys_mono_now()
			if now >= until {
				return lin.Timeout{}
			}
			left := int((until - now + 999_999) / 1_000_000)
			if left < part {
				part = left
			}
		}
		f := hd.tap.recv(part) or {
			if err is lin.Timeout {
				continue
			}
			return err
		}
		return f
	}
	return lin.Timeout{}
}

@[export: 'bb_lin_recv']
pub fn bb_lin_recv(h i32, timeout_ms i32, out &C.bb_lin_frame) i32 {
	if isnil(out) {
		return fail(bb_err, 'lin_recv: nowhere to put the frame')
	}
	return with_lin(h, fn [timeout_ms, out] (mut hd LinHandle) i32 {
		f := hd.recv(int(timeout_ms)) or {
			if err is lin.Timeout {
				ok()
				return bb_none
			}
			return lin_failed(hd, err)
		}
		if f.data.len > lin.max_data {
			return fail(bb_err, 'lin_recv: a frame of ${f.data.len} data bytes does not fit bb_lin_frame (8 at most)')
		}
		unsafe {
			out.id = f.id
			out.pid = f.pid
			out.len = u8(f.data.len)
			out.checksum = f.checksum
			for i in 0 .. lin.max_data {
				out.data[i] = if i < f.data.len { f.data[i] } else { u8(0) }
			}
			out.model = lin_model_code(f.model)
			out.errs = lin_errs_bits(f.errs)
			out.event = lin_event_code(f.event)
			out.origin = lin_origin_code(f.src)
			out.t_ns = f.t_ns
		}
		return ok()
	})
}

// bb_lin_decode is the Lua lin.recv's decode: the LDF's response for the id (an event-triggered
// frame's by its first byte), its signals only for an error-free frame.
@[export: 'bb_lin_decode']
pub fn bb_lin_decode(h i32, f &C.bb_lin_frame, signals &i32) i32 {
	if isnil(f) || isnil(signals) {
		return fail(bb_err, 'lin_decode: no frame, or nowhere to put its signal count')
	}
	return with_lin(h, fn [f, signals] (mut hd LinHandle) i32 {
		hd.frame_name = ''
		hd.sigs = []lindb.SignalValue{}
		unsafe {
			*signals = 0
		}
		n := int(f.len)
		if n > lin.max_data {
			return fail(bb_err, 'lin_decode: a frame carries at most 8 data bytes, not ${n}')
		}
		mut data := []u8{len: n}
		for i in 0 .. n {
			data[i] = f.data[i]
		}
		x := hd.ldf or {
			ok()
			return bb_none
		}
		if f.event == i32(C.BB_LIN_EVENT_WAKEUP) {
			ok()
			return bb_none
		}
		resp := x.response_for(f.id, data) or {
			ok()
			return bb_none
		}
		hd.frame_name = resp.name
		if lf := resp.frame {
			if f.errs == 0 {
				hd.sigs = x.decode(lf, data)
			}
		}
		unsafe {
			*signals = i32(hd.sigs.len)
		}
		return ok()
	})
}

@[export: 'bb_lin_frame_name']
pub fn bb_lin_frame_name(h i32, buf &char, cap i32) i32 {
	return with_lin(h, fn [buf, cap] (mut hd LinHandle) i32 {
		return put(hd.frame_name, buf, cap)
	})
}

@[export: 'bb_lin_frame_id']
pub fn bb_lin_frame_id(h i32, name &char) i32 {
	if isnil(name) {
		return fail(bb_err, 'lin_frame_id: no name')
	}
	n := unsafe { cstring_to_vstring(name) }
	return with_lin(h, fn [n] (mut hd LinHandle) i32 {
		x := hd.ldf or { return fail(bb_err, '${hd.name} has no LDF, so no frame `${n}`') }
		fr := x.frame(n) or { return fail(bb_err, 'the LDF has no frame `${n}`') }
		ok()
		return i32(fr.id)
	})
}

// lin_sig is signal k of the handle's last decode.
fn (hd &LinHandle) lin_sig(k i32) !lindb.SignalValue {
	if k < 0 || int(k) >= hd.sigs.len {
		return error('the last decode holds no signal ${k} (it holds ${hd.sigs.len}; bb_lin_decode makes it)')
	}
	return hd.sigs[int(k)]
}

@[export: 'bb_lin_signal_info']
pub fn bb_lin_signal_info(h i32, k i32, out &C.bb_lin_signal) i32 {
	if isnil(out) {
		return fail(bb_err, 'lin_signal_info: nowhere to put it')
	}
	return with_lin(h, fn [k, out] (mut hd LinHandle) i32 {
		s := hd.lin_sig(k) or { return fail(bb_err, err.msg()) }
		unsafe {
			out.raw = s.raw
			out.physical = s.physical or { 0.0 }
			out.has_physical = u8(s.physical != none)
			out.is_array = u8(s.is_array)
			out.bytes = i32(s.bytes.len)
		}
		return ok()
	})
}

@[export: 'bb_lin_signal_text']
pub fn bb_lin_signal_text(h i32, k i32, which i32, buf &char, cap i32) i32 {
	return with_lin(h, fn [k, which, buf, cap] (mut hd LinHandle) i32 {
		s := hd.lin_sig(k) or { return fail(bb_err, err.msg()) }
		t := if which == i32(C.BB_LIN_SIGNAL_NAME) {
			s.name
		} else if which == i32(C.BB_LIN_SIGNAL_TEXT) {
			s.text
		} else if which == i32(C.BB_LIN_SIGNAL_UNIT) {
			s.unit
		} else {
			return fail(bb_err, 'lin_signal_text: ${which} is not an enum bb_lin_signal_text')
		}
		return put(t, buf, cap)
	})
}

@[export: 'bb_lin_signal_bytes']
pub fn bb_lin_signal_bytes(h i32, k i32, buf &u8, cap i32) i32 {
	return with_lin(h, fn [k, buf, cap] (mut hd LinHandle) i32 {
		s := hd.lin_sig(k) or { return fail(bb_err, err.msg()) }
		return put_bytes(s.bytes, buf, cap)
	})
}

@[export: 'bb_lin_header']
pub fn bb_lin_header(h i32, id i32) i32 {
	if id < 0 || id > i32(lin.max_id) {
		return fail(bb_err, 'lin_header: id ${id} is not 0..63')
	}
	return with_lin(h, fn [id] (mut hd LinHandle) i32 {
		hd.row.header(u8(id)) or { return lin_failed(hd, err) }
		return ok()
	})
}

// lin_raw is a raw value given as a double: a whole number 0 .. 2^53, which a double holds exactly.
fn lin_raw(signal string, v f64) !lindb.Value {
	if math.is_nan(v) || math.is_inf(v, 0) || v != math.floor(v) || v < 0 || v > 9007199254740992.0 {
		return error('the raw value of ${signal} is a whole number 0 .. 2^53, not ${v}')
	}
	return lindb.Value(u64(v))
}

@[export: 'bb_lin_set_signal']
pub fn bb_lin_set_signal(h i32, signal &char, kind i32, value f64, data &u8, n i32) i32 {
	if isnil(signal) {
		return fail(bb_err, 'lin_set_signal: no signal name')
	}
	name := unsafe { cstring_to_vstring(signal) }
	b := bytes_in('lin_set_signal', data, n) or { return fail(bb_err, err.msg()) }
	return with_lin(h, fn [name, kind, value, b] (mut hd LinHandle) i32 {
		v := if kind == i32(C.BB_LIN_VALUE_NUMBER) {
			if lin.has_physical(hd.ldf, name) {
				lindb.Value(value)
			} else {
				lin_raw(name, value) or {
					return fail(bb_err, 'lin_set_signal: ${err.msg()} (its encoding has no physical range)')
				}
			}
		} else if kind == i32(C.BB_LIN_VALUE_RAW) {
			lin_raw(name, value) or { return fail(bb_err, 'lin_set_signal: ${err.msg()}') }
		} else if kind == i32(C.BB_LIN_VALUE_TEXT) {
			lindb.Value(b.bytestr())
		} else if kind == i32(C.BB_LIN_VALUE_BYTES) {
			lindb.Value(b)
		} else {
			return fail(bb_err, 'lin_set_signal: kind ${kind} is not an enum bb_lin_value')
		}
		hd.row.set_signal(name, v) or { return lin_failed(hd, err) }
		return ok()
	})
}

@[export: 'bb_lin_schedule']
pub fn bb_lin_schedule(h i32, name &char) i32 {
	if isnil(name) {
		return fail(bb_err, 'lin_schedule: no table name')
	}
	n := unsafe { cstring_to_vstring(name) }
	return with_lin(h, fn [n] (mut hd LinHandle) i32 {
		hd.row.schedule(n) or { return lin_failed(hd, err) }
		return ok()
	})
}

@[export: 'bb_lin_stop_schedule']
pub fn bb_lin_stop_schedule(h i32) i32 {
	return with_lin(h, fn (mut hd LinHandle) i32 {
		if !hd.row.stop_schedule() {
			ok()
			return bb_releasing
		}
		return ok()
	})
}

@[export: 'bb_lin_wakeup']
pub fn bb_lin_wakeup(h i32) i32 {
	return with_lin(h, fn (mut hd LinHandle) i32 {
		hd.row.wakeup() or { return lin_failed(hd, err) }
		return ok()
	})
}

@[export: 'bb_lin_sleep']
pub fn bb_lin_sleep(h i32) i32 {
	return with_lin(h, fn (mut hd LinHandle) i32 {
		hd.row.sleep() or { return lin_failed(hd, err) }
		return ok()
	})
}

@[export: 'bb_lin_read_status']
pub fn bb_lin_read_status(h i32, out &C.bb_lin_status) i32 {
	if isnil(out) {
		return fail(bb_err, 'lin_read_status: nowhere to put it')
	}
	return with_lin(h, fn [out] (mut hd LinHandle) i32 {
		v := hd.row.view()
		hd.view = v
		hd.has_view = true
		unsafe {
			out.role = lin_role_code(v.role)
			out.state = lin_state_code(v.state)
			out.frames = i32(v.frames.len)
			out.notes = i32(v.notes.len)
			out.load = v.load_percent
			out.dropped = v.dropped
			out.sched_sent = v.sched.sent
			out.sched_failed = v.sched.failed
			out.sched_late = v.sched.late
			out.sched_running = u8(v.sched.running)
		}
		return ok()
	})
}

@[export: 'bb_lin_status_id']
pub fn bb_lin_status_id(h i32, k i32, out &C.bb_lin_id) i32 {
	if isnil(out) {
		return fail(bb_err, 'lin_status_id: nowhere to put it')
	}
	return with_lin(h, fn [k, out] (mut hd LinHandle) i32 {
		if !hd.has_view {
			return fail(bb_err_state, 'no LIN status taken on handle: bb_lin_read_status takes it')
		}
		if k < 0 || int(k) >= hd.view.frames.len {
			return fail(bb_err, 'the LIN status holds no frame id row ${k} (it holds ${hd.view.frames.len})')
		}
		fr := hd.view.frames[int(k)]
		unsafe {
			out.id = fr.id
			out.count = fr.count
			out.errors = fr.errors
			out.cadence_ms = fr.cadence_ms
		}
		return ok()
	})
}

@[export: 'bb_lin_status_text']
pub fn bb_lin_status_text(h i32, which i32, k i32, buf &char, cap i32) i32 {
	return with_lin(h, fn [which, k, buf, cap] (mut hd LinHandle) i32 {
		if !hd.has_view {
			return fail(bb_err_state, 'no LIN status taken on handle: bb_lin_read_status takes it')
		}
		v := hd.view
		s := if which == i32(C.BB_LIN_STATUS_NAME) {
			v.name
		} else if which == i32(C.BB_LIN_STATUS_ADDRESS) {
			v.address
		} else if which == i32(C.BB_LIN_STATUS_SCHEDULE) {
			v.schedule
		} else if which == i32(C.BB_LIN_STATUS_NOTE) {
			if k < 0 || int(k) >= v.notes.len {
				return fail(bb_err, 'the LIN status holds no note ${k} (it holds ${v.notes.len})')
			}
			v.notes[int(k)]
		} else if which == i32(C.BB_LIN_STATUS_FRAME) {
			if k < 0 || int(k) >= v.frames.len {
				return fail(bb_err, 'the LIN status holds no frame id row ${k} (it holds ${v.frames.len})')
			}
			v.frames[int(k)].name
		} else {
			return fail(bb_err, 'lin_status_text: ${which} is not an enum bb_lin_status_text')
		}
		return put(s, buf, cap)
	})
}

@[export: 'bb_lin_diagnostics']
pub fn bb_lin_diagnostics(h i32, out &C.bb_diagnostics) i32 {
	if isnil(out) {
		return fail(bb_err, 'lin_diagnostics: nowhere to put them')
	}
	return with_lin(h, fn [out] (mut hd LinHandle) i32 {
		d := hd.row.diagnostics()
		unsafe {
			out.dropped = d.dropped + hd.tap.dropped()
			out.bus_errors = d.bus_errors
			out.decode_errors = d.decode_errors
		}
		return ok()
	})
}

// bb_lin_close: out of the table at once; the row of its own stopped, or the run's untapped, once
// the call inside it has left, which its `closing` ends within a slice (20 ms).
@[export: 'bb_lin_close']
pub fn bb_lin_close(h i32) i32 {
	bb_mu.lock()
	mut hd := bb_lins[int(h)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no open LIN handle ${h}')
	}
	bb_lins.delete(int(h))
	bb_mu.unlock()
	stdatomic.store_i64(&hd.closing, 1)
	for stdatomic.load_i64(&hd.users) > 0 {
		time.sleep(time.millisecond)
	}
	if hd.own {
		hd.row.stop()
	} else {
		hd.row.untap(hd.tap)
	}
	return ok()
}
