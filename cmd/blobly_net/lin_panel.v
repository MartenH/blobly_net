module main

import os
import sync
import time
import vgui
import blobly.lin
import blobly.transport

// LIN (View ▸ LIN): the project's `lin:` buses, run by Start and shown here — apart from the CAN
// rows, which never see one. Each bus is a lin.Row owned by a run worker of its own (lin_worker):
// it starts the row, keeps the frames a tap reads in a bounded list, and stops the row when the
// run ends, so neither Start nor Stop waits for a port on the GUI thread. The panel draws the
// row's view and the list, and asks the row to act (a schedule, a wakeup, a signal); every rule
// is blobly/lin's.

const lin_recent = 500 // frames each bus keeps for the panel
const lin_view_ms = 100.0 // how often the open panel takes a bus's view

// LinRun is one LIN bus of a run: what its worker publishes, read by the panel under `mu`.
@[heap]
struct LinRun {
	name    string
	address string
	role    string
mut:
	mu sync.Mutex
	// row is the bus once its worker started it; none before, or when it did not start (err).
	row     ?&lin.Row
	err     string
	ended   string // why the bus ended while the run was on: its port gone
	recent  []lin.Frame
	t0_ns   i64
	view    lin.RowView
	view_at f64
	// failed is why the last action the panel sent off (go_lin) did not happen, '' if it did
	failed string
	// the panel's own state, GUI thread only
	pick  int
	edits map[string][]u8
	said  string
}

// start_lin spawns a worker per enabled LIN bus of the project. GUI thread, from start(); the list
// is published under app.mu, since a script's worker reads it.
fn (mut app App) start_lin() {
	mut runs := []&LinRun{}
	dir := os.dir(app.proj_path)
	for b in app.proj.lin {
		if !b.enabled {
			continue
		}
		mut lr := &LinRun{
			name:    b.name
			address: b.address
			role:    b.role
			t0_ns:   i64(time.sys_mono_now())
		}
		runs << lr
		app.reserve_run_worker() // released by the worker's own defer
		spawn lin_worker(app, lr, lin.spec_of(b, dir), app.run_gen)
	}
	app.mu.lock()
	app.lin_runs = runs
	app.mu.unlock()
}

// lin_rows_now is the running run's LIN rows that started: what a script's lin.open reaches by
// name. None while stopped. Any thread.
fn (mut app App) lin_rows_now() []&lin.Row {
	app.mu.lock()
	mut runs := if app.running { app.lin_runs.clone() } else { []&LinRun{} }
	app.mu.unlock()
	mut out := []&lin.Row{}
	for mut lr in runs {
		lr.mu.lock()
		if r := lr.row {
			out << r
		}
		lr.mu.unlock()
	}
	return out
}

// lin_worker holds one LIN bus for the run `gen`: starts its row, keeps what a tap reads, and
// stops the row when the run ends or the bus does.
fn lin_worker(app &App, lr &LinRun, spec lin.RowSpec, gen u64) {
	defer {
		release_run_worker(app)
	}
	mut a := unsafe { app }
	mut run := unsafe { lr }
	mut row := lin.start_row(spec, lin.RowOpts{}) or {
		run.mu.lock()
		run.err = err.msg()
		run.mu.unlock()
		a.notify('LIN ${spec.name}: not started — ${err.msg()}')
		return
	}
	for n in row.notes() {
		a.notify(n) // each names its bus
	}
	mut tap := row.tap() or {
		row.stop()
		run.mu.lock()
		run.err = err.msg()
		run.mu.unlock()
		a.notify('LIN ${spec.name}: not started — ${err.msg()}')
		return
	}
	run.mu.lock()
	run.row = row
	run.mu.unlock()
	sim := if spec.simulate.len > 0 { ', simulating ${spec.simulate.join(', ')}' } else { '' }
	sched := if spec.schedule != '' { ', schedule ${spec.schedule}' } else { '' }
	a.notify('LIN ${spec.name} (${spec.address} @ ${row.baud} baud): ${spec.role}${sim}${sched}')
	for a.run_live(gen) {
		f := tap.recv(50) or {
			if err is transport.CarrierGone {
				run.mu.lock()
				run.ended = err.msg()
				run.mu.unlock()
				a.notify('LIN ${spec.name}: ended — ${err.msg()}')
				break
			}
			continue
		}
		run.mu.lock()
		run.recent << f
		if run.recent.len > 2 * lin_recent {
			run.recent = run.recent[run.recent.len - lin_recent..].clone()
		}
		run.mu.unlock()
	}
	if !row.stop() {
		a.notify('LIN ${spec.name}: its schedule or reader outlived its bound')
	}
	d := row.diagnostics()
	if d.dropped > 0 || d.bus_errors > 0 || d.decode_errors > 0 {
		a.notify('LIN ${spec.name}: ${d.dropped} dropped, ${d.bus_errors} bus errors, ${d.decode_errors} undecodable')
	}
}

