module script

import time
import blobly.lua
import blobly.isotp
import blobly.doip
import blobly.uds

// timeout_note is the error a script ends with once the run's deadline has passed.
pub const timeout_note = 'run timeout'

// the deadline is asked every this many Lua VM instructions
const deadline_every = 1000

// deadline_calls makes the protected calls re-raise a timeout they caught, so a script that
// catches errors cannot hold the run past its deadline. Lua source, double quotes only.
const deadline_calls = r'
local raw_pcall, raw_xpcall, raw_resume = pcall, xpcall, coroutine.resume
local function past(...)
  if __expired() then error("run timeout", 0) end
  return ...
end
function pcall(...) return past(raw_pcall(...)) end
-- past the deadline the handler is not called: one raised by the hook would run with hooks off
function xpcall(f, h, ...)
  if type(h) ~= "function" then return past(raw_xpcall(f, h, ...)) end
  return past(raw_xpcall(f, function(e) if __expired() then return e end return h(e) end, ...))
end
coroutine.resume = function(...) return past(raw_resume(...)) end
'

// Running is a test() begun in `script` and not yet reported, in the coroutine `co`.
struct Running {
	name   string
	co     u64
	script string
	t0     u64
}

// set_deadline ends what this env runs `after_ms` from now. Lua code is stopped between
// instructions (a count hook raising timeout_note, which pcall, xpcall and coroutine.resume raise
// again); a sleep, a frame wait or a listening window is
// cut to what is left; a UDS request (a flash's too) is abandoned, in its carrier's wait or between
// its answers. A DoIP connection being opened finishes its own bounded wait first. Set before anything runs: a coroutine or a UDS connection
// that exists already is not bound.
pub fn (mut env Env) set_deadline(after_ms i64) {
	env.deadline = time.sys_mono_now() + u64(after_ms) * 1_000_000
	env.st.do_string(deadline_calls) or { panic('deadline_calls: ${err}') }
	env.st.set_count_hook(l_deadline_hook, deadline_every)
}

// expired is whether the deadline set_deadline set has passed.
pub fn (env &Env) expired() bool {
	return env.deadline != 0 && time.sys_mono_now() >= env.deadline
}

// running_test is the test() the deadline was raised inside — the innermost begun in the
// coroutine it was raised in, not one suspended in another; '' when it was in none.
pub fn (env &Env) running_test() string {
	if env.timeout_co == 0 {
		return ''
	}
	for i := env.running.len - 1; i >= 0; i-- {
		if env.running[i].co == env.timeout_co {
			return env.running[i].name
		}
	}
	return ''
}

// thread_of is the coroutine a host function was called from: its own lua_State.
fn thread_of(l lua.State) u64 {
	return u64(voidptr(l))
}

// timeout_at raises the deadline's error in `l`, noting the first coroutine it was raised in.
fn timeout_at(l lua.State) i32 {
	mut env := env_of(l)
	if env.timeout_co == 0 {
		env.timeout_co = thread_of(l)
	}
	return l.fail(timeout_note)
}

// bounded is a wait of `ms` cut to what is left before the deadline; a negative one (wait for
// ever) is the whole of it.
fn (env &Env) bounded(ms i64) i64 {
	if env.deadline == 0 || ms == 0 {
		return ms
	}
	now := time.sys_mono_now()
	// at most what a backend's int wait can hold
	left := if now >= env.deadline {
		i64(0)
	} else {
		ms_left := (env.deadline - now) / 1_000_000 + 1
		i64(if ms_left < u64(max_i32) { ms_left } else { u64(max_i32) })
	}
	return if ms > 0 && ms < left { ms } else { left }
}

// bounded_window is a listening window of `ms` cut like a wait; one of 0 or less stays as it is.
fn (env &Env) bounded_window(ms i64) i64 {
	return if ms <= 0 { ms } else { env.bounded(ms) }
}

// bound_client is `c` on `ch` abandoning a request once the deadline has passed: the client
// between its answers, the carrier inside its own wait.
fn (env &Env) bound_client(mut ch isotp.Channel, c uds.Client) uds.Client {
	if env.deadline == 0 {
		return c
	}
	stop := fn [env] () bool {
		return env.expired()
	}
	if mut ch is isotp.SoftChannel {
		ch.stop_requested = stop
	} else if mut ch is doip.DoipClient {
		ch.stop_requested = stop
	}
	mut out := c
	out.stop_requested = stop
	return out
}

fn l_deadline_hook(l lua.State) i32 {
	if env_of(l).expired() {
		return timeout_at(l)
	}
	return 0
}

// __test_begin(name): a test() starts, in the coroutine that calls it
fn l_test_begin(l lua.State) i32 {
	mut env := env_of(l)
	env.running << Running{
		name:   l.arg_str(1)
		co:     thread_of(l)
		script: env.script_arg
		t0:     time.sys_mono_now()
	}
	return 0
}

// test_ended is the innermost test() running in coroutine `co`, which has ended.
fn (mut env Env) test_ended(co u64) Running {
	for i := env.running.len - 1; i >= 0; i-- {
		if env.running[i].co == co {
			r := env.running[i]
			env.running.delete(i)
			return r
		}
	}
	return Running{
		script: env.script_arg
		t0:     time.sys_mono_now()
	}
}

// __expired() -> whether the run's deadline has passed
fn l_expired(l lua.State) i32 {
	l.push_bool(env_of(l).expired())
	return 1
}

// __script_chunk() -> the chunk name of the running script file ("@" + its path), '' for source
fn l_script_chunk(l lua.State) i32 {
	env := env_of(l)
	l.push_str(if env.script_arg == '' { '' } else { '@' + env.script_arg })
	return 1
}
