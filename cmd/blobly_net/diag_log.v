module main

import os
import time
import uds
import vgui
import script
import diaghold
import project

// ---- The Diagnostics panel's log: one entry per request, as a table ----
//
// Every request a press puts on the carrier is ONE entry (uds.LogEntry, made by the client's
// on_exchange hook — diag_exchange_for): its bytes both ways, the NRC, the latency and the
// responsePending it waited through. What is not a request is an entry of its own kind: a
// connection opened or let go (diag_conn_for, diag_push_conn) or a line the panel had to say
// (diag_note_for, diag_push_refusal). A line ABOUT an answer — a value decoded by the description —
// annotates that answer's entry instead (diag_say_for). uds.LogEntry.line() is the one text form:
// the table's Copy all and the autopress report print it. Copy as Lua turns rows into a script
// (script.lua_from_log).

// DiagRow is one entry with the text the table draws, built once when the table's copy is taken
// rather than every frame.
struct DiagRow {
	e      uds.LogEntry
	clock  string // minutes, seconds and ms: the hour is in the detail and in Copy all
	req    string
	answer string // the answer, and the panel's note after it
	detail string
}

fn diag_row(e uds.LogEntry) DiagRow {
	mut answer := e.response_text()
	if e.note != '' {
		answer += ' — ${e.note}'
	}
	return DiagRow{
		e:      e
		clock:  e.clock.all_after(':')
		req:    if e.is_request() { e.request_text() } else if e.outcome == .connection { 'connection' } else { 'note' }
		answer: answer
		detail: e.detail()
	}
}

// DiagTableUi is the table's controls. GUI thread only.
struct DiagTableUi {
mut:
	errors_only bool
	this_target bool
	sel         map[u64]bool // selected entries, by number
	shown       u64          // the entry whose bytes the detail pane shows
	rows_shown  int          // rows drawn last frame: what tells the table to follow new ones
}

fn log_clock() string {
	t := time.now()
	return '${t.hour:02}:${t.minute:02}:${t.second:02}.${t.nanosecond / 1_000_000:03}'
}

fn (mut app App) diag_append_locked(e uds.LogEntry) u64 {
	seq := app.diag_log.push(uds.LogEntry{
		...e
		clock: log_clock()
	})
	app.diag_gen++
	app.diag_last_push_ns = time.sys_mono_now()
	return seq
}

// diag_push_refusal says a press refused before it was queued, under the target pressed.
fn (mut app App) diag_push_refusal(key string, label string, line string) {
	app.mu.lock()
	app.diag_append_locked(uds.LogEntry{
		outcome: .note
		target:  if label != '' { label } else { key }
		key:     key
		text:    line
		failed:  true
	})
	app.mu.unlock()
}

// diag_push_conn is a connection event no request caused — the holder letting go, its idle
// service, a keep-alive — filed under the target of the connection it is about (`t`, the emitting
// holder's own): the strip's target may already be a newer holder's.
fn (mut app App) diag_push_conn(t DiagTarget, line string, failed bool) {
	app.mu.lock()
	app.diag_append_locked(uds.LogEntry{
		outcome: .connection
		target:  if t.label != '' { t.label } else { t.key }
		key:     t.key
		text:    line
		failed:  failed
	})
	app.mu.unlock()
}

// diag_entry_for appends an entry a REQUEST caused, only under the project it was pressed in
// (diaghold.view_writable): the epoch is compared and the entry appended under ONE take of the
// lock, since a load between the two would clear the log and then receive the stale entry. '' says
// nothing. Returns its number, 0 when nothing was appended.
fn (mut app App) diag_entry_for(req DiagReq, e uds.LogEntry) u64 {
	if !e.is_request() && e.text == '' {
		return 0
	}
	app.mu.lock()
	mut seq := u64(0)
	if diaghold.view_writable(req.epoch, app.diag_epoch) {
		seq = app.diag_append_locked(uds.LogEntry{
			...e
			target: if req.label != '' { req.label } else { req.key }
			key:    req.key
		})
		if e.is_request() {
			app.diag_press_seq = seq
		}
	}
	app.mu.unlock()
	return seq
}

// diag_note_for is a line of a request's that stands on its own: a batch's summary, a refusal.
fn (mut app App) diag_note_for(req DiagReq, line string, failed bool) {
	app.diag_entry_for(req, uds.LogEntry{
		outcome: .note
		text:    line
		failed:  failed
	})
}

