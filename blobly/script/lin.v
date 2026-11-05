// lin — LIN from a script: lin.open on a row of the run (a tap on it, and the row's controls) or
// on an address (a row of the script's own, stopped at close). Its Lua half is its own chunk,
// loaded here, so the prelude does not change.
module script

import time
import blobly.lin
import blobly.lindb
import blobly.lua
import blobly.transport

// LinHandle is one lin.open: a tap on a row, and whether the row is the script's own.
@[heap]
struct LinHandle {
	name string // the row's name, or the address
	own  bool
mut:
	row    &lin.Row
	tap    &lin.Tap
	ldf    ?lindb.Ldf
	closed bool
}

// close ends the handle: the script's own row stopped, a run's row untapped.
fn (mut h LinHandle) close() {
	if h.closed {
		return
	}
	h.closed = true
	if h.own {
		h.row.stop()
	} else {
		h.row.untap(h.tap)
	}
}

// lin_lua is the lin.* namespace over the primitives. Lua source, double quotes only.
const lin_lua = r'
lin = {}
function lin.open(target, opts)
  if type(target) ~= "string" then error("lin.open: give a LIN row name or an address", 2) end
  if opts ~= nil and type(opts) ~= "table" then error("lin.open: opts is a table", 2) end
  local o = opts or {}
  return __lin_open(target, o.role or "", o.ldf or "", o.baud or 0, opts ~= nil)
end
function lin.recv(h, timeout_ms) return __lin_recv(h, timeout_ms or 1000) end
function lin.expect(h, want, timeout_ms) return __lin_expect(h, want, timeout_ms or 1000) end
function lin.header(h, id) __lin_header(h, id) end
function lin.set(h, signal, value, opts)
  if opts ~= nil and type(opts) ~= "table" then error("lin.set: opts is a table", 2) end
  local t = type(value)
  if t == "table" then
    __lin_set(h, signal, "bytes", string.char(table.unpack(value)))
  elseif t == "string" then
    __lin_set(h, signal, "str", value)
  elseif t == "number" then
    __lin_set(h, signal, (opts and opts.raw) and "raw" or "num", value)
  else
    error("lin.set: the value is a number, a string or a byte table, not " .. t, 2)
  end
end
function lin.schedule(h, name) __lin_schedule(h, name) end
function lin.stop_schedule(h) return __lin_stop_schedule(h) end
function lin.sleep(h) __lin_sleep(h) end
function lin.wakeup(h) __lin_wakeup(h) end
function lin.status(h) return __lin_status(h) end
function lin.diagnostics(h)
  local dropped, bus_errors, decode_errors = __lin_diagnostics(h)
  return { dropped = dropped, bus_errors = bus_errors, decode_errors = decode_errors }
end
function lin.close(h) __lin_close(h) end
'

fn (mut env Env) register_lin() {
	env.st.register('__lin_open', l_lin_open)
	env.st.register('__lin_recv', l_lin_recv)
	env.st.register('__lin_expect', l_lin_expect)
	env.st.register('__lin_header', l_lin_header)
	env.st.register('__lin_set', l_lin_set)
	env.st.register('__lin_schedule', l_lin_schedule)
	env.st.register('__lin_stop_schedule', l_lin_stop_schedule)
	env.st.register('__lin_sleep', l_lin_sleep)
	env.st.register('__lin_wakeup', l_lin_wakeup)
	env.st.register('__lin_status', l_lin_status)
	env.st.register('__lin_diagnostics', l_lin_diagnostics)
	env.st.register('__lin_close', l_lin_close)
	env.st.do_string(lin_lua) or { panic('lin chunk: ${err}') }
}

// close_lin_handles closes every LIN handle still open: what a script opened ends with it (the
// handles stay listed, so close_lin still reports what each counted).
pub fn (mut env Env) close_lin_handles() {
	for mut h in env.lins {
		h.close()
	}
}

