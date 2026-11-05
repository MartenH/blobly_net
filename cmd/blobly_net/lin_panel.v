module main

import os
import sync
import time
import vgui
import blobly.lin
import blobly.lindb
import blobly.transport

// LIN (View ▸ LIN): the project's LIN rows, run by Start and shown here — apart from the CAN
// rows, which never see one. Each bus is a lin.Row owned by a run worker of its own (lin_worker):
// it starts the row, keeps the frames a tap reads in a bounded list, and stops the row when the
// run ends, so neither Start nor Stop waits for a port on the GUI thread. The panel draws the
// row's view and the list, and asks the row to act (a schedule, a wakeup, a signal); every rule
// is blobly/lin's.

const lin_recent = 500 // frames each bus keeps for the panel
const lin_view_ms = 100.0 // how often a bus's worker takes its view for the panel
const lin_handover_ms = 3000 // the longest a bus waits for the previous run's to let go

// LinRun is one LIN bus of a run: what its worker publishes, read by the panel under `mu`.
@[heap]
struct LinRun {
	name    string
	address string
	role    string
	gen     u64
	ci      int    // its row in app.chans (and app.proj.channels)
	iface   string // the row's interface, what row_is_mine_locked asks
mut:
	mu sync.Mutex
	// prev is the previous run's bus of this name, which may still be letting go of the port;
	// dropped once this one's wait for it is over, so the runs do not chain for ever
	prev ?&LinRun
	// owned: this worker started a row (and stops it before done)
	owned bool
	// row is the bus once its worker started it; none before, or when it did not start (err).
	row     ?&lin.Row
	err     string
	ended   string // why the bus ended while the run was on: its port gone
	recent  []lin.Frame
	done    bool // the worker has stopped its row and gone
	said_rec bool // the worker said a recording leaves its frames out (worker only)
	t0_ns   i64
	// view is the row's view as the worker last took it: the panel never asks the row, whose
	// view on a serial bus waits for the lock a write to the port holds
	view     lin.RowView
	has_view bool
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
	mut before := map[string]&LinRun{}
	for r in app.lin_runs {
		before[r.name] = r
	}
	dir := os.dir(app.proj_path)
	for ci, ch in app.proj.channels {
		if ch.kind() != .lin || !ch.enabled {
			continue
		}
		b := ch
		mut lr := &LinRun{
			name:    b.name
			address: b.address
			role:    b.lin_role
			ci:      ci
			iface:   ch.iface
			gen:     app.run_gen
			prev:    before[b.name] or { none }
			t0_ns:   i64(time.sys_mono_now())
		}
		runs << lr
		app.reserve_run_worker() // released by the worker's own defer
		spawn lin_worker(app, lr, lin.spec_of(b, dir))
	}
	app.mu.lock()
	app.lin_runs = runs
	app.mu.unlock()
}

