// events — what run() waits on: the next frame on any channel a handler names, read from the
// SCRIPT'S OWN handles (`bus_for`) on the script's own thread. A frame is consumed once, by
// whoever reads it — run(), a handler's bus.recv, a nested run() or a later expect — and the
// script's own sends are never heard back, because the handle that sent them is the one read.
// No other thread touches a handle: canlib forbids two threads on one Kvaser handle without the
// caller's own locking, and Vector's and SocketCAN's ladder state is written by recv and read by
// health. One channel blocks in that handle's recv; several are looked at in turn with recv(0),
// sleeping one slice between looks.
module script

import time
import blobly.lua
import blobly.transport

// wait_slice is how long a wait on several channels sleeps between looks. Windows' sleep
// truncates to whole milliseconds, so anything shorter there is Sleep(0), a spin.
const wait_slice = $if windows { time.millisecond } $else { 100 * time.microsecond }

// error_rest_ms bounds how long a wait rests on a bus that answered an error at once (closed,
// failing): long enough not to spin, short enough that a link that comes back is read again.
const error_rest_ms = 20

// wait_frame is the next frame on any of `names`, waiting at most timeout_ms (a wait on several
// may return up to one slice after it, having looked at nothing since); none when nothing came. Several channels are looked at
// from the one after the last served (`rr`), so one that floods cannot starve the others.
fn (mut env Env) wait_frame(names []string, timeout_ms int, slice time.Duration) ?(string, transport.CanFrame) {
	if names.len == 0 {
		if timeout_ms > 0 {
			time.sleep(timeout_ms * time.millisecond)
		}
		return none
	}
	if names.len == 1 {
		mut bus := env.bus_for(names[0]) or { return none }
		t0 := time.ticks()
		f := bus.recv(timeout_ms) or {
			if err.msg() != 'timeout' {
				left := i64(timeout_ms) - (time.ticks() - t0)
				rest := if left < error_rest_ms { left } else { i64(error_rest_ms) }
				if rest > 0 {
					time.sleep(rest * time.millisecond)
				}
			}
			return none
		}
		return names[0], f
	}
	mut buses := []transport.Bus{}
	for n in names {
		buses << env.bus_for(n) or { return none }
	}
	deadline := time.sys_mono_now() + u64(timeout_ms) * 1_000_000
	for {
		mut spent := false
		for k in 0 .. names.len {
			// a look may spend its own bound filtering: past the deadline, the next is not taken
			if k > 0 && time.sys_mono_now() >= deadline {
				return none
			}
			i := (env.rr + k) % names.len
			f := buses[i].recv(0) or {
				spent = spent || transport.look_was_spent(err)
				continue
			}
			env.rr = i + 1
			return names[i], f
		}
		if time.sys_mono_now() >= deadline {
			return none
		}
		if spent {
			continue // records still queued behind a look's bound: look again at once
		}
		time.sleep(slice)
		// a frame that came during the last slice stays for the next reader: nothing is taken
		// off a handle after the deadline
		if time.sys_mono_now() >= deadline {
			return none
		}
	}
	return none
}

// __wait_frame(timeout_ms, channel...) -> channel, id, ext, data, fd, brs, esi, rtr, t_ms, e2e | nil
fn l_wait_frame(l lua.State) i32 {
	mut env := env_of(l)
	mut names := []string{}
	for i in 2 .. l.nargs() + 1 {
		names << l.arg_str(i)
	}
	name, f := env.wait_frame(names, int(env.bounded(l.arg_int(1))), wait_slice) or {
		if env.expired() {
			return timeout_at(l) // the wait was cut
		}
		for n in names {
			env.j1939_idle(n)
		}
		l.push_nil()
		return 1
	}
	t_ns := transport.received_now(f)
	env.j1939_saw(name, f, t_ns)
	l.push_str(name)
	l.push_int(f.id)
	l.push_bool(f.extended)
	l.push_bytes(f.data)
	push_received(l, f, t_ns)
	push_e2e(l, env.e2e_verdict(name, f))
	return 10
}

// __listen(channel) -> whether the channel's ladder needs its recv read: a channel a handler names
// is opened (and refused, if it is not a CAN bus) where the handler is registered
fn l_listen(l lua.State) i32 {
	mut env := env_of(l)
	name := l.arg_str(1)
	env.bus_for(name) or { return l.fail(err.msg()) }
	ci := env.find_chan(name) or { return l.fail(err.msg()) }
	l.push_bool(transport.health_source(env.chans[ci].iface) == .needs_reader)
	return 1
}

// __bus_health(channel) -> the rung's name, "" where the backend cannot say
fn l_bus_health(l lua.State) i32 {
	mut env := env_of(l)
	mut bus := env.bus_for(l.arg_str(1)) or { return l.fail(err.msg()) }
	l.push_str(transport.health_name(bus.health()))
	return 1
}