// close_lin closes every LIN handle and adds what each counted to `out`: its tap's drops, and
// for the script's own row the row's handle's counts.
fn (mut env Env) close_lin(mut out map[string]transport.BusDiagnostics) {
	for i, mut h in env.lins {
		h.close()
		mut d := transport.BusDiagnostics{
			dropped: h.tap.dropped()
		}
		if h.own {
			d = d.plus(h.row.diagnostics())
		}
		if !d.is_empty() {
			out['lin ${h.name} #${i}'] = d
		}
	}
}

// lin_arg is the open LIN handle argument i names.
fn (mut env Env) lin_arg(l lua.State, i int) !&LinHandle {
	n := handle_arg(l, i, 'the lin handle')!
	if n >= env.lins.len || env.lins[n].closed {
		return error('the lin handle ${n} is not open')
	}
	return env.lins[n]
}

fn role_of(s string) !lin.Role {
	return match s {
		'master' { lin.Role.master }
		'slave' { lin.Role.slave }
		'monitor', '' { lin.Role.monitor }
		else { error('role `${s}` is not master, slave or monitor') }
	}
}

// __lin_open(target, role, ldf, baud, has_opts) -> handle
fn l_lin_open(l lua.State) i32 {
	mut env := env_of(l)
	target := l.arg_str(1)
	if rows := env.lin_rows {
		for row in rows {
			if row.spec.name != target {
				continue
			}
			if l.arg_bool(5) {
				return l.fail('lin.open: ${target} is a LIN row of the run; its role, LDF and rate are the project file')
			}
			mut r := unsafe { row }
			tap := r.tap() or { return l.fail('lin.open: ${err.msg()}') }
			return env.push_lin_handle(l, target, false, r, tap)
		}
	}
	if !target.contains(':') {
		if rows := env.lin_rows {
			names := rows.map(it.spec.name)
			return l.fail('lin.open: no LIN row `${target}` in this run (${if names.len > 0 {
				names.join(', ')
			} else {
				'it has none'
			}}), and it is not an address')
		}
		return l.fail('lin.open: `${target}` is not an address, and this script was given no run\'s LIN buses; give lin.open an address such as inproc:<name>')
	}
	role := role_of(l.arg_str(2)) or { return l.fail('lin.open: ${err.msg()}') }
	baud := int_arg(l, 4, 'baud', 0, 20000) or { return l.fail('lin.open: ${err.msg()}') }
	ldf := l.arg_str(3)
	mut row := lin.start_row(lin.RowSpec{
		name:    target
		address: target
		baud:    int(baud)
		ldf:     if ldf == '' { '' } else { env.script_relative(ldf) }
		role:    role
	}, lin.RowOpts{}) or { return l.fail('lin.open: ${err.msg()}') }
	tap := row.tap() or {
		row.stop()
		return l.fail('lin.open: ${err.msg()}')
	}
	return env.push_lin_handle(l, target, true, row, tap)
}

fn (mut env Env) push_lin_handle(l lua.State, name string, own bool, row &lin.Row, tap &lin.Tap) i32 {
	env.lins << &LinHandle{
		name: name
		own:  own
		row:  row
		tap:  tap
		ldf:  row.ldf()
	}
	l.push_int(env.lins.len - 1)
	return 1
}

// __lin_recv(h, ms) -> frame, or nil when none came
fn l_lin_recv(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.recv: ${err.msg()}') }
	f := h.tap.recv(int(env.bounded(ms_up(l, 2)))) or {
		if env.expired() {
			return timeout_at(l)
		}
		if err is lin.Timeout {
			l.push_nil()
			return 1
		}
		return l.fail('lin.recv: ${err.msg()}')
	}
	push_lin_frame(l, f, h.ldf)
	return 1
}

// lin_frame_name is the LDF's name for a frame of `id` carrying `data`, '' when it has none.
fn lin_frame_name(ldf ?lindb.Ldf, id u8, data []u8) string {
	if x := ldf {
		if resp := x.response_for(id, data) {
			return resp.name
		}
	}
	return ''
}

// lin_said is how a frame is named in what lin.expect says came instead.
fn lin_said(f lin.Frame, ldf ?lindb.Ldf) string {
	if f.event == .wakeup {
		return 'wakeup'
	}
	name := lin_frame_name(ldf, f.id, f.data)
	return '0x${f.id:02X}${if name == '' { '' } else { ' ' + name }}${lin.key_suffix(f)}'
}

