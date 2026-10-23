// E2E on a row's frames (bb.h's "E2E on a row's frames" block): a bus handle's received frames
// judged by sim.E2eReader once bb_e2e_attach binds it to a row, and a message sent by name stamped
// with its declared E2E by sim.E2eStamper — the rules the Lua prelude's frame.e2e and
// bus.send_message follow.
module main

import blobly.candb
import blobly.project
import blobly.sim
import blobly.transport

// E2eJudge is what bb_e2e_attach bound a handle to: the reader of its row in run `gen`, nil for
// none. Used by the handle's own thread (bb.h), so it needs no lock of its own.
struct E2eJudge {
mut:
	reader &sim.E2eReader = unsafe { nil }
	gen    u64
}

__global (
	// the run's sends by name, per row, under bb_mu; bb_e2e_gen is the run they count
	bb_e2e_stampers map[int]&sim.E2eStamper
	bb_e2e_gen      u64
)

// e2e_row is row `row`'s databases and configuration as the run has them, and the run's number.
fn e2e_row(row i32) !(candb.Database, project.Channel, u64) {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	if !bb_dbs_live {
		return error_with_code("not started: a row's E2E is the run's, from bb_start until bb_stop",
			int(bb_err_state))
	}
	if row < 0 || int(row) >= bb_dbs.len {
		return error('no channel ${row}')
	}
	return bb_dbs[int(row)], bb_run_rows[int(row)], bb_run_gen
}

// message_locked is message(row, m) for a caller that holds bb_mu.
fn message_locked(row i32, m i32) !candb.Message {
	if !bb_dbs_live {
		return error_with_code("not started: a row's databases are the run's, from bb_start until bb_stop",
			int(bb_err_state))
	}
	if row < 0 || int(row) >= bb_dbs.len {
		return error('no channel ${row}')
	}
	msgs := bb_dbs[int(row)].messages
	if m < 0 || int(m) >= msgs.len {
		return error('channel ${row} has no message ${m} (it has ${msgs.len})')
	}
	return msgs[int(m)]
}

@[export: 'bb_e2e_attach']
pub fn bb_e2e_attach(h i32, row i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	db, cfg, gen := e2e_row(row) or { return refused(err) }
	r := sim.new_e2e_reader(db, cfg.all_nodes(), cfg.verify)
	n := r.judges()
	hd.judge = E2eJudge{
		reader: if n > 0 { r } else { unsafe { nil } }
		gen:    gen
	}
	ok()
	return i32(n)
}

// e2e_verdict is bb_frame.e2e for a frame the handle received: its row's verdict while the run it
// was attached in is the one started, BB_E2E_NONE otherwise.
fn (mut hd BusHandle) e2e_verdict(fr transport.CanFrame) u8 {
	if isnil(hd.judge.reader) {
		return u8(C.BB_E2E_NONE)
	}
	bb_mu.lock()
	current := bb_dbs_live && bb_run_gen == hd.judge.gen
	bb_mu.unlock()
	if !current {
		return u8(C.BB_E2E_NONE)
	}
	v := hd.judge.reader.judge(fr) or { return u8(C.BB_E2E_NONE) }
	return e2e_code(v)
}

// e2e_code is bb.h's enum bb_e2e for a verdict, by variant: one added to sim.Violation fails this
// match, and one reordered there cannot shift what a host reads.
fn e2e_code(v sim.Violation) u8 {
	return u8(match v {
		.ok { C.BB_E2E_OK }
		.bad_crc { C.BB_E2E_BAD_CRC }
		.stalled_ctr { C.BB_E2E_REPEATED }
		.skipped_ctr { C.BB_E2E_SKIPPED }
		.truncated { C.BB_E2E_TRUNCATED }
		.timeout { C.BB_E2E_TIMEOUT }
	})
}

@[export: 'bb_e2e_stamp']
pub fn bb_e2e_stamp(row i32, m i32, f &C.bb_frame) i32 {
	if isnil(f) {
		return fail(bb_err, 'e2e_stamp: no frame')
	}
	n := int(f.len)
	if n > 64 {
		return fail(bb_err, 'e2e_stamp: a payload is at most 64 bytes, not ${n}')
	}
	mut data := []u8{len: n}
	for i in 0 .. n {
		data[i] = f.data[i]
	}
	// the message, its run and that run's counters under one hold: a stop and start between the
	// lookup and the stamp would count an old run's message in the new run
	bb_mu.lock()
	msg := message_locked(row, m) or {
		bb_mu.unlock()
		return refused(err)
	}
	if n < msg.payload_len() {
		bb_mu.unlock()
		return fail(bb_err, 'e2e_stamp: a frame of ${n} bytes is shorter than ${msg.name} (${msg.payload_len()})')
	}
	if bb_e2e_gen != bb_run_gen {
		bb_e2e_stampers = map[int]&sim.E2eStamper{}
		bb_e2e_gen = bb_run_gen
	}
	mut st := bb_e2e_stampers[int(row)] or {
		s := &sim.E2eStamper{}
		bb_e2e_stampers[int(row)] = s
		s
	}
	stamped := st.stamp(msg, mut data) or {
		bb_mu.unlock()
		return fail(bb_err, err.msg())
	}
	bb_mu.unlock()
	if !stamped {
		ok()
		return bb_none
	}
	unsafe {
		for i in 0 .. n {
			f.data[i] = data[i]
		}
	}
	return ok()
}
