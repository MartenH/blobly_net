// A row's format on a host's handle (bb.h's bb_framing_attach): frames sent on a bus handle bound
// to a row, stating no format, raised to the row's (transport.row_framing, #384) — the rule the
// Lua script's handle on a row follows.
module main

import blobly.transport

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
	name := bb_run_rows[int(row)].name
	bb_mu.unlock()
	hd.row = name
	ok()
	return if transport.row_framing(hd.iface, name).fd { 1 } else { 0 }
}
