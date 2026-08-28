// blobly_net — the Dear ImGui + ImPlot frontend for blobly_net (phased migration off
// vlang/gui; see docs/gui_toolkit_evaluation.md).
//   Phase 1: live decoded Trace + Trace Chart swimlane, docked in one window.
//   Phase 2: menu bar (File/View) + Start/Stop measurement lifecycle + a Buses panel with
//            per-channel enable + state colour + RX counts. Channels open on ▶ Start, not
//            at boot. All engine work reuses the GUI-free modules (project/transport/candb/
//            telem) unchanged; gui's src/main.v stays the shipping app until parity.
//
// Build: libs/vgui/build_deps.sh  then
//   v -enable-globals -cc gcc -path "@vlib|@vmodules|modules|libs" run cmd/blobly_net/
// (the DIRECTORY — the app is many files in one `module main`; naming one file fails on the
// first cross-file reference)
// Project: argv[1] (a .blobnet path — the Windows file association passes it), else
// BLOBLY_PROJECT, else projects/sim-demo.blobnet (driver-free, runs on a clean machine —
// the old trace-demo default needed vcan0 + a blobly_emb target). Env: VGUI_WAKE_MS cap.
module main

import os
import time
import vgui

// load_ui_font replaces imgui's blocky default (ProggyClean) with a real TTF: VGUI_FONT
// if set, else the first available system monospace (DejaVu Sans Mono / Consolas). Keeping
// it monospace keeps the hex/data columns aligned.
fn load_ui_font() {
	mut candidates := []string{}
	env := os.getenv('VGUI_FONT')
	if env != '' {
		candidates << env
	}
	candidates << [
		'/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
		'/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
		'/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf',
		'C:/Windows/Fonts/consola.ttf',
		'C:/Windows/Fonts/segoeui.ttf',
	]
	sz := os.getenv('VGUI_FONT_SIZE').int()
	size := if sz > 0 { f32(sz) } else { f32(16) }
	for f in candidates {
		if f != '' && os.exists(f) {
			if vgui.add_font(f, size) {
				return
			}
		}
	}
}

