// Network management on a row's frames (bb.h's "Network management on a row's frames" block): a
// bus handle's received frames fed to an nm.Listener once bb_nm_attach binds it to a row, by the
// row's wire's configuration (nm.configure, the panel's rule) or a range the host states.
module main

import blobly.headless
import blobly.nm
import blobly.transport

// NmTap is what bb_nm_attach bound a handle to: the listener in run `gen` and the reading
// bb_nm_read_view last took, which bb_nm_node_info indexes; nil for none. Used by the handle's own thread
// (bb.h), so it needs no lock of its own.
struct NmTap {
mut:
	l    &nm.Listener = unsafe { nil }
	gen  u64
	view nm.View
}

__global (
	// the run's rows' NM configurations, aligned with bb_dbs and under bb_mu; `bb_nm_has[i]` false
	// where row i's wire has none
	bb_nm_cfgs []nm.Config
	bb_nm_has  []bool
)

// nm_publish records the run's per-row NM configurations; under bb_mu.
fn nm_publish(r &headless.Run) {
	bb_nm_cfgs = []nm.Config{}
	bb_nm_has = []bool{}
	for c in r.chans {
		cfg := r.nm_config(c.cfg) or {
			bb_nm_cfgs << nm.Config{}
			bb_nm_has << false
			continue
		}
		bb_nm_cfgs << cfg
		bb_nm_has << true
	}
}

// nm_retire forgets them at a stop; under bb_mu.
fn nm_retire() {
	bb_nm_cfgs = []nm.Config{}
	bb_nm_has = []bool{}
}

// nm_row is row `row`'s NM configuration as the run has it, whether it has one, and the run's
// number.
fn nm_row(row i32) !(nm.Config, bool, u64) {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	if !bb_dbs_live {
		return error_with_code("not started: a row's NM reading is the run's, from bb_start until bb_stop",
			int(bb_err_state))
	}
	if row < 0 || int(row) >= bb_nm_cfgs.len {
		return error('no channel ${row}')
	}
	if bb_run_rows[int(row)].is_eth() {
		return error('channel ${row} (${bb_run_rows[int(row)].name}) is not a CAN row: NM is read from CAN frames')
	}
	return bb_nm_cfgs[int(row)], bb_nm_has[int(row)], bb_run_gen
}

@[export: 'bb_nm_attach']
pub fn bb_nm_attach(h i32, row i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	cfg, has, gen := nm_row(row) or { return refused(err) }
	if !isnil(hd.nm.l) && hd.nm.gen == gen {
		ok()
		return 1
	}
	if !has {
		hd.nm = NmTap{} // an earlier run's listener does not go on reading
		ok()
		return 0
	}
	hd.nm = NmTap{
		l:   nm.new_listener(cfg)
		gen: gen
	}
	ok()
	return 1
}

