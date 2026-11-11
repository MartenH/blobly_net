// The newest frame per id and kind on a bus handle's wire (bb.h's "The newest frame" block): a
// transport.NewestView read from a handle of its own on its own thread, so its answer is current
// while the host does not read the handle — inside a UDS exchange, a flash, a sleep.
module main

import blobly.transport

@[export: 'bb_bus_watch']
pub fn bb_bus_watch(h i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	if !isnil(hd.bus.view) {
		return ok()
	}
	bus := transport.open(hd.iface) or { return fail(bb_err, 'watch: ${hd.iface}: ${err.msg()}') }
	view := transport.watch_newest(bus, hd.iface)
	bb_mu.lock()
	hd.bus.view = view
	bb_mu.unlock()
	return ok()
}

@[export: 'bb_bus_latest']
pub fn bb_bus_latest(h i32, id u32, ext i32, out &C.bb_frame) i32 {
	if isnil(out) {
		return fail(bb_err, 'latest: nowhere to put the frame')
	}
	kind := match ext {
		-1 { ?bool(none) }
		0 { ?bool(false) }
		1 { ?bool(true) }
		else { return fail(bb_err, 'latest: ext is -1 (either kind), 0 or 1, not ${ext}') }
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	mut view := hd.view() or { return fail(bb_err_state, 'latest: handle ${h} is not watched (bb_bus_watch)') }
	view.settle() // what is queued on the view's handle now kept first: the answer is as of the call
	why := view.failure()
	if why != '' {
		return fail(bb_err, 'latest: ${why}')
	}
	f := view.get(id, kind) or {
		ok()
		return bb_none
	}
	put_frame(out, f.frame, f.t_ns)
	return ok()
}

@[export: 'bb_bus_latest_clear']
pub fn bb_bus_latest_clear(h i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	mut view := hd.view() or { return fail(bb_err_state, 'latest_clear: handle ${h} is not watched (bb_bus_watch)') }
	view.settle() // what was queued before the call forgotten with the rest
	view.clear()
	return ok()
}

// view is the handle's newest-frame view, none before bb_bus_watch; read under bb_mu, since
// bb_bus_latest may come from another thread than the one that watched.
fn (mut hd BusHandle) view() ?&transport.NewestView {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	v := hd.bus.view
	return if isnil(v) { none } else { v }
}