fn draw_lin(mut app App) {
	vgui.set_next_window(220, 140, 1180, 620)
	vis, op := vgui.begin_closable('LIN', app.show_lin)
	app.show_lin = op
	if !vis {
		vgui.end()
		return
	}
	if app.proj.lin.len == 0 {
		vgui.text_dim_wrapped('The project has no LIN bus. They are a list of their own, `lin:`, beside `buses:` — name, address (inproc:<name>, tty:<path>[@baud], pty:<path>[@baud][,plain]), ldf, role, simulate, schedule. See docs/lin.md.')
		vgui.end()
		return
	}
	if app.lin_runs.len == 0 {
		vgui.text_dim('Start runs these LIN buses:')
		for b in app.proj.lin {
			on := if b.enabled { '' } else { '  (disabled)' }
			vgui.text('${b.name}   ${b.address}   ${b.role}${on}')
		}
		vgui.end()
		return
	}
	for i, mut lr in app.lin_runs {
		draw_lin_run(mut app, i, mut lr)
	}
	vgui.end()
}

fn draw_lin_run(mut app App, i int, mut lr LinRun) {
	sc := app.prefs.ui_scale
	vgui.separator_text('${lr.name}   ${lr.address}   ${lr.role}')
	lr.mu.lock()
	row_opt := lr.row
	err := lr.err
	ended := lr.ended
	n := if lr.recent.len > lin_recent { lin_recent } else { lr.recent.len }
	recent := lr.recent[lr.recent.len - n..].clone()
	lr.mu.unlock()
	if err != '' {
		vgui.text_colored_wrapped(220, 120, 80, 'not started: ${err}')
		return
	}
	mut row := row_opt or {
		vgui.text_dim('starting…')
		return
	}
	now_ms := f64(time.sys_mono_now()) / 1e6
	if lr.view_at == 0 || now_ms - lr.view_at >= lin_view_ms {
		lr.view_at = now_ms
		lr.view = row.view()
	}
	v := lr.view
	if ended != '' {
		vgui.text_colored_wrapped(220, 120, 80, 'ended: ${ended}')
	}
	state := match v.state {
		.active { 'active' }
		.sleep { 'asleep' }
		.short { 'shorted' }
	}
	mut parts := [state, '${row.baud} baud', 'load ${v.load_percent:.1f} %']
	if v.schedule != '' {
		parts << 'schedule ${v.schedule}: ${v.sched.sent} headers'
		if v.sched.late > 0 {
			parts << '${v.sched.late} late'
		}
		if v.sched.failed > 0 {
			parts << '${v.sched.failed} refused'
		}
	}
	if v.dropped > 0 {
		parts << '${v.dropped} dropped by a full reader'
	}
	vgui.text(parts.join('   ·   '))
	if v.sched.last_error != '' {
		vgui.text_colored_wrapped(220, 120, 80, 'schedule: ${v.sched.last_error}')
	}
	app.draw_lin_controls(i, mut lr, mut row, v)
	if v.notes.len > 0 && vgui.tree_node('LDF notes (${v.notes.len})##linnotes${i}') {
		for note in v.notes {
			vgui.text_dim_wrapped(note)
		}
		vgui.tree_pop()
	}
	sims := row.simulated_frames()
	if vgui.table_begin_flat('##linids${i}', 7) {
		vgui.table_setup_col('id', 50 * sc)
		vgui.table_setup_col('frame', 150 * sc)
		vgui.table_setup_col('frames', 60 * sc)
		vgui.table_setup_col('errors', 55 * sc)
		vgui.table_setup_col('cadence', 75 * sc)
		vgui.table_setup_col('last', 370 * sc)
		vgui.table_setup_col('signals', 420 * sc)
		vgui.table_headers()
		for f in v.frames {
			vgui.table_row()
			vgui.table_set_col(0)
			vgui.text('0x${f.id:02X}')
			vgui.table_set_col(1)
			vgui.text(f.name)
			vgui.table_set_col(2)
			vgui.text('${f.count}')
			vgui.table_set_col(3)
			if f.errors > 0 {
				vgui.text_colored(220, 120, 80, '${f.errors}')
			} else {
				vgui.text_dim('0')
			}
			vgui.table_set_col(4)
			if f.cadence_ms > 0 {
				vgui.text('${f.cadence_ms:.1f} ms')
			}
			vgui.table_set_col(5)
			vgui.text('${lin.origin_of(f.last)}  ${lin.reading(f.last)}')
			vgui.table_set_col(6)
			vgui.text(f.signals.map(lin.signal_text(it)).join('   '))
			if f.name in sims {
				vgui.set_item_tooltip('published by this row: set its signals below')
			}
		}
		vgui.table_end()
	}
	if sims.len > 0 {
		app.draw_lin_signals(i, mut lr, mut row, sims, v)
	}
	if vgui.tree_node('frames (${recent.len}, newest first)##linrecent${i}') {
		vgui.child_begin('##linlog${i}', 220 * sc)
		for k := recent.len - 1; k >= 0; k-- {
			f := recent[k]
			t := f64(f.t_ns - lr.t0_ns) / 1e6
			vgui.text('${t:10.3f}  ${lin.origin_of(f):-4}  ${lin.reading(f)}')
		}
		vgui.child_end()
		vgui.tree_pop()
	}
}

