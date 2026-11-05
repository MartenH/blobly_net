module script

import os
import blobly.lin

const lin_test_ldf = os.join_path(@VMODROOT, 'dbc', 'lin_demo.ldf')

fn lin_env(bus string) !(&Env, &lin.Row) {
	row := lin.start_row(lin.RowSpec{
		name:     'BODY'
		address:  'inproc:${bus}'
		ldf:      lin_test_ldf
		role:     .master
		simulate: ['CEM', 'LSM', 'RSM']
		schedule: 'NormalTable'
	}, lin.RowOpts{})!
	mut env := new_env([])!
	env.lin_rows = fn [row] () []&lin.Row {
		return [row]
	}
	return env, row
}

// A run's row: its frames decoded, a signal set, a schedule switched, the row's view.
fn test_lin_on_a_row_of_the_run() {
	mut env, mut row := lin_env('sl_body')!
	defer {
		env.close()
		row.stop()
	}
	env.run_source('
test("frames", function()
  local h = lin.open("BODY")
  local f = lin.expect(h, "LSM_Frm2", 500)
  check.equal(f.id, 0x12)
  check.equal(f.name, "LSM_Frm2")
  check.equal(f.origin, "TX-S")
  check.equal(f.event, "frame")
  check.equal(#f.errs, 0)
  check.equal(f.signals.LSMerror, "OK")
  check.equal(f.raw.IntTest, 0)
  lin.set(h, "IntTest", "passed")
  for _ = 1, 20 do
    f = lin.expect(h, 0x12, 500)
    if f.raw.IntTest == 2 then break end
  end
  check.equal(f.signals.IntTest, "passed")
  local c = lin.expect(h, "CEM_Frm2", 500)
  check.equal(c.signals.CabinTemp, 20)
  lin.schedule(h, "FastTable")
  lin.expect(h, "LSM_Frm3", 500)
  local st = lin.status(h)
  check.equal(st.name, "BODY")
  check.equal(st.schedule, "FastTable")
  check.equal(st.state, "active")
  check.truthy(st.frames[0x12].count > 0)
  check.equal(st.frames[0x12].name, "LSM_Frm2")
  lin.close(h)
end)
test("expect names what came", function()
  local h = lin.open("BODY")
  local ok, e = pcall(lin.expect, h, 0x30, 100)
  check.truthy(not ok)
  check.truthy(e:find("no 0x30 within 100 ms; came instead: 0x", 1, true) ~= nil, e)
  ok, e = pcall(lin.open, "NOPE")
  check.truthy(e:find("no LIN row `NOPE` running (BODY)", 1, true) ~= nil, e)
  ok, e = pcall(lin.open, "BODY", { role = "slave" })
  check.truthy(e:find("its role, LDF and rate are the project file", 1, true) ~= nil, e)
end)
')!
	assert env.failed() == 0, env.results.filter(!it.ok).map('${it.name}: ${it.msg}').str()
	assert env.total() == 2
}

// An address is a row of the script's own, stopped at close; a header nobody answers is named.
fn test_lin_on_an_address() {
	mut env := new_env([])!
	env.run_source('
test("own row", function()
  local h = lin.open("inproc:sl_own", { role = "master", ldf = "${lin_test_ldf}" })
  lin.header(h, 0x11)
  local ok, e = pcall(lin.expect, h, "LSM_Frm1", 100)
  check.truthy(e:find("came instead: 0x11 LSM_Frm1/no_response x1", 1, true) ~= nil, e)
  local f = lin.recv(h, 0)
  check.equal(f, nil)
  lin.sleep(h)
  f = lin.recv(h, 500)
  check.equal(f.event, "sleep")
  lin.wakeup(h)
  f = lin.recv(h, 500)
  check.equal(f.event, "wakeup")
  check.equal(lin.diagnostics(h).dropped, 0)
end)
')!
	assert env.failed() == 0, env.results.filter(!it.ok).map('${it.name}: ${it.msg}').str()
	assert env.lins.len == 1 && !env.lins[0].closed
	env.close_reporting()
	assert env.lins[0].closed
	// the own row was stopped: its bus takes a master again
	mut m := lin.open('inproc:sl_own', lin.Config{ role: .master })!
	m.close()
}

// Without a run's rows, a row name is refused saying so.
fn test_lin_names_need_a_run() {
	mut env := new_env([])!
	defer {
		env.close()
	}
	env.run_source('test("gui", function()
  local ok, e = pcall(lin.open, "BODY")
  check.truthy(e:find("was given no run", 1, true) ~= nil, e)
end)')!
	assert env.failed() == 0, env.results.filter(!it.ok).map('${it.name}: ${it.msg}').str()
}

// What a script opened on LIN ends with it: its own bus stopped (the bus takes a master again),
// a run row's tap let go.
fn test_lin_handles_end_with_the_script() {
	mut env, mut row := lin_env('sl_end')!
	defer {
		env.close()
		row.stop()
	}
	env.run_source('lin.open("inproc:sl_end_own", { role = "master" }); lin.open("BODY")')!
	assert env.lins.len == 2 && !env.lins[0].closed && !env.lins[1].closed
	env.close_lin_handles()
	assert env.lins.all(it.closed)
	mut m := lin.open('inproc:sl_end_own', lin.Config{ role: .master })!
	m.close()
	mut tap := env.lins[1].tap
	for {
		tap.recv(0) or {
			assert err.msg().contains('stopped'), err.msg()
			break
		}
	}
}
