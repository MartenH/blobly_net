// Bus metrics of a bus handle (bb.h's "Bus metrics" block): its load (transport.LoadMeter, counted
// by the handle's MeteredBus), its backend's diagnostics counts since open, and its controller's
// error counters.
module main

@[export: 'bb_bus_load']
pub fn bb_bus_load(h i32, out &C.bb_busload) i32 {
	if isnil(out) {
		return fail(bb_err, 'load: nowhere to put it')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	r := hd.bus.load()
	unsafe {
		out.percent = f64(r.percent)
		out.average = f64(r.average)
		out.bits = r.bits
		out.frames = r.frames
		out.nominal = i32(r.nominal)
	}
	return ok()
}

@[export: 'bb_bus_diagnostics']
pub fn bb_bus_diagnostics(h i32, out &C.bb_diagnostics) i32 {
	if isnil(out) {
		return fail(bb_err, 'diagnostics: nowhere to put them')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	d := hd.bus.diagnostics()
	unsafe {
		out.dropped = d.dropped
		out.bus_errors = d.bus_errors
		out.decode_errors = d.decode_errors
	}
	return ok()
}

@[export: 'bb_bus_error_counters']
pub fn bb_bus_error_counters(h i32, tx &i32, rx &i32) i32 {
	if isnil(tx) || isnil(rx) {
		return fail(bb_err, 'error counters: nowhere to put them')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	c := hd.bus.error_counters()
	ok()
	if !c.known {
		return bb_none
	}
	unsafe {
		*tx = i32(c.tx)
		*rx = i32(c.rx)
	}
	return 0
}