// draw_lin_controls is what the row's role lets the operator do: a master runs and stops
// schedules and sends the go-to-sleep command; a master or a slave sends a wakeup.
fn (mut app App) draw_lin_controls(i int, mut lr LinRun, mut row lin.Row, v lin.RowView) {
	if v.role == .monitor {
		return
	}
	if v.role == .master {
		if l := row.ldf() {
			names := l.schedules.map(it.name)
			if names.len > 0 {
				if lr.pick >= names.len {
					lr.pick = 0
				}
				vgui.set_next_item_width(180 * app.prefs.ui_scale)
				lr.pick = vgui.combo('##linsched${i}', names, lr.pick)
				vgui.same_line()
				if vgui.small_button('run schedule##linrun${i}') {
					go_lin(mut lr, mut row, 'schedule', names[lr.pick])
				}
				vgui.same_line()
			}
		}
		if vgui.small_button('stop schedule##linstop${i}') {
			go_lin(mut lr, mut row, 'stop schedule', '')
		}
		vgui.same_line()
		if vgui.small_button('go to sleep##linsleep${i}') {
			go_lin(mut lr, mut row, 'go to sleep', '')
		}
		vgui.same_line()
	}
	if vgui.small_button('wakeup##linwake${i}') {
		go_lin(mut lr, mut row, 'wakeup', '')
	}
	lr.mu.lock()
	if lr.failed != '' {
		lr.said = lr.failed
		lr.failed = ''
	}
	lr.mu.unlock()
	if lr.said != '' {
		vgui.same_line()
		vgui.text_colored(220, 120, 80, lr.said)
	}
}

// go_lin does what a button asks off the GUI thread: a wakeup or a go-to-sleep waits for the slot
// before it, and stopping a schedule for the header it may be sending.
fn go_lin(mut lr LinRun, mut row lin.Row, what string, schedule string) {
	lr.said = ''
	spawn fn (r &lin.Row, run &LinRun, what string, schedule string) {
		mut rr := unsafe { r }
		mut lrr := unsafe { run }
		mut why := ''
		match what {
			'schedule' {
				rr.schedule(schedule) or { why = err.msg() }
			}
			'stop schedule' {
				if !rr.stop_schedule() {
					why = 'the schedule was still sending a header at its bound'
				}
			}
			'go to sleep' {
				rr.sleep() or { why = err.msg() }
			}
			else {
				rr.wakeup() or { why = err.msg() }
			}
		}
		if why != '' {
			lrr.mu.lock()
			lrr.failed = '${what}: ${why}'
			lrr.mu.unlock()
		}
	}(row, lr, what, schedule)
}

// draw_lin_signals edits what the row's simulated nodes publish: a value per signal, typed as
// one is shown (a number, a logical value's text, a byte array's bytes in hex; raw:N, phys:X,
// text:... and bytes:01 02 say which), put out from the next response.
fn (mut app App) draw_lin_signals(i int, mut lr LinRun, mut row lin.Row, sims []string, v lin.RowView) {
	if !vgui.tree_node('simulated signals##linsig${i}') {
		return
	}
	l := row.ldf() or {
		vgui.tree_pop()
		return
	}
	sc := app.prefs.ui_scale
	if vgui.table_begin_flat('##linsigs${i}', 4) {
		vgui.table_setup_col('frame', 150 * sc)
		vgui.table_setup_col('signal', 150 * sc)
		vgui.table_setup_col('now', 260 * sc)
		vgui.table_setup_col('set (Enter)', 220 * sc)
		vgui.table_headers()
		for fname in sims {
			lf := l.frame(fname) or { continue }
			mut now := map[string]string{}
			for f in v.frames {
				if f.id == lf.id {
					for s in f.signals {
						now[s.name] = lin.signal_text(s).all_after('=')
					}
				}
			}
			for m in lf.signals {
				vgui.table_row()
				vgui.table_set_col(0)
				vgui.text(fname)
				vgui.table_set_col(1)
				vgui.text(m.name)
				vgui.table_set_col(2)
				vgui.text_dim(now[m.name] or { '' })
				vgui.table_set_col(3)
				key := m.name
				if key !in lr.edits {
					lr.edits[key] = []u8{len: 64}
				}
				mut buf := lr.edits[key]
				vgui.set_next_item_width(200 * sc)
				if vgui.input_text_enter('##linset${i}_${key}', mut buf) {
					text := vgui.buf_str(buf)
					val := lin.value_of_text(l, m.name, text) or {
						lr.said = err.msg()
						continue
					}
					row.set_signal(m.name, val) or {
						lr.said = err.msg()
						continue
					}
					lr.said = ''
				}
				lr.edits[key] = buf
			}
		}
		vgui.table_end()
	}
	vgui.tree_pop()
}