// __lin_expect(h, id or frame name, ms) -> the first error-free frame of that id (a go-to-sleep
// is a MasterReq)
fn l_lin_expect(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.expect: ${err.msg()}') }
	mut want := u8(0)
	if l.arg_is_number(2) {
		want = u8(int_arg(l, 2, 'the id', 0, 63) or { return l.fail('lin.expect: ${err.msg()}') })
	} else {
		name := l.arg_str(2)
		x := h.ldf or { return l.fail('lin.expect: ${h.name} has no LDF, so no frame `${name}`') }
		fr := x.frame(name) or { return l.fail('lin.expect: the LDF has no frame `${name}`') }
		want = fr.id
	}
	ms := env.bounded(ms_up(l, 3))
	until := time.sys_mono_now() + u64(if ms > 0 { ms } else { 0 }) * 1_000_000
	mut order := []string{}
	mut came := map[string]int{}
	for {
		// what is left of the wait, then looks at what is queued
		mut wait := -1
		if ms >= 0 {
			now := time.sys_mono_now()
			wait = if now >= until { 0 } else { int((until - now) / 1_000_000) + 1 }
		}
		f := h.tap.recv(wait) or {
			if err is lin.Timeout {
				break
			}
			return l.fail('lin.expect: ${err.msg()}')
		}
		if f.id == want && f.event != .wakeup && f.errs.is_empty() {
			push_lin_frame(l, f, h.ldf)
			return 1
		}
		key := lin_said(f, h.ldf)
		if key !in came {
			order << key
		}
		came[key]++
	}
	if env.expired() {
		return timeout_at(l)
	}
	what := lin_frame_name(h.ldf, want, [])
	instead := if order.len == 0 {
		'nothing came'
	} else {
		'came instead: ' + order#[..8].map('${it} x${came[it]}').join(', ') +
			if order.len > 8 { ', ...' } else { '' }
	}
	return l.fail('lin.expect: no 0x${want:02X}${if what == '' { '' } else { ' ' + what }} within ${ms} ms; ${instead}')
}

// push_lin_frame pushes a frame as a table: id, pid, name, data (a byte table), errs (names),
// event, origin, t_ms, and where the LDF decodes it signals (by name: physical, else the text,
// else the raw value; a byte array without text its bytes) and raw (a scalar's raw value).
fn push_lin_frame(l lua.State, f lin.Frame, ldf ?lindb.Ldf) {
	l.new_table()
	l.set_int('id', f.id)
	l.set_int('pid', f.pid)
	push_byte_table(l, f.data)
	l.set_field('data')
	l.new_table()
	for i, n in f.errs.names() {
		l.push_str(n)
		l.set_index(i + 1)
	}
	l.set_field('errs')
	l.set_str('event', f.event.str())
	l.set_str('origin', lin.origin_of(f))
	l.set_num('t_ms', clock_ms(f.t_ns))
	x := ldf or { return }
	resp := x.response_for(f.id, f.data) or { return }
	l.set_str('name', resp.name)
	lf := resp.frame or { return }
	if !f.errs.is_empty() || f.event == .wakeup {
		return
	}
	sigs := x.decode(lf, f.data)
	l.new_table()
	for s in sigs {
		if p := s.physical {
			l.set_num(s.name, p)
		} else if s.text != '' {
			l.set_str(s.name, s.text)
		} else if s.is_array {
			push_byte_table(l, s.bytes)
			l.set_field(s.name)
		} else {
			l.set_int(s.name, i64(s.raw))
		}
	}
	l.set_field('signals')
	l.new_table()
	for s in sigs {
		if !s.is_array {
			l.set_int(s.name, i64(s.raw))
		}
	}
	l.set_field('raw')
}

fn push_byte_table(l lua.State, b []u8) {
	l.new_table()
	for i, v in b {
		l.push_int(v)
		l.set_index(i + 1)
	}
}