// lin_rows_fn is what a script asks for the run's LIN rows, at each lin.open.
fn (app &App) lin_rows_fn() fn () []&lin.Row {
	return fn [app] () []&lin.Row {
		mut a := unsafe { app }
		return a.lin_rows_now()
	}
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

// lin_worker holds one LIN bus for its run: waits for the previous run's bus of the name to let
// go (a Stop does not wait for it), starts its row, keeps what a tap reads, and stops the row when
// the run ends or the bus does.
fn lin_worker(app &App, lr &LinRun, spec lin.RowSpec) {
	mut a := unsafe { app }
	mut run := unsafe { lr }
	defer {
		run.mu.lock()
		run.done = true
		run.mu.unlock()
		release_run_worker(app)
	}
	gen := run.gen
	run.mu.lock()
	first := run.prev
	run.mu.unlock()
	if p := first {
		for _ in 0 .. lin_handover_ms / 10 {
			if !a.run_live(gen) {
				// stopped while waiting: whoever comes next waits for what this one waited for
				return
			}
			holder_of(p) or { break }
			time.sleep(10 * time.millisecond)
		}
	}
	run.mu.lock()
	run.prev = none
	run.mu.unlock()
	if !a.run_live(gen) {
		return
	}
	mut row := lin.start_row(spec, lin.RowOpts{}) or {
		run.mu.lock()
		run.err = err.msg()
		run.mu.unlock()
		lin_say(app, gen, 'LIN ${spec.name}: not started — ${err.msg()}')
		return
	}
	for n in row.notes() {
		lin_say(app, gen, n) // each names its bus
	}
	mut tap := row.tap() or {
		row.stop()
		run.mu.lock()
		run.err = err.msg()
		run.mu.unlock()
		lin_say(app, gen, 'LIN ${spec.name}: not started — ${err.msg()}')
		return
	}
	run.mu.lock()
	run.row = row
	run.owned = true
	run.mu.unlock()
	lin_mark(app, run, gen, true)
	mut viewed := i64(0)
	ldf := row.ldf()
	sim := if spec.simulate.len > 0 { ', simulating ${spec.simulate.join(', ')}' } else { '' }
	sched := if spec.schedule != '' { ', schedule ${spec.schedule}' } else { '' }
	lin_say(app, gen, 'LIN ${spec.name} (${spec.address} @ ${row.baud} baud): ${spec.role}${sim}${sched}')
	for a.run_live(gen) {
		now := i64(time.sys_mono_now())
		if now - viewed >= i64(lin_view_ms * 1e6) {
			viewed = now
			publish_view(mut run, mut row)
		}
		f := tap.recv(50) or {
			if err is transport.CarrierGone {
				run.mu.lock()
				run.ended = err.msg()
				run.mu.unlock()
				lin_say(app, gen, 'LIN ${spec.name}: ended — ${err.msg()}')
				lin_mark(app, run, gen, false)
				break
			}
			continue
		}
		mut name := ''
		if l := ldf {
			if resp := l.response_for(f.id, f.data) {
				name = resp.name
			}
		}
		push_lin(app, mut run, gen, f, name)
		run.mu.lock()
		run.recent << f
		if run.recent.len > 2 * lin_recent {
			run.recent = run.recent[run.recent.len - lin_recent..].clone()
		}
		run.mu.unlock()
	}
	if !row.stop() {
		lin_say(app, gen, 'LIN ${spec.name}: its schedule or reader outlived its bound')
	}
	publish_view(mut run, mut row) // the view as the run ended
	d := row.diagnostics()
	if d.dropped > 0 || d.bus_errors > 0 || d.decode_errors > 0 {
		lin_say(app, gen, 'LIN ${spec.name}: ${d.dropped} dropped, ${d.bus_errors} bus errors, ${d.decode_errors} undecodable')
	}
}

// lin_signals is a LIN trace row decoded through the LDF of the bus it came from (by its channel
// name among the run's LIN buses); none where that bus has no LDF or the LDF no frame for it.
// GUI thread.
fn (app &App) lin_signals(r TraceRow) []lindb.SignalValue {
	for run in app.lin_runs {
		if run.name != r.ch {
			continue
		}
		mut lr := unsafe { run }
		lr.mu.lock()
		row_opt := lr.row
		lr.mu.unlock()
		row := row_opt or { return [] }
		l := row.ldf() or { return [] }
		if r.id > 0x3F {
			return []
		}
		resp := l.response_for(u8(r.id), r.data) or { return [] }
		f := resp.frame or { return [] }
		return l.decode(f, r.data)
	}
	return []
}

// push_lin puts a frame in the trace, as a row of its bus: on the trace's clock (a LIN frame is
// stamped on the host's monotonic clock, which t0_ns is on), named from the LDF, its origin the
// frame's publisher (lin.origin_of), grouped apart when it errs or is an event (its flags). The
// row's RX count and `last RX` move only for a frame that shows another node alive
// (lin.is_bus_traffic): the master's own unanswered headers never make a dead slave look current.
fn push_lin(app &App, mut run LinRun, gen u64, f lin.Frame, name string) {
	mut a := unsafe { app }
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	if !a.running || !a.row_is_mine_locked(run.ci, run.iface, gen) {
		return
	}
	t_ms := f64(f.t_ns - i64(a.t0_ns)) / 1_000_000.0
	ch := a.chans[run.ci].name
	if lin.is_bus_traffic(f) {
		a.chans[run.ci].rx++
		a.chans[run.ci].rx_seen++
		a.chans[run.ci].rx_last = t_ms
	}
	if a.recording && !run.said_rec {
		a.log_append_locked('${ch}: LIN frames are shown in the trace but NOT recorded — a recording holds CAN frames')
		run.said_rec = true
	}
	if a.paused {
		return
	}
	id := if lin.has_id(f) { u32(f.id) } else { u32(0xFF) }
	origin := lin.origin_of(f)
	flags := lin.flags_text(f)
	key := gkey_lin(origin, ch, id, flags)
	a.push_row_locked(TraceRow{
		t_ms:      t_ms
		ch:        ch
		origin:    origin
		id:        id
		lin:       true
		lin_flags: flags
		name:      name
		data:      f.data.clone()
		key:       key
	})
	a.gcount[key]++
}

// publish_view takes the row's view and puts it where the panel reads it.
fn publish_view(mut run LinRun, mut row lin.Row) {
	v := row.view()
	run.mu.lock()
	run.view = v
	run.has_view = true
	run.mu.unlock()
}

// holder_of is the bus that may still hold the port a run's bus is about to open: `p` while its
// worker is out; none once a worker that started a row is done; and, for a worker that is done
// without having started one (stopped while it waited), what that worker was waiting for.
fn holder_of(p &LinRun) ?&LinRun {
	mut cur := unsafe { p }
	for {
		cur.mu.lock()
		done := cur.done
		owned := cur.owned
		prev := cur.prev
		cur.mu.unlock()
		if !done {
			return cur
		}
		if owned {
			return none
		}
		next := prev or { return none }
		cur = unsafe { next }
	}
	return none
}

// lin_mark is the bus's row in the Buses panel running or not, while the row is still this run's.
fn lin_mark(app &App, run &LinRun, gen u64, on bool) {
	mut a := unsafe { app }
	a.mu.lock()
	// on only while the run is: a Stop has already cleared every row
	if (!on || a.running) && a.row_is_mine_locked(run.ci, run.iface, gen) {
		a.chans[run.ci].running = on
	}
	a.mu.unlock()
}

// lin_say puts a LIN bus's line in the Log unless a later run has started, whose Log it is not
// about; its own run may have stopped, since a bus says what it counted as it stops.
fn lin_say(app &App, gen u64, msg string) {
	mut a := unsafe { app }
	a.mu.lock()
	ours := a.run_gen == gen
	a.mu.unlock()
	if ours {
		a.notify(msg)
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
	if !app.proj.channels.any(it.kind() == .lin) {
		vgui.text_dim_wrapped('The project has no LIN bus. A LIN bus is a row of buses: with `adapter: lin` — name, address (inproc:<name>, tty:<path>[@baud], pty:<path>[@baud][,plain]), ldf, role, simulate, schedule. See docs/lin.md.')
		vgui.end()
		return
	}
	if app.lin_runs.len == 0 {
		vgui.text_dim('Start runs these LIN buses:')
		for b in app.proj.channels {
			if b.kind() != .lin {
				continue
			}
			on := if b.enabled { '' } else { '  (disabled)' }
			vgui.text('${b.name}   ${b.address}   ${b.lin_role}${on}')
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
	lr.mu.unlock()
	// the controls only while this bus runs: after a Stop or its port going, the view stays and
	// nothing can be asked of the row
	live := app.running && app.run_gen == lr.gen && ended == ''
	if err != '' {
		vgui.text_colored_wrapped(220, 120, 80, 'not started: ${err}')
		return
	}
	mut row := row_opt or {
		vgui.text_dim('starting…')
		return
	}
	lr.mu.lock()
	v := lr.view
	has_view := lr.has_view
	lr.mu.unlock()
	if !has_view {
		vgui.text_dim('starting…')
		return
	}
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
	if live {
		app.draw_lin_controls(i, mut lr, mut row, v)
	} else if ended == '' {
		vgui.text_dim('stopped: the view as the run ended')
	}
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
	if sims.len > 0 && live {
		app.draw_lin_signals(i, mut lr, mut row, sims, v)
	}
	if vgui.tree_node('frames (the last ${lin_recent}, newest first)##linrecent${i}') {
		lr.mu.lock()
		n := if lr.recent.len > lin_recent { lin_recent } else { lr.recent.len }
		recent := lr.recent[lr.recent.len - n..].clone()
		lr.mu.unlock()
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
					go_lin(mut lr, mut row, 'schedule', names[lr.pick], lindb.Value(u64(0)))
				}
				vgui.same_line()
			}
		}
		if vgui.small_button('stop schedule##linstop${i}') {
			go_lin(mut lr, mut row, 'stop schedule', '', lindb.Value(u64(0)))
		}
		vgui.same_line()
		if vgui.small_button('go to sleep##linsleep${i}') {
			go_lin(mut lr, mut row, 'go to sleep', '', lindb.Value(u64(0)))
		}
		vgui.same_line()
	}
	if vgui.small_button('wakeup##linwake${i}') {
		go_lin(mut lr, mut row, 'wakeup', '', lindb.Value(u64(0)))
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

// go_lin does what the panel asks off the GUI thread: a wakeup or a go-to-sleep waits for the slot
// before it, stopping a schedule for the header it may be sending, and a signal set for the bus's
// lock, which a serial bus holds across a write to the port.
fn go_lin(mut lr LinRun, mut row lin.Row, what string, arg string, val lindb.Value) {
	lr.said = ''
	spawn fn (r &lin.Row, run &LinRun, what string, arg string, val lindb.Value) {
		mut rr := unsafe { r }
		mut lrr := unsafe { run }
		mut why := ''
		match what {
			'schedule' {
				rr.schedule(arg) or { why = err.msg() }
			}
			'stop schedule' {
				if !rr.stop_schedule() {
					why = 'the schedule was still sending a header at its bound'
				}
			}
			'go to sleep' {
				rr.sleep() or { why = err.msg() }
			}
			'wakeup' {
				rr.wakeup() or { why = err.msg() }
			}
			else {
				rr.set_signal(arg, val) or { why = err.msg() }
			}
		}
		if why != '' {
			lrr.mu.lock()
			lrr.failed = '${what}: ${why}'
			lrr.mu.unlock()
		}
	}(row, lr, what, arg, val)
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
					go_lin(mut lr, mut row, 'set ${m.name}', m.name, val)
				}
				lr.edits[key] = buf
			}
		}
		vgui.table_end()
	}
	vgui.tree_pop()
}
