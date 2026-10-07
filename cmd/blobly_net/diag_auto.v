module main

import os
import time
import vgui
import uds
import diaghold

// DiagAutopress is a dev hook, inert unless BLOBLY_DIAG_PRESS is set: the Diagnostics panel's
// buttons pressed in order from the frame loop, for the headless screenshot and for timing the
// panel end to end (VGUI_FRAMES / VGUI_SHOT cannot click). A comma-separated list of
// `session`, `vin`, `tp`, `did:<hex>`, `wait:<ms>`, `target:<label substring>`, `connect` (the
// strip's Connect), `disconnect`, `stop` (the measurement stopped, as the toolbar's Stop), `pane:<px>` (the
// DTC/DIDs divider dragged to that height),
// `logsel:<n>` (the response table's n-th entry selected, its bytes shown), `copylua:<file>` (Copy
// as Lua of every entry, into the file),
// `script:<path>` (started as the Script panel's Run starts one), the DTC tab's `tab:dtc`,
// `dtcs`, `dtc:<display or hex code>` (select a row), `dtc_clear`, `dtc_off`, `dtc_on` and `auto`
// (the auto-refresh tick on), and the DIDs tab's `tab:did`, `did_all` (Read all),
// `did_read:<hex>`, `did_edit:<hex>` (the write dialog, opened and left open) and
// `did_write:<hex>=<part>;<part>…` (the dialog filled and its Write pressed); each press waits for the
// previous one to finish. Each press's time, from the press to its line, goes to stdout, and once
// the list is done (and a started script has finished) the panel's lines and the script's.
struct DiagAutopress {
mut:
	steps       []string
	at          int
	waiting     bool // a press is out and not finished
	gen_at      u64 // diag_gen when it went out
	press_ns    u64
	until_ms    i64 // a `wait:` ends here
	total_ns    u64
	presses     int
	script_ns   u64 // when a `script:` step started one
	script_end  u64 // when a frame first saw it finished
	script_seen bool // a frame saw it running
	reported    bool
	stopped     bool // a `stop` step ran: the later steps go on with the measurement stopped
}

// autopress_timeout_ns bounds one press's wait for its line.
const autopress_timeout_ns = u64(60_000_000_000)

fn (mut app App) diag_autopress_init() {
	spec := os.getenv('BLOBLY_DIAG_PRESS')
	if spec == '' {
		return
	}
	app.diag_auto.steps = spec.split(',').map(it.trim_space()).filter(it != '')
	app.show_diag = true
}

