// The run's generators (bb.h's "Generators" block): headless.Run's sim.GenControl, which the Lua
// gen.* reaches too.
module main

import blobly.headless
import blobly.project
import blobly.sim

__global (
	// the started run, under bb_mu, for a generator call from any thread: a stop retires it there
	bb_gen_run &headless.Run = unsafe { nil }
)

// gens_publish / gens_retire keep bb_gen_run the run's; the caller holds bb_mu.
fn gens_publish(r &headless.Run) {
	bb_gen_run = r
}

fn gens_retire() {
	bb_gen_run = unsafe { nil }
}

// gens_nul_refusal refuses a generator a host could not name: its name, or its channel's, cut at
// a NUL (bb_gen_text, bb_gen_find) names another.
fn gens_nul_refusal(proj project.Project) ! {
	for ch in proj.channels {
		for s in ch.senders {
			if s.name.contains_u8(0) || ch.name.contains_u8(0) {
				return error('load: generator "${s.name.replace('\0', '\\0')}" of channel "${ch.name.replace('\0',
					'\\0')}" has a NUL in its name, which a C string cannot carry')
			}
		}
	}
}

// gen_run is the started run, or BB_ERR_STATE's refusal.
fn gen_run() !&headless.Run {
	bb_mu.lock()
	r := bb_gen_run
	bb_mu.unlock()
	if isnil(r) {
		return error_with_code("not started: the generators are the run's, from bb_start until bb_stop",
			int(bb_err_state))
	}
	return r
}

// gen_failed is a generator call's failure as its bb.h code.
fn gen_failed(err IError) i32 {
	if err is sim.GenError {
		return fail(match err.kind {
			.refused { bb_err }
			.stopped { bb_err_state }
			.timeout { bb_err_timeout }
		}, err.msg())
	}
	return refused(err)
}

// gen_info is generator g's description.
fn gen_info(g i32) !sim.GenInfo {
	mut r := gen_run()!
	return r.gen_info(int(g))
}

@[export: 'bb_gen_count']
pub fn bb_gen_count() i32 {
	mut r := gen_run() or { return refused(err) }
	n := r.generators().len
	ok()
	return i32(n)
}

@[export: 'bb_gen_find']
pub fn bb_gen_find(name &char) i32 {
	if isnil(name) {
		return fail(bb_err, 'gen_find: no name')
	}
	mut r := gen_run() or { return refused(err) }
	g := sim.gen_find(r.generators(), vstr(name)) or { return gen_failed(err) }
	ok()
	return i32(g)
}

@[export: 'bb_gen_info']
pub fn bb_gen_info(g i32, out &C.bb_generator) i32 {
	if isnil(out) {
		return fail(bb_err, 'gen_info: no bb_generator to fill')
	}
	i := gen_info(g) or { return gen_failed(err) }
	unsafe {
		out.id = i.id
		out.ext = u8(i.ext)
		out.running = u8(i.running)
		out.sendable = u8(i.note == '' && i.target != '')
		out.cycle_ms = i32(i.cycle_ms)
		out.sent = i.sent
	}
	return ok()
}

@[export: 'bb_gen_text']
pub fn bb_gen_text(g i32, which i32, buf &char, cap i32) i32 {
	i := gen_info(g) or { return gen_failed(err) }
	s := match which {
		0 { i.name }
		1 { i.channel }
		2 { i.message }
		3 { i.trigger }
		4 { i.target }
		5 { i.note }
		else { return fail(bb_err, 'gen_text: no text ${which}') }
	}
	return put(s, buf, cap)
}

@[export: 'bb_gen_fire']
pub fn bb_gen_fire(g i32, until_ns i64) i32 {
	mut r := gen_run() or { return refused(err) }
	r.gen_fire(int(g), if until_ns > 0 { u64(until_ns) } else { u64(0) }) or {
		return gen_failed(err)
	}
	return ok()
}

@[export: 'bb_gen_start']
pub fn bb_gen_start(g i32, cycle_ms i32) i32 {
	mut r := gen_run() or { return refused(err) }
	r.gen_start(int(g), int(cycle_ms)) or { return gen_failed(err) }
	return ok()
}

@[export: 'bb_gen_stop']
pub fn bb_gen_stop(g i32) i32 {
	mut r := gen_run() or { return refused(err) }
	r.gen_stop(int(g)) or { return gen_failed(err) }
	return ok()
}

@[export: 'bb_gen_cycle']
pub fn bb_gen_cycle(g i32, cycle_ms i32) i32 {
	mut r := gen_run() or { return refused(err) }
	r.gen_cycle(int(g), int(cycle_ms)) or { return gen_failed(err) }
	return ok()
}

@[export: 'bb_gen_set']
pub fn bb_gen_set(g i32, signal &char, value f64) i32 {
	if isnil(signal) {
		return fail(bb_err, 'gen_set: no signal')
	}
	mut r := gen_run() or { return refused(err) }
	r.gen_value(int(g), vstr(signal), value) or { return gen_failed(err) }
	return ok()
}

@[export: 'bb_gen_source']
pub fn bb_gen_source(g i32, signal &char, w &C.bb_wave) i32 {
	if isnil(signal) || isnil(w) {
		return fail(bb_err, 'gen_source: no signal or no source')
	}
	mut r := gen_run() or { return refused(err) }
	src := project.GenCfg{
		typ:       vstr(w.kind)
		value:     w.value
		offset:    w.offset
		amplitude: w.amplitude
		freq:      w.freq
		phase:     w.phase
		min:       w.min
		max:       w.max
		period:    w.period
		start:     w.start
		step:      w.step
		modulo:    w.modulo
		count:     w.count
		base:      w.base
	}
	r.gen_source(int(g), vstr(signal), src) or { return gen_failed(err) }
	return ok()
}
