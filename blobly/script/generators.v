module script

import blobly.lua
import blobly.project
import blobly.sim

// generators.v — gen.*: the run's generators from a script (sim.GenControl), each named by its
// name or `channel/name` (sim.gen_find), or by its position in gen.list(). Every primitive takes
// the generator as two arguments, the name and the position (0: none), which the prelude splits.

fn (mut env Env) register_gens() {
	env.st.register('__gen_list', l_gen_list)
	env.st.register('__gen_fire', l_gen_fire)
	env.st.register('__gen_start', l_gen_start)
	env.st.register('__gen_stop', l_gen_stop)
	env.st.register('__gen_cycle', l_gen_cycle)
	env.st.register('__gen_set', l_gen_set)
	env.st.register('__gen_source', l_gen_source)
}

// gen_arg is the generator arguments 1 and 2 name: a position (1-based) when 2 is one, else a name.
fn gen_arg(l lua.State) !int {
	mut env := env_of(l)
	gs := env.gens.generators()
	pos := l.arg_int_exact(2) or { 0 }
	if pos != 0 {
		if pos < 1 || pos > gs.len {
			return error('no generator at position ${pos} (the run has ${gs.len})')
		}
		return int(pos - 1)
	}
	return sim.gen_find(gs, l.arg_str(1))
}

// ms_arg is argument i as whole milliseconds.
fn ms_arg(l lua.State, i int, what string) !int {
	v := l.arg_int_exact(i) or { return error('${what}: the cycle is a whole number of ms') }
	if v < 0 || v > i64(max_i32) {
		return error('${what}: cycle ${v} ms')
	}
	return int(v)
}

fn l_gen_list(l lua.State) i32 {
	mut env := env_of(l)
	l.new_table()
	for i, g in env.gens.generators() {
		l.new_table()
		l.set_str('name', g.name)
		l.set_str('channel', g.channel)
		l.set_str('message', g.message)
		l.set_int('id', i64(g.id))
		l.set_bool('ext', g.ext)
		l.set_str('trigger', g.trigger)
		l.set_int('cycle_ms', g.cycle_ms)
		l.set_bool('running', g.running)
		l.set_int('sent', g.sent)
		l.set_str('target', g.target)
		l.set_str('note', g.note)
		l.set_index(i + 1)
	}
	return 1
}

fn l_gen_fire(l lua.State) i32 {
	mut env := env_of(l)
	g := gen_arg(l) or { return l.fail('gen.fire: ${err.msg()}') }
	// bounded by the run deadline too: a fire its loop reaches past it is never sent
	if env.expired() {
		return timeout_at(l)
	}
	env.gens.gen_fire(g, env.deadline) or {
		if env.expired() {
			return timeout_at(l)
		}
		return l.fail('gen.fire: ${err.msg()}')
	}
	return 0
}

fn l_gen_start(l lua.State) i32 {
	mut env := env_of(l)
	g := gen_arg(l) or { return l.fail('gen.start: ${err.msg()}') }
	ms := ms_arg(l, 3, 'gen.start') or { return l.fail(err.msg()) }
	env.gens.gen_start(g, ms) or { return l.fail('gen.start: ${err.msg()}') }
	return 0
}

fn l_gen_stop(l lua.State) i32 {
	mut env := env_of(l)
	g := gen_arg(l) or { return l.fail('gen.stop: ${err.msg()}') }
	env.gens.gen_stop(g) or { return l.fail('gen.stop: ${err.msg()}') }
	return 0
}

fn l_gen_cycle(l lua.State) i32 {
	mut env := env_of(l)
	g := gen_arg(l) or { return l.fail('gen.cycle: ${err.msg()}') }
	ms := ms_arg(l, 3, 'gen.cycle') or { return l.fail(err.msg()) }
	env.gens.gen_cycle(g, ms) or { return l.fail('gen.cycle: ${err.msg()}') }
	return 0
}

fn l_gen_set(l lua.State) i32 {
	mut env := env_of(l)
	g := gen_arg(l) or { return l.fail('gen.set: ${err.msg()}') }
	if !l.arg_is_num(4) {
		return l.fail('gen.set: the value is a number')
	}
	env.gens.gen_value(g, l.arg_str(3), l.arg_num(4)) or { return l.fail('gen.set: ${err.msg()}') }
	return 0
}

// __gen_source(name, position, signal, type, value, offset, amplitude, freq, phase, min, max,
// period, start, step, modulo, count, base): the prelude spreads gen.source's table in that order.
fn l_gen_source(l lua.State) i32 {
	mut env := env_of(l)
	g := gen_arg(l) or { return l.fail('gen.source: ${err.msg()}') }
	w := project.GenCfg{
		typ:       l.arg_str(4)
		value:     l.arg_num(5)
		offset:    l.arg_num(6)
		amplitude: l.arg_num(7)
		freq:      l.arg_num(8)
		phase:     l.arg_num(9)
		min:       l.arg_num(10)
		max:       l.arg_num(11)
		period:    l.arg_num(12)
		start:     l.arg_num(13)
		step:      l.arg_num(14)
		modulo:    l.arg_num(15)
		count:     l.arg_num(16)
		base:      l.arg_num(17)
	}
	env.gens.gen_source(g, l.arg_str(3), w) or { return l.fail('gen.source: ${err.msg()}') }
	return 0
}
