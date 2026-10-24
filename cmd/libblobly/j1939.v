// J1939 on a row's frames (bb.h's "J1939 on a row's frames" block): a bus handle's received frames
// fed to a j1939.Listener once bb_j1939_attach binds it to a row, its completed messages decoded
// through the row's databases by candb.pgn_message_in, the rule the trace decodes them by.
module main

import time
import blobly.candb
import blobly.j1939
import blobly.transport

// J1939Tap is what bb_j1939_attach bound a handle to: the listener and the row's databases in run
// `gen`, nil for none. Used by the handle's own thread (bb.h), so it needs no lock of its own.
struct J1939Tap {
mut:
	l   &j1939.Listener = unsafe { nil }
	db  candb.Database
	gen u64
}

// j1939_row is row `row`'s databases as the run has them, whether its wire reads as J1939 (a row
// on it ticked `j1939:`, or with a database that declares it: j1939.on_wire), and the run's number.
fn j1939_row(row i32) !(candb.Database, bool, u64) {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	if !bb_dbs_live {
		return error_with_code("not started: a row's J1939 reading is the run's, from bb_start until bb_stop",
			int(bb_err_state))
	}
	if row < 0 || int(row) >= bb_dbs.len {
		return error('no channel ${row}')
	}
	keys := bb_run_rows.map(transport.destination_key_for(it.adapter, it.iface))
	mut says := []bool{len: bb_run_rows.len}
	for i, r in bb_run_rows {
		says[i] = r.j1939 || bb_dbs[i].j1939_declared()
	}
	return bb_dbs[int(row)], j1939.on_wire(keys, says, int(row)), bb_run_gen
}

@[export: 'bb_j1939_attach']
pub fn bb_j1939_attach(h i32, row i32, force i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	db, says, gen := j1939_row(row) or { return refused(err) }
	if !isnil(hd.j1939.l) && hd.j1939.gen == gen {
		ok()
		return 1
	}
	if force == 0 && !says {
		ok()
		return 0
	}
	hd.j1939 = J1939Tap{
		l:   &j1939.Listener{}
		db:  db
		gen: gen
	}
	ok()
	return 1
}

// j1939_feed gives a frame the handle read to its listener, at its placed time.
fn (mut hd BusHandle) j1939_feed(fr transport.CanFrame, t_ns i64) {
	if !isnil(hd.j1939.l) {
		hd.j1939.l.feed(fr, f64(t_ns) / 1_000_000.0)
	}
}

// j1939_idle times the listener's stalled transfers out: the handle had nothing queued.
fn (mut hd BusHandle) j1939_idle() {
	if !isnil(hd.j1939.l) {
		hd.j1939.l.idle(f64(time.sys_mono_now()) / 1_000_000.0)
	}
}

// listener is the handle's listener, refused where bb_j1939_attach bound none.
fn (mut hd BusHandle) listener(h i32) !&j1939.Listener {
	if isnil(hd.j1939.l) {
		return error('bus handle ${h} is not listening for J1939: bb_j1939_attach it first')
	}
	return hd.j1939.l
}

// put_text copies `s` into a fixed field of `cap` bytes, cut before a whole UTF-8 character.
fn put_text(s string, buf &char, cap int) {
	mut n := if s.len < cap { s.len } else { cap - 1 }
	for n > 0 && n < s.len && s[n] & 0xC0 == 0x80 {
		n--
	}
	unsafe {
		vmemcpy(buf, s.str, n)
		buf[n] = 0
	}
}

