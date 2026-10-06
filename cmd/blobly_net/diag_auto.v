module main

import os
import time
import vgui
import uds

// DiagAutopress is a dev hook, inert unless BLOBLY_DIAG_PRESS is set: the Diagnostics panel's
// buttons pressed in order from the frame loop, for the headless screenshot and for timing the
// panel end to end (VGUI_FRAMES / VGUI_SHOT cannot click). A comma-separated list of
// `session`, `vin`, `tp`, `did:<hex>`, `wait:<ms>`, `target:<label substring>`, `disconnect`,
// `script:<path>` (started as the Script panel's Run starts one), and the DTC tab's `tab:dtc`,
// `dtcs`, `dtc:<display or hex code>` (select a row), `dtc_clear`, `dtc_off`, `dtc_on` and `auto`
// (the auto-refresh tick on); each press waits for the
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
}

fn (mut app App) diag_autopress_init() {
	spec := os.getenv('BLOBLY_DIAG_PRESS')
	if spec == '' {
		return
	}
	app.diag_auto.steps = spec.split(',').map(it.trim_space()).filter(it != '')
	app.show_diag = true
}

// diag_autopress_step runs from draw_diag once the run is on, with the current target list.
fn (mut app App) diag_autopress_step(targets []DiagTarget) {
	mut au := &app.diag_auto
	if au.steps.len == 0 {
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
	if step == 'disconnect' {
		app.diag_disconnect()
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
	app.mu.lock()
	lines := app.diag_log.clone()
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
