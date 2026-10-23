// Bus metrics during a run: a channel's load (transport.LoadMeter, on the script's own handle) and
// its backend's diagnostics counts since open (transport.Bus.diagnostics).
module script

import blobly.lua
import blobly.transport

fn (mut env Env) register_metrics() {
	env.st.register('__bus_load', l_bus_load)
	env.st.register('__bus_diagnostics', l_bus_diagnostics)
}

// metered_for is the script's handle on the channel, opened as bus_for opens it.
fn (mut env Env) metered_for(name string) !&transport.MeteredBus {
	env.bus_for(name)!
	return env.buses[name] or { return error('no bus open for "${name}"') }
}

// __bus_load(channel) -> percent and average (nil before a whole second), frames, bits, nominal
fn l_bus_load(l lua.State) i32 {
	mut env := env_of(l)
	mut b := env.metered_for(l.arg_str(1)) or { return l.fail(err.msg()) }
	r := b.load()
	if r.percent < 0 {
		l.push_nil()
	} else {
		l.push_num(f64(r.percent))
	}
	if r.average < 0 {
		l.push_nil()
	} else {
		l.push_num(f64(r.average))
	}
	l.push_int(i64(r.frames))
	l.push_num(r.bits)
	l.push_int(r.nominal)
	return 5
}

// __bus_diagnostics(channel) -> dropped, bus_errors, decode_errors since the handle opened
fn l_bus_diagnostics(l lua.State) i32 {
	mut env := env_of(l)
	mut b := env.metered_for(l.arg_str(1)) or { return l.fail(err.msg()) }
	d := b.diagnostics()
	l.push_int(i64(d.dropped))
	l.push_int(i64(d.bus_errors))
	l.push_int(i64(d.decode_errors))
	return 3
}