// __lin_header(h, id)
fn l_lin_header(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.header: ${err.msg()}') }
	id := int_arg(l, 2, 'the id', 0, 63) or { return l.fail('lin.header: ${err.msg()}') }
	h.row.header(u8(id)) or { return l.fail('lin.header: ${err.msg()}') }
	return 0
}

// __lin_set(h, signal, kind, value): kind num (physical where the signal's encoding has a
// physical range, else raw), raw, str or bytes
fn l_lin_set(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.set: ${err.msg()}') }
	signal := l.arg_str(2)
	// the value is read by its kind only: arg_str on a number turns it into a string
	v := match l.arg_str(3) {
		'bytes' {
			lindb.Value(l.arg_bytes(4))
		}
		'str' {
			lindb.Value(l.arg_str(4))
		}
		'num' {
			if lin.has_physical(h.ldf, signal) {
				lindb.Value(l.arg_num(4))
			} else {
				lindb.Value(u64(int_arg(l, 4, 'the raw value of ${signal}', 0, max_i64) or {
					return l.fail('lin.set: ${err.msg()} (its encoding has no physical range)')
				}))
			}
		}
		else {
			lindb.Value(u64(int_arg(l, 4, 'the raw value of ${signal}', 0, max_i64) or {
				return l.fail('lin.set: ${err.msg()}')
			}))
		}
	}
	h.row.set_signal(signal, v) or { return l.fail('lin.set: ${err.msg()}') }
	return 0
}

// __lin_schedule(h, name)
fn l_lin_schedule(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.schedule: ${err.msg()}') }
	h.row.schedule(l.arg_str(2)) or { return l.fail('lin.schedule: ${err.msg()}') }
	return 0
}

// __lin_stop_schedule(h) -> false when the scheduler outlived its bound
fn l_lin_stop_schedule(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.stop_schedule: ${err.msg()}') }
	l.push_bool(h.row.stop_schedule())
	return 1
}

fn l_lin_sleep(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.sleep: ${err.msg()}') }
	h.row.sleep() or { return l.fail('lin.sleep: ${err.msg()}') }
	return 0
}

fn l_lin_wakeup(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.wakeup: ${err.msg()}') }
	h.row.wakeup() or { return l.fail('lin.wakeup: ${err.msg()}') }
	return 0
}

// __lin_status(h) -> the row's view: name, address, role, state, schedule, load, dropped,
// sched (sent, failed, late, running), frames (by id: name, count, errors, cadence_ms), notes
fn l_lin_status(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.status: ${err.msg()}') }
	v := h.row.view()
	l.new_table()
	l.set_str('name', v.name)
	l.set_str('address', v.address)
	l.set_str('role', v.role.str())
	l.set_str('state', v.state.str())
	l.set_str('schedule', v.schedule)
	l.set_num('load', v.load_percent)
	l.set_int('dropped', i64(v.dropped))
	l.new_table()
	l.set_int('sent', i64(v.sched.sent))
	l.set_int('failed', i64(v.sched.failed))
	l.set_int('late', i64(v.sched.late))
	l.set_bool('running', v.sched.running)
	l.set_field('sched')
	l.new_table()
	for fr in v.frames {
		l.new_table()
		l.set_str('name', fr.name)
		l.set_int('count', i64(fr.count))
		l.set_int('errors', i64(fr.errors))
		l.set_num('cadence_ms', fr.cadence_ms)
		l.set_index(fr.id)
	}
	l.set_field('frames')
	l.new_table()
	for i, n in v.notes {
		l.push_str(n)
		l.set_index(i + 1)
	}
	l.set_field('notes')
	return 1
}

// __lin_diagnostics(h) -> dropped (the row's handle's and this tap's), bus_errors, decode_errors
fn l_lin_diagnostics(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.diagnostics: ${err.msg()}') }
	d := h.row.diagnostics()
	l.push_int(i64(d.dropped + h.tap.dropped()))
	l.push_int(i64(d.bus_errors))
	l.push_int(i64(d.decode_errors))
	return 3
}

fn l_lin_close(l lua.State) i32 {
	mut env := env_of(l)
	mut h := env.lin_arg(l, 1) or { return l.fail('lin.close: ${err.msg()}') }
	h.close()
	return 0
}