// diag_autopress_step runs from draw_diag every frame, with the listed targets.
fn (mut app App) diag_autopress_step(targets []DiagTarget) {
	mut au := &app.diag_auto
	if au.steps.len == 0 {
		return
	}
	// the steps start once the run is on, and go on stopped only after a `stop` step of their own
	if !app.running && !au.stopped {
		return
	}
	// frames keep coming, so VGUI_FRAMES (which this hook is run under) ends a quiet project too
	vgui.wake()
	if au.reported {
		return
	}
	app.mu.lock()
	busy := app.diag_busy
	dgen := app.diag_gen
	last_ns := app.diag_last_push_ns
	sbusy := app.script_busy
	app.mu.unlock()
	if au.script_ns != 0 && au.script_end == 0 {
		if sbusy {
			au.script_seen = true
		} else if au.script_seen {
			au.script_end = time.sys_mono_now()
		}
	}
	if au.waiting {
		if busy || dgen == au.gen_at {
			// a press that never finishes — refused in silence, or a defect — must not hold the
			// run until VGUI_FRAMES ends it with no report
			if time.sys_mono_now() - au.press_ns > autopress_timeout_ns {
				// the press is still out, so no later step could run: end the run with its report
				au.waiting = false
				println('diag-autopress: ${au.steps[au.at - 1]} no line within ${autopress_timeout_ns / 1_000_000_000} s; aborting the run')
				app.diag_autopress_report()
			}
			return
		}
		au.waiting = false
		au.total_ns += last_ns - au.press_ns
		au.presses++
		ms := f64(last_ns - au.press_ns) / 1e6
		println('diag-autopress: ${au.steps[au.at - 1]} ${ms:.1f} ms')
		return
	}
	if au.until_ms > 0 {
		if time.ticks() < au.until_ms {
			return
		}
		au.until_ms = 0
	}
	if au.at >= au.steps.len {
		if au.script_ns != 0 && au.script_end == 0 {
			// the script is still going: report once it has finished
			return
		}
		app.diag_autopress_report()
		return
	}
	// not while a press is in flight (the auto-refresh's): it would be refused as busy, which
	// writes no line, and this hook would wait for one
	if busy {
		return
	}
	step := au.steps[au.at]
	au.at++
	if step.starts_with('wait:') {
		au.until_ms = time.ticks() + step.all_after(':').i64()
		return
	}
	if step.starts_with('target:') {
		want := step.all_after(':')
		for t in targets {
			if t.label.contains(want) {
				app.diag_sel_key = t.key
				break
			}
		}
		return
	}
	if step.starts_with('logsel:') {
		// the response table's row at this index (of every entry), selected as a click selects it
		app.mu.lock()
		entries := app.diag_log.entries.clone()
		app.mu.unlock()
		i := step.all_after(':').int()
		if i >= 0 && i < entries.len {
			app.diag_tbl.sel = {
				entries[i].seq: true
			}
			app.diag_tbl.shown = entries[i].seq
		}
		return
	}
	if step.starts_with('copylua:') {
		// Copy as Lua of every entry, written to a file instead of the clipboard
		app.mu.lock()
		entries := app.diag_log.entries.clone()
		app.mu.unlock()
		os.write_file(step.all_after(':'), app.diag_lua(entries)) or {
			println('diag-autopress: ${step}: ${err}')
		}
		return
	}
	if step == 'disconnect' {
		app.diag_disconnect()
		return
	}
	if step.starts_with('pane:') {
		// the tabs' divider dragged to this height (unscaled px), as a drag sets it
		app.diag_tab_h = step.all_after(':').f32()
		return
	}
	if step == 'stop' {
		// the measurement stopped as the toolbar's Stop does: the panel keeps showing what it read
		au.stopped = true
		app.stop()
		return
	}
	if step.starts_with('script:') {
		au.script_ns = time.sys_mono_now()
		app.reserve_tool_reader()
		spawn script_worker(app, step.all_after(':'))
		return
	}
	if step == 'tab:dtc' {
		app.dtc_ui.select_tab = true
		return
	}
	if step == 'auto' {
		app.dtc_ui.auto = true
		return
	}
	if step == 'tab:did' {
		app.did_ui.select_tab = true
		return
	}
	if step == 'did_all' || step.starts_with('did_read:') || step.starts_with('did_edit:')
		|| step.starts_with('did_write:') {
		t := targets.filter(it.key == app.diag_sel_key)[0] or { targets[0] or { DiagTarget{} } }
		desc := app.diag_desc(t)
		own, iso := did_rows(desc)
		app.did_ui.select_tab = true // the write dialog is drawn by the tab
		if step == 'did_all' {
			mut ids := own.map(it.id)
			ids << iso.map(it.id)
			au.gen_at = dgen
			au.press_ns = time.sys_mono_now()
			au.waiting = true
			app.did_press(DiagReq{
				kind: 'did_read_all'
				dids: ids
			}, desc)
			return
		}
		arg := step.all_after(':')
		id := diaghold.parse_did(arg.all_before('=')) or {
			println('diag-autopress: ${step}: not a DID')
			return
		}
		if step.starts_with('did_read:') {
			au.gen_at = dgen
			au.press_ns = time.sys_mono_now()
			au.waiting = true
			app.did_press(DiagReq{
				kind: 'did_read'
				did:  id
			}, desc)
			return
		}
		x := desc.desc.did(id) or {
			println('diag-autopress: ${step}: no DID ${id:04X} in the description')
			return
		}
		app.mu.lock()
		view := if app.did_view.owns(t.key, desc.ident) { app.did_view } else { DidView{} }
		app.mu.unlock()
		app.did_edit(x, view, desc)
		if step.starts_with('did_write:') {
			app.did_ui.edit_bufs = arg.all_after('=').split(';').map(mkbuf(it, did_edit_room(x, it)))
			app.did_ui.auto_write = true
			au.gen_at = dgen
			au.press_ns = time.sys_mono_now()
			au.waiting = true
		}
		return
	}
	if step in ['dtcs', 'dtc_clear', 'dtc_off', 'dtc_on'] || step.starts_with('dtc:') {
		t := targets.filter(it.key == app.diag_sel_key)[0] or { targets[0] or { DiagTarget{} } }
		desc := app.diag_desc(t)
		au.gen_at = dgen
		au.press_ns = time.sys_mono_now()
		au.waiting = true
		match step {
			'dtcs' {
				app.dtc_press('dtcs', 0, false, false, desc)
			}
			'dtc_clear' {
				app.dtc_press('dtc_clear', 0, false, false, desc)
			}
			'dtc_off', 'dtc_on' {
				app.dtc_press('dtc_setting', 0, step == 'dtc_on', false, desc)
			}
			else {
				arg := step.all_after(':')
				code := uds.dtc_code(arg) or { u32(('0x' + arg).u64()) }
				app.dtc_select(code, false, desc)
				if !app.running {
					au.waiting = false // stopped, a selection asks nothing: no line to wait for
				}
			}
		}
		return
	}
	mut kind := step
	mut did := u16(0)
	if step.starts_with('did:') {
		kind = 'did'
		did = u16(('0x' + step.all_after(':')).u64())
	}
	au.gen_at = dgen
	au.press_ns = time.sys_mono_now()
	au.waiting = true
	app.diag_press(kind, did)
}

fn (mut app App) diag_autopress_report() {
	mut au := &app.diag_auto
	au.reported = true
	total := f64(au.total_ns) / 1e6
	println('diag-autopress: ${au.presses} presses, ${total:.1f} ms in all')
	lines := app.diag_log_lines()
	app.mu.lock()
	slines := app.script_log.clone()
	app.mu.unlock()
	for l in lines {
		println('diag-log: ${l}')
	}
	if au.script_ns != 0 {
		for l in slines {
			println('script-log: ${l}')
		}
		ms := f64(au.script_end - au.script_ns) / 1e6
		println('diag-autopress: script ran ${ms:.0f} ms')
	}
}
