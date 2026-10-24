// Background cyclic senders (bb.h's "Background cyclic senders" block): blobly/cyclic, each one of
// the run's loops (headless.Run.start_cyclic) on a bus handle of its own.
module main

import blobly.cyclic
import blobly.transport

struct CyclicHandle {
	run u64 // the run it was started in
mut:
	s &cyclic.Sender
}

__global (
	bb_cyclic      map[int]&CyclicHandle // under bb_mu
	bb_cyclic_next int
)

// cyclic_retire lets go of the handles of earlier runs, whose loops their run's stop ended; the
// caller holds bb_mu.
fn cyclic_retire(run u64) {
	for k, h in bb_cyclic {
		if h.run != run {
			bb_cyclic.delete(k)
		}
	}
}

// cyclic_start opens a bus of its own on CAN row `row` of the started run and starts `spec` on it.
fn cyclic_start(row i32, spec cyclic.Spec) i32 {
	bb_mu.lock()
	mut r := bb_gen_run
	run := bb_run_gen
	rows := bb_run_rows
	bb_mu.unlock()
	if isnil(r) {
		return fail(bb_err_state, "not started: a background sender is one of the run's loops, from bb_start")
	}
	if row < 0 || int(row) >= rows.len {
		return fail(bb_err, 'no channel ${row}')
	}
	ch := rows[int(row)]
	if ch.is_eth() {
		return fail(bb_err, '${ch.name} is a DoIP or SOME/IP row, which carries no CAN frames')
	}
	spec.check() or { return fail(bb_err, '${ch.name}: ${err.msg()}') }
	iface := ch.iface_with_bitrate()
	bus := transport.open(iface) or { return fail(bb_err, '${iface}: ${err.msg()}') }
	s := r.start_cyclic(bus, spec) or { return fail(bb_err_state, '${ch.name}: ${err.msg()}') }
	bb_mu.lock()
	c := bb_cyclic_next
	bb_cyclic_next++
	bb_cyclic[c] = &CyclicHandle{
		run: run
		s:   s
	}
	bb_mu.unlock()
	ok()
	return i32(c)
}

@[export: 'bb_cyclic_start']
pub fn bb_cyclic_start(row i32, f &C.bb_frame, period_ms i32) i32 {
	if isnil(f) {
		return fail(bb_err, 'cyclic_start: no frame')
	}
	n := int(f.len)
	if n > 64 {
		return fail(bb_err, 'cyclic_start: a payload is at most 64 bytes, not ${n}')
	}
	if f.rtr != 0 || f.esi != 0 {
		return fail(bb_err, 'cyclic_start: a background sender sends data frames, with no rtr or esi')
	}
	mut data := []u8{len: n}
	for i in 0 .. n {
		data[i] = f.data[i]
	}
	// stated as bb_bus_send reads the flags: fd unset takes the wire's declared format
	format := if f.fd == 0 {
		transport.FrameFormat.wire
	} else if f.brs != 0 {
		transport.FrameFormat.fd_brs
	} else {
		transport.FrameFormat.fd
	}
	if f.fd == 0 && f.brs != 0 {
		return fail(bb_err, 'cyclic_start: brs without fd is no frame a controller sends')
	}
	return cyclic_start(row, cyclic.Spec{
		id:        f.id
		ext:       f.ext != 0
		data:      data
		format:    format
		period_ms: int(period_ms)
	})
}

// values_of is the host's n signal names and values.
fn values_of(n i32, signals &&char, values &f64) !map[string]f64 {
	if n < 0 || (n > 0 && (isnil(signals) || isnil(values))) {
		return error('${n} signals, and no arrays of them')
	}
	mut out := map[string]f64{}
	for i in 0 .. int(n) {
		p := unsafe { signals[i] }
		if isnil(p) {
			return error('signal name ${i} is NULL')
		}
		out[unsafe { cstring_to_vstring(p) }] = unsafe { values[i] }
	}
	return out
}

@[export: 'bb_cyclic_start_message']
pub fn bb_cyclic_start_message(row i32, m i32, n i32, signals &&char, values &f64, e2e i32, period_ms i32) i32 {
	msg := message(row, m) or { return refused(err) }
	vs := values_of(n, signals, values) or { return fail(bb_err, 'cyclic_start_message: ${err.msg()}') }
	return cyclic_start(row, cyclic.Spec{
		by_message: true
		message:    msg
		values:     vs
		e2e:        e2e != 0
		period_ms:  int(period_ms)
	})
}

// with_cyclic is background sender c, or why there is none.
fn with_cyclic(c i32) !&cyclic.Sender {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	h := bb_cyclic[int(c)] or {
		return error_with_code('no background sender ${c}', int(bb_err_handle))
	}
	return h.s
}

@[export: 'bb_cyclic_data']
pub fn bb_cyclic_data(c i32, data &u8, len i32) i32 {
	if len < 0 || (len > 0 && isnil(data)) {
		return fail(bb_err, 'cyclic_data: ${len} bytes, and none given')
	}
	mut s := with_cyclic(c) or { return refused(err) }
	s.set_data(unsafe { data.vbytes(int(len)) }.clone()) or { return fail(bb_err, err.msg()) }
	return ok()
}

@[export: 'bb_cyclic_signals']
pub fn bb_cyclic_signals(c i32, n i32, signals &&char, values &f64) i32 {
	vs := values_of(n, signals, values) or { return fail(bb_err, 'cyclic_signals: ${err.msg()}') }
	mut s := with_cyclic(c) or { return refused(err) }
	s.set_values(vs) or { return fail(bb_err, err.msg()) }
	return ok()
}

@[export: 'bb_cyclic_period']
pub fn bb_cyclic_period(c i32, period_ms i32) i32 {
	mut s := with_cyclic(c) or { return refused(err) }
	s.set_period(int(period_ms)) or { return fail(bb_err, err.msg()) }
	return ok()
}

@[export: 'bb_cyclic_status']
pub fn bb_cyclic_status(c i32, out &C.bb_cyclic_info) i32 {
	if isnil(out) {
		return fail(bb_err, 'cyclic_status: no bb_cyclic_info to fill')
	}
	mut s := with_cyclic(c) or { return refused(err) }
	i := s.info()
	unsafe {
		out.sent = i.sent
		out.failed = i.failed
		out.period_ms = i32(i.period_ms)
		out.running = u8(i.running)
	}
	return ok()
}

@[export: 'bb_cyclic_error']
pub fn bb_cyclic_error(c i32, buf &char, cap i32) i32 {
	mut s := with_cyclic(c) or { return refused(err) }
	return put(s.info().error, buf, cap)
}

@[export: 'bb_cyclic_stop']
pub fn bb_cyclic_stop(c i32) i32 {
	bb_mu.lock()
	h := bb_cyclic[int(c)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no background sender ${c}')
	}
	bb_cyclic.delete(int(c))
	bb_mu.unlock()
	mut s := h.s
	if !s.stop() {
		ok()
		return bb_releasing
	}
	return ok()
}