// diag_conn_for is a connection event a request caused: the open it made, the let-go it ended in.
fn (mut app App) diag_conn_for(req DiagReq, line string, failed bool) {
	app.diag_entry_for(req, uds.LogEntry{
		outcome: .connection
		text:    line
		failed:  failed
	})
}

// diag_say_for is a line about the answer the press just had: it annotates that answer's entry
// while nothing has come between them (uds.ExchangeLog.annotate), and is a note of its own
// otherwise — a press that failed before it sent anything, a line after a batch.
fn (mut app App) diag_say_for(req DiagReq, line string, failed bool) {
	if line == '' {
		return
	}
	app.mu.lock()
	if diaghold.view_writable(req.epoch, app.diag_epoch) {
		if app.diag_log.annotate(app.diag_press_seq, line, failed) {
			app.diag_gen++
			app.diag_last_push_ns = time.sys_mono_now()
		} else {
			app.diag_append_locked(uds.LogEntry{
				outcome: .note
				target:  if req.label != '' { req.label } else { req.key }
				key:     req.key
				text:    line
				failed:  failed
			})
		}
	}
	app.mu.unlock()
}

// diag_exchange_for logs one exchange of the press `req` (the client's on_exchange, on the holder
// thread), the DID it names called what the target's description calls it.
fn (mut app App) diag_exchange_for(req DiagReq, x uds.Exchange) {
	mut e := uds.entry_of(x)
	if x.req.len >= 3 && (x.req[0] == 0x22 || x.req[0] == 0x2E) {
		e.did_name = req.desc.did_name(u16(x.req[1]) << 8 | u16(x.req[2]))
	}
	app.diag_entry_for(req, e)
}

// diag_log_lines is the log as text, for the autopress report.
fn (mut app App) diag_log_lines() []string {
	app.mu.lock()
	lines := app.diag_log.entries.map(it.line())
	app.mu.unlock()
	return lines
}

// ---- the table ----

// draw_diag_log is the response table under each tab: filters, Copy all, Copy as Lua, the rows
// and the selected row's bytes. `sel_t` is the selected target ("this target only").
fn draw_diag_log(mut app App, sel_t DiagTarget) {
	app.mu.lock()
	fresh := app.diag_rows_gen != app.diag_gen
	entries := if fresh { app.diag_log.entries.clone() } else { []uds.LogEntry{} }
	gen := app.diag_gen
	app.mu.unlock()
	if fresh {
		app.diag_rows = entries.map(diag_row(it))
		app.diag_rows_gen = gen
	}
	mut ui := &app.diag_tbl
	f := uds.LogFilter{
		errors_only: ui.errors_only
		key:         if ui.this_target { sel_t.key } else { '' }
	}
	shown_rows := app.diag_rows.filter(f.keeps(it.e))
	rows := shown_rows.map(it.e)
	// a selection the cap has dropped is forgotten; one a filter hides is kept for when it is
	// shown again, and only what is shown is copied
	if fresh {
		for seq, _ in ui.sel.clone() {
			if !entries.any(it.seq == seq) {
				ui.sel.delete(seq)
			}
		}
	}
	chosen := rows.filter(it.seq in ui.sel)
	vgui.separator_text('responses (newest last)')
	ui.errors_only = vgui.checkbox('errors only', ui.errors_only)
	vgui.same_line()
	ui.this_target = vgui.checkbox('this target only', ui.this_target)
	if vgui.small_button('Copy all##diaglog') {
		vgui.clipboard_set(uds.log_text(rows))
	}
	vgui.set_item_tooltip('the rows shown, as text')
	vgui.same_line()
	if vgui.small_button('Copy as Lua##diaglog') {
		app.diag_copy_lua(if chosen.len > 0 { chosen } else { rows })
	}
	vgui.set_item_tooltip('the selected rows (none selected: every row shown) as a script for cmd/script —\neach request a test checking the answer seen here')
	vgui.same_line()
	vgui.text_dim('${rows.len} row(s)${if chosen.len > 0 { ' · ${chosen.len} selected' } else { '' }} · click selects, Ctrl+click adds')
	sc := app.prefs.ui_scale
	shown := shown_rows.filter(it.e.seq == ui.shown)[0] or { DiagRow{} }
	detail_h := if shown.e.seq != 0 { 6 * vgui.line_height() } else { f32(0) }
	table_h := vgui.content_avail_h() - detail_h
	// the target column only where the rows name more than one
	many := rows.any(it.key != rows[0].key)
	vgui.child_wh('##diaglogbox', 0, if table_h > 60 * sc { table_h } else { 60 * sc })
	// request and answer keep ~250 px each in a narrow panel: it scrolls sideways instead
	min_w := (if many { 820 } else { 740 }) * sc
	if vgui.table_begin_wide(if many { '##diaglog6' } else { '##diaglog5' }, if many { 6 } else { 5 },
		min_w) {
		vgui.table_setup_col('time', 76 * sc)
		if many {
			vgui.table_setup_col('target', 72 * sc)
		}
		vgui.table_setup_col('request', 0)
		vgui.table_setup_col('response', 0)
		vgui.table_setup_col('ms', 44 * sc)
		vgui.table_setup_col('0x78', 36 * sc)
		vgui.table_freeze_top()
		vgui.table_headers()
		follow := rows.len != ui.rows_shown && vgui.scroll_at_bottom()
		for r in shown_rows {
			e := r.e
			vgui.table_row()
			vgui.table_next_col()
			if vgui.selectable_row('${r.clock}##dl${e.seq}', e.seq in ui.sel) {
				if vgui.key_ctrl() {
					if e.seq in ui.sel {
						ui.sel.delete(e.seq)
					} else {
						ui.sel[e.seq] = true
					}
				} else {
					ui.sel = {
						e.seq: true
					}
				}
				ui.shown = e.seq
			}
			if many {
				vgui.table_cell(e.target.all_before('  '))
				vgui.set_item_tooltip(e.target)
			}
			if e.is_request() {
				vgui.table_cell(r.req)
				vgui.set_item_tooltip(r.detail)
				vgui.table_next_col()
				diag_log_answer(r)
				vgui.table_cell(e.latency_text())
				vgui.table_cell(if e.pending > 0 { '${e.pending}' } else { '' })
				if e.pending > 0 {
					vgui.set_item_tooltip('${e.pending_text()} of responsePending')
				}
			} else {
				vgui.table_cell_dim(r.req)
				vgui.table_next_col()
				diag_log_answer(r)
				vgui.table_cell('')
				vgui.table_cell('')
			}
		}
		if follow {
			vgui.scroll_bottom()
		}
		ui.rows_shown = rows.len
		vgui.table_end()
	}
	vgui.child_end()
	if shown.e.seq != 0 {
		vgui.console_text('##diaglogdetail', shown.detail, shown.detail.count('\n') + 1)
	}
}