@[export: 'bb_j1939_take_message']
pub fn bb_j1939_take_message(h i32, out &C.bb_j1939_message, values &f64, active &u8, cap i32) i32 {
	if isnil(out) {
		return fail(bb_err, 'j1939_take_message: nowhere to put it')
	}
	if cap < 0 || (cap > 0 && (isnil(values) || isnil(active))) {
		return fail(bb_err, 'j1939_take_message: arrays of ${cap}, and no arrays')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	mut l := hd.listener(h) or { return fail(bb_err_state, err.msg()) }
	head := l.peek_message() or {
		ok()
		return bb_none
	}
	// the decode of this run only: a handle kept past a stop names no message of the next one's
	bb_mu.lock()
	current := bb_dbs_live && bb_run_gen == hd.j1939.gen
	bb_mu.unlock()
	mut pm := candb.PgnMatch{}
	if current {
		pm = candb.pgn_message_in([hd.j1939.db], head.pgn, head.sa)
		if pm.found && pm.msg.signals.len > int(cap) {
			return fail(bb_err, 'j1939_take_message: ${pm.msg.name} has ${pm.msg.signals.len} signals, and the arrays hold ${cap}')
		}
	}
	a := l.next_message() or { return bb_none }
	unsafe {
		out.pgn = a.pgn
		out.sa = a.sa
		out.da = a.da
		out.priority = a.priority
		out.bam = u8(a.bam)
		out.len = i32(a.data.len)
		out.message = if pm.found { i32(pm.index) } else { -1 }
		out.t_start_ns = i64(a.t_start_ms * 1_000_000.0)
		out.t_end_ns = i64(a.t_end_ms * 1_000_000.0)
		for i in 0 .. a.data.len {
			out.data[i] = a.data[i]
		}
		put_text(pm.refused, &out.note[0], 256)
	}
	if pm.found {
		on := pm.msg.carried(a.data)
		for k, sig in pm.msg.signals {
			unsafe {
				active[k] = u8(on[k])
				values[k] = if on[k] { sig.physical(a.data) } else { 0.0 }
			}
		}
	}
	return ok()
}

@[export: 'bb_j1939_take_fault']
pub fn bb_j1939_take_fault(h i32, out &C.bb_j1939_fault) i32 {
	if isnil(out) {
		return fail(bb_err, 'j1939_take_fault: nowhere to put it')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	mut l := hd.listener(h) or { return fail(bb_err_state, err.msg()) }
	f := l.next_fault() or {
		ok()
		return bb_none
	}
	unsafe {
		out.kind = fault_code(f.kind)
		out.sa = f.sa
		out.da = f.da
		out.announced = u8(f.announced)
		out.pgn = f.pgn
		put_text(f.detail, &out.detail[0], 256)
		put_text(f.str(), &out.text[0], 256)
	}
	return ok()
}

// fault_code is bb.h's enum bb_j1939_fault_kind for a kind, by variant: one added to
// j1939.FaultKind fails this match, and one reordered there cannot shift what a host reads.
fn fault_code(k j1939.FaultKind) i32 {
	return i32(match k {
		.orphan { C.BB_J1939_ORPHAN }
		.sequence { C.BB_J1939_SEQUENCE }
		.restarted { C.BB_J1939_RESTARTED }
		.aborted { C.BB_J1939_ABORTED }
		.timeout { C.BB_J1939_TIMEOUT }
		.malformed { C.BB_J1939_MALFORMED }
		.overflow { C.BB_J1939_OVERFLOW }
		.padding { C.BB_J1939_PADDING }
		.off_spec { C.BB_J1939_OFF_SPEC }
		.truncated { C.BB_J1939_TRUNCATED }
	})
}

@[export: 'bb_j1939_dropped']
pub fn bb_j1939_dropped(h i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	l := hd.listener(h) or { return fail(bb_err_state, err.msg()) }
	ok()
	return i32(l.dropped)
}

@[export: 'bb_j1939_address_count']
pub fn bb_j1939_address_count(h i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	l := hd.listener(h) or { return fail(bb_err_state, err.msg()) }
	ok()
	return i32(l.dir.len())
}

@[export: 'bb_j1939_address_info']
pub fn bb_j1939_address_info(h i32, k i32, out &C.bb_j1939_address) i32 {
	if isnil(out) {
		return fail(bb_err, 'j1939_address_info: nowhere to put it')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	l := hd.listener(h) or { return fail(bb_err_state, err.msg()) }
	nodes := l.dir.nodes()
	if k < 0 || int(k) >= nodes.len {
		return fail(bb_err, 'the directory holds no address ${k} (it holds ${nodes.len})')
	}
	nd := nodes[int(k)]
	n := nd.name
	unsafe {
		out.sa = nd.sa
		out.name = n.raw
		out.identity = n.identity
		out.manufacturer = n.manufacturer
		out.ecu_instance = n.ecu_instance
		out.function_instance = n.function_instance
		out.function = n.function
		out.vehicle_system = n.vehicle_system
		out.vehicle_system_instance = n.vehicle_system_instance
		out.industry_group = n.industry_group
		out.arbitrary_address_capable = u8(n.arbitrary_address_capable)
		out.t_ns = i64(nd.t_ms * 1_000_000.0)
	}
	return ok()
}

@[export: 'bb_j1939_function_name']
pub fn bb_j1939_function_name(function i32, buf &char, cap i32) i32 {
	if function < 0 || function > 255 {
		return fail(bb_err, 'a J1939 function is 0..255, not ${function}')
	}
	return put(j1939.function_name(u8(function)) or { '' }, buf, cap)
}
