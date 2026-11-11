// Bus metrics during a run: a channel's load (transport.LoadMeter, on the script's own handle), its
// backend's diagnostics counts since open (transport.Bus.diagnostics) and its controller's error
// counters (transport.Bus.error_counters).
module script

import blobly.lua

fn (mut env Env) register_metrics() {
	env.st.register('__bus_load', l_bus_load)
	env.st.register('__bus_diagnostics', l_bus_diagnostics)
	env.st.register('__bus_error_counters', l_bus_error_counters)
}

// __bus_load(channel) -> percent and average (nil before a whole second), frames, bits, nominal
fn l_bus_load(l lua.State) i32 {
	mut env := env_of(l)
	mut b := env.bus_for(l.arg_str(1)) or { return l.fail(err.msg()) }
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
	mut b := env.bus_for(l.arg_str(1)) or { return l.fail(err.msg()) }
	d := b.diagnostics()
	l.push_int(i64(d.dropped))
	l.push_int(i64(d.bus_errors))
	l.push_int(i64(d.decode_errors))
	return 3
}

// __bus_error_counters(channel) -> tx, rx as the controller last reported them, or nil where the
// backend cannot say
fn l_bus_error_counters(l lua.State) i32 {
	mut env := env_of(l)
	mut b := env.bus_for(l.arg_str(1)) or { return l.fail(err.msg()) }
	c := b.error_counters()
	if !c.known {
		l.push_nil()
		return 1
	}
	l.push_int(c.tx)
	l.push_int(c.rx)
	return 2
}