// diag_log_answer draws a row's answer: red where it is an error, dim for a connection event or
// note that is not, and the panel's own note after the answer.
fn diag_log_answer(r DiagRow) {
	if r.e.is_error() {
		vgui.text_colored(235, 90, 80, r.answer)
	} else if !r.e.is_request() {
		vgui.text_dim(r.answer)
	} else {
		vgui.text(r.answer)
	}
	if r.e.is_request() && r.e.req.len > 0 {
		vgui.set_item_tooltip(r.detail)
	}
}

// diag_copy_lua puts `rows` on the clipboard as a script: each target reached through the
// project channel that carries it, the project named by `-- @project`.
fn (mut app App) diag_copy_lua(rows []uds.LogEntry) {
	vgui.clipboard_set(app.diag_lua(rows))
	n := rows.filter(it.is_request()).len
	app.notify('copied ${n} request(s) as Lua — run it with scripts/runtests.sh <file>')
}

// diag_lua is `rows` as a script.
fn (app &App) diag_lua(rows []uds.LogEntry) string {
	return script.lua_from_log(rows, script.LuaOpts{
		project: if app.proj_path != '' { os.real_path(app.proj_path) } else { '' }
		targets: app.diag_targets().map(app.lua_target(it))
	})
}

// lua_target is how a script reaches `t`: by the channel that carries it (its own, else the
// project channel on its interface), with its ids on CAN — the tester transmits on the id the ECU
// listens on.
fn (app &App) lua_target(t DiagTarget) script.LuaTarget {
	mut ch := t.chan
	if ch == '' {
		ch = (app.proj.channels.filter(it.iface == t.iface)[0] or { project.Channel{} }).name
	}
	// uds.open infers 29-bit addressing from an id above 0x7FF: a 29-bit target on smaller ids
	// cannot be opened as it was reached, so its requests are left as comments
	if !t.carrier.doip && t.ext && t.rx <= 0x7FF && t.tx <= 0x7FF {
		ch = ''
	}
	return script.LuaTarget{
		key:     t.key
		label:   t.label
		channel: ch
		ids:     !t.carrier.doip
		tx:      t.rx
		rx:      t.tx
	}
}