fn main() {
	if '--version' in os.args || '-V' in os.args {
		// scripts and bug reports need the version without a window; -V not -v, which V's
		// own tooling and many CLIs reserve for verbose
		println('blobly_net ${app_version}')
		return
	}
	// Capture any CALLER-supplied project path FIRST, absolutized against the caller's
	// cwd — the re-anchoring chdir below would otherwise re-base a relative argv/env
	// path under the bundle directory and fail to open it (codex #63 r3).
	mut proj_path := ''
	mut caller_supplied := false
	if env := os.getenv_opt('BLOBLY_PROJECT') {
		proj_path = env
		caller_supplied = true
	}
	if os.args.len > 1 && os.args[1].to_lower().ends_with('.blobnet') {
		// Explorer's `.blobnet` association launches `blobly_net.exe "<file>"` — without
		// this the association opened the app but silently ignored the chosen project.
		// to_lower: the Windows association matches extensions case-insensitively.
		proj_path = os.args[1]
		caller_supplied = true
	}
	if caller_supplied {
		proj_path = os.abs_path(proj_path)
	}
	// A file-association launch keeps the CALLER's working directory, so every
	// bundle-root-relative asset (projects/, dbc/, tests/, docs/, samples/) would miss.
	// Re-anchor to the executable's directory — but only when the cwd clearly isn't a
	// bundle/repo root already, so `v run` from the checkout keeps working unchanged.
	exe_dir := os.dir(os.executable())
	if !os.exists('projects') && os.exists(os.join_path(exe_dir, 'projects')) {
		os.chdir(exe_dir) or {}
	}
	if proj_path == '' {
		proj_path = 'projects/sim-demo.blobnet' // bundle-relative: resolved AFTER the anchor
	}
	mut wake_ms := os.getenv('VGUI_WAKE_MS').i64()
	if wake_ms <= 0 {
		wake_ms = 33
	}
	max_frames := os.getenv('VGUI_FRAMES').int()
	shot := os.getenv('VGUI_SHOT')

	mut app := &App{
		t0_ns:   time.sys_mono_now()
		wake_ms: wake_ms
	}
	app.send_id_buf = mkbuf('101', 24)
	app.send_data_buf = mkbuf('01', 64)
	app.diag_did_buf = mkbuf('F190', 16)
	app.script_path_buf = mkbuf('tests/diag_basic.lua', 256)
	app.shell_buf = mkbuf('', 128)
	app.eth_target_buf = mkbuf('', 64)
	app.flash_img_buf = mkbuf('', 256)
	app.flash_base_buf = mkbuf('08020000', 16)
	app.flash_req_buf = mkbuf('7B0', 12)
	app.flash_rsp_buf = mkbuf('7B8', 12)
	app.flash_ver_buf = mkbuf('1', 12)
	app.trace_filter_buf = mkbuf('', 64)
	app.trace_filter2_buf = mkbuf('', 64)
	app.symbol_filter_buf = mkbuf('', 64)
	app.doip_host_buf = mkbuf('127.0.0.1', 64)
	app.load_project(proj_path)
	println('blobly_net: ${app.proj_name} — ${app.chans.len} channel(s), ${app.dbs.len} DBC(s), manifest=${app.has_manifest}. Press Start.')

	// Headless self-test of the Configuration editor: drive the real methods (New → add bus →
	// edit fields → add DBC → Save As) and assert the written .blobnet round-trips. Exits after.
	// The editor's widgets can't be clicked under WSLg, so this smoke covers the logic instead.
	if os.getenv('BLOBLY_SELFTEST_CONFIG') != '' {
		selftest_config(mut app)
		return
	}

	if os.getenv('BLOBLY_SELFTEST_DBC') != '' {
		app.show_dbc = true
		if !vgui.init('blobly_net ${app_version} — selftest', 1500, 850, true) {
			eprintln('vgui.init failed')
			return
		}
		for frame in 0 .. 10 {
			vgui.frame_begin()
			if app.dbs.len > 0 {
				app.dbc_ed.db = 0
				if frame > 2 && app.dbs[0].messages.len > 0 {
					app.dbc_ed.msg = 0
				}
				if frame > 5 && app.dbs[0].messages.len > 0
					&& app.dbs[0].messages[0].signals.len > 0 {
					app.dbc_ed.sig = 0
				}
			}
			draw_dbc_editor(mut app)
			vgui.frame_end()
		}
		vgui.shutdown()
		println('selftest_dbc: ok')
		return
	}

	// A LARGER FIXED window — deliberately not maximized (that experiment scrambled layouts
	// persisted at the old size; View > Reset Layout is the recovery) and deliberately not
	// clamped to the monitor (a clamp made these sizes machine-dependent, which the headless
	// branch exists to prevent). HEADLESS runs (VGUI_FRAMES / VGUI_SHOT — the documented GUI
	// smoke) keep 1500x850: a screenshot's dimensions must not depend on the monitor.
	headless := max_frames > 0 || shot != ''
	init_w, init_h := if headless { 1500, 850 } else { 1800, 1000 }
	if !vgui.init('blobly_net ${app_version} — ${app.proj_name}', init_w, init_h, true) {
		eprintln('vgui.init failed')
		return
	}
	set_app_icon() // the B-on-blue window/taskbar icon (procedural placeholder as fallback)
	app.load_logo() // the menu-bar wordmark (needs the GL context, so after init)
	load_ui_font()
	if os.getenv('BLOBLY_THEME') == 'light' {
		app.dark = false
		vgui.set_theme(false)
	}
	// Dev hook: open the Configuration editor at startup (it can't be reached via synthetic
	// typing under WSLg, so this is how it gets screenshot-verified). Mirrors BLOBLY_AUTOSTART.
	if os.getenv('BLOBLY_SHOW_CONFIG') != '' {
		app.show_config = true
	}
	// Autostart defers the measurement start until the GL context has SETTLED. On Windows the
	// GPU driver maps/unmaps its own DLL data sections during the first presented frames; if a
	// worker thread triggers a Boehm GC collection inside that window, the collector faults
	// scanning a mid-remap driver data root (SIGSEGV in GC_mark_from, thirdparty/libgc). Starting
	// after ~`autostart_frame` presented frames clears the race. A human pressing Start is always
	// well past this, so it only matters for BLOBLY_AUTOSTART / automated runs. Override with
	// BLOBLY_AUTOSTART_FRAME.
	autostart_frame := if os.getenv('BLOBLY_AUTOSTART') != '' {
		n := os.getenv('BLOBLY_AUTOSTART_FRAME').int()
		if n > 0 {
			n
		} else {
			30
		}
	} else {
		0
	}
	// BLOBLY_FOCUS=PanelName brings that panel's tab to the front once at startup (test/dev aid).
	focus_panel := os.getenv('BLOBLY_FOCUS')

	mut frame := 0
	for vgui.running() {
		frame++
		// During the autostart settle window, wake the loop so those frames render back-to-back
		// (the event-driven wait would otherwise pace them ~0.5s apart before any RX thread exists).
		if autostart_frame > 0 && frame < autostart_frame {
			vgui.wake()
		}
		if autostart_frame > 0 && frame == autostart_frame {
			app.start()
		}
		last := max_frames > 0 && frame >= max_frames
		if last && shot != '' {
			vgui.dump_ppm(shot)
		}

		app.mu.lock()
		rx := app.rx
		txs := app.tx_counts_locked()
		rows := app.trace.clone()
		gcount := app.gcount.clone()
		trecs := app.trecs.clone()
		chans := app.chans.clone()
		app.mu.unlock()

		vgui.frame_begin()
		if focus_panel != '' && frame == 3 {
			vgui.set_window_focus(focus_panel)
		}
		draw_menubar(mut app, rx)
		// activity bar spans the full height on the far left (VS Code style); the toolbar
		// and dockspace live in a right-hand pane beside it (not above it).
		draw_activity_bar(mut app)
		vgui.same_line()
		vgui.child_fill('##right')
		draw_toolbar(mut app, rx, txs, chans)
		vgui.dockspace()
		vgui.child_end()
		build_layout()
		app.poll_hotkeys()
		app.cfg_file_visible = false // the File tab sets it when it draws, below

		if app.show_buses {
			draw_buses(mut app, chans)
		}
		if app.show_sim {
			draw_sim(mut app)
		}
		if app.show_symbols {
			draw_symbols(mut app)
		}
		if app.show_stats {
			draw_stats(mut app, chans, rx, txs)
		}
		if app.show_trace {
			draw_trace(mut app, rows, gcount, rx)
		}
		if app.show_ftrace {
			draw_ftrace(mut app, rows, gcount)
		}
		if app.show_log {
			draw_log(mut app)
		}
		if app.show_replay {
			draw_replay(mut app)
		}
		if app.show_tchart {
			draw_tchart(mut app, trecs)
		}
		if app.show_signals {
			draw_signals(mut app, rows)
		}
		if app.show_graphics {
			draw_graphics(mut app, rows)
		}
		if app.show_diag {
			draw_diag(mut app)
		}
		if app.show_shell {
			draw_shell(mut app)
		}
		if app.show_dbc {
			draw_dbc_editor(mut app)
		}
		if app.show_sys {
			draw_system(mut app)
		}
		if app.show_flash {
			draw_flash(mut app)
		}
		if app.show_doip {
			draw_doip(mut app)
		}
		if app.show_network {
			draw_network(mut app, chans)
		}
		if app.show_gen {
			draw_gen(mut app)
		}
		if app.show_script {
			draw_script(mut app)
		}
		if app.show_config {
			draw_config(mut app)
		}
		if app.disc_open {
			draw_discover_dialog(mut app)
		}
		if app.fb_open {
			draw_filebrowser(mut app)
		}
		// AFTER the panels: draw_gen is where a generator's name and key buffers are copied into
		// the sender, so a Ctrl+S polled before it saved the previous value and then read clean
		// — the last edit lost on reopen with nothing on screen to say so (codex round 3 on
		// #250). Polled here, what is saved is what is shown.
		app.poll_shortcuts()

		vgui.frame_end()
		if last {
			eprintln('rendered ${frame} frames; RX ${rx}')
			break
		}
	}
	app.stop()
	vgui.shutdown()
}
