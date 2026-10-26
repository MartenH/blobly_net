// A row's format on a host's handle (bb.h's bb_framing_attach): frames sent on a bus handle bound
// to a row, stating no format, raised to the row's (project.Channel.emitter_framing, #384) — the
// rule the Lua script's handle on a row follows.
module main

import blobly.transport

// RowFraming is what bb_framing_attach bound a handle to: the row's format in run `gen`.
struct RowFraming {
	framing transport.Framing
	gen     u64
}

@[export: 'bb_framing_attach']
pub fn bb_framing_attach(h i32, row i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	bb_mu.lock()
	if !bb_dbs_live {
		bb_mu.unlock()
		return fail(bb_err_state, "not started: a row's format is the run's, from bb_start until bb_stop")
	}
	if row < 0 || int(row) >= bb_run_rows.len {
		bb_mu.unlock()
		return fail(bb_err, 'no channel ${row}')
	}
	fr := bb_run_rows[int(row)].emitter_framing()
	gen := bb_run_gen
	bb_mu.unlock()
	hd.framing = RowFraming{
		framing: fr
		gen:     gen
	}
	ok()
	return if fr.fd { 1 } else { 0 }
}

// framed is `f` as the handle's row raises it, while the run it was attached in is the one started.
fn (hd &BusHandle) framed(f transport.CanFrame) transport.CanFrame {
	if !hd.framing.framing.fd {
		return f
	}
	bb_mu.lock()
	current := bb_dbs_live && bb_run_gen == hd.framing.gen
	bb_mu.unlock()
	return if current { hd.framing.framing.raised(f) } else { f }
}