@[export: 'bb_nm_attach_range']
pub fn bb_nm_attach_range(h i32, row i32, lo i64, hi i64, ext i32, timeout_ms i32) i32 {
	cfg := nm.explicit(lo, hi, ext != 0, timeout_ms) or {
		return fail(bb_err, 'nm_attach_range: ${err.msg()}')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	_, _, gen := nm_row(row) or { return refused(err) }
	hd.nm = NmTap{
		l:   nm.new_listener(cfg)
		gen: gen
	}
	ok()
	return 1
}

// nm_feed gives a frame the handle read to its listener, at its receive time `t_ns` (bb_frame.t_ns).
fn (mut hd BusHandle) nm_feed(fr transport.CanFrame, t_ns i64) {
	if !isnil(hd.nm.l) {
		hd.nm.l.feed(fr.id, fr.extended, fr.rtr, fr.data, f64(t_ns) / 1_000_000.0)
	}
}

// nm_idle: the handle had nothing queued, so the reading is complete to now.
fn (mut hd BusHandle) nm_idle(now_ns i64) {
	if !isnil(hd.nm.l) {
		hd.nm.l.idle(f64(now_ns) / 1_000_000.0)
	}
}

// nm_source_code is bb.h's enum bb_nm_source for a source, by variant.
fn nm_source_code(s nm.Source) i32 {
	return i32(match s {
		.system { C.BB_NM_SYSTEM }
		.arxml { C.BB_NM_ARXML }
		.project { C.BB_NM_PROJECT }
		.script { C.BB_NM_SCRIPT }
	})
}

// nm_state_code is bb.h's enum bb_nm_state for a state, by variant.
fn nm_state_code(s nm.BusState) i32 {
	return i32(match s {
		.asleep { C.BB_NM_ASLEEP }
		.awake { C.BB_NM_AWAKE }
		.releasing { C.BB_NM_RELEASING }
	})
}

fn ns_of(ms f64) i64 {
	return i64(ms * 1_000_000.0)
}

@[export: 'bb_nm_read_view']
pub fn bb_nm_read_view(h i32, out &C.bb_nm_view) i32 {
	if isnil(out) {
		return fail(bb_err, 'nm_read_view: nowhere to put it')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	if isnil(hd.nm.l) {
		return fail(bb_err_state, 'bus handle ${h} is not reading NM: bb_nm_attach it first')
	}
	v := hd.nm.l.reading()
	hd.nm.view = v
	at := hd.nm.l.at_ms
	unsafe {
		out.state = nm_state_code(v.state)
		out.nodes = i32(v.rows.len)
		out.keepers = i32(v.keeper_rows.len)
		out.woke = i32(v.woke_row)
		out.woke_active = u8(v.woke_active)
		out.heard = u8(v.heard)
		out.timeout_default = u8(v.cfg.timeout_default)
		out.timeout_ms = i32(v.cfg.timeout_ms)
		out.source = nm_source_code(v.cfg.source)
		out.t_ns = if at > 0 { ns_of(at) } else { 0 }
		out.woke_ns = if v.woke_row >= 0 { ns_of(at - v.woke_ago) } else { 0 }
		out.last_ns = if v.heard { ns_of(at - v.last_ago) } else { 0 }
		out.frames = v.frames
		out.malformed = v.malformed
		out.dropped = v.dropped
		put_text(v.cfg.origin, &out.origin[0], 256)
		put_text(v.cfg.describe(), &out.frames_text[0], 256)
		put_text(v.last_error, &out.last_error[0], 256)
	}
	return ok()
}

@[export: 'bb_nm_node_info']
pub fn bb_nm_node_info(h i32, k i32, out &C.bb_nm_node) i32 {
	if isnil(out) {
		return fail(bb_err, 'nm_node_info: nowhere to put it')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	if isnil(hd.nm.l) {
		return fail(bb_err_state, 'bus handle ${h} is not reading NM: bb_nm_attach it first')
	}
	v := hd.nm.view
	if k < 0 || int(k) >= v.rows.len {
		return fail(bb_err, 'the NM reading holds no node ${k} (it holds ${v.rows.len}; bb_nm_read_view takes it)')
	}
	r := v.rows[int(k)]
	at := hd.nm.l.at_ms
	unsafe {
		put_text(r.name, &out.name[0], 256)
		out.id = r.id
		out.ext = u8(r.ext)
		out.has_id = u8(r.has_id)
		out.nid = i32(r.nid)
		out.missing = u8(r.missing)
		out.unknown = u8(r.unknown)
		out.live = u8(!r.missing && !r.stale)
		out.keeper = i32(v.keeper_rows.index(int(k)))
		out.cbv = r.cbv
		out.has_pn = u8(r.has_pn)
		out.pn = r.pn
		out.count = r.count
		out.last_ns = if r.missing { 0 } else { ns_of(at - r.ago_ms) }
		out.cadence_ms = r.mean_ms
		out.last_interval_ms = r.last_iv_ms
	}
	return ok()
}
