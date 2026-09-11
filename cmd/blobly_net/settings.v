module main

import os
import prefs
import panerule
import vgui

// prefs_path is where the settings live: the user's config directory, so every project and
// every checkout shares one file (%AppData%\blobly_net\settings.toml on Windows,
// ~/.config/blobly_net/settings.toml on Linux).
fn prefs_path() string {
	dir := os.config_dir() or { os.home_dir() }
	return os.join_path(dir, 'blobly_net', 'settings.toml')
}

// load_prefs reads the file at startup. No file is the defaults; a broken one is logged, the
// defaults stand — a settings file must never keep the app from starting — and it is REMEMBERED
// as broken, so an automatic save does not overwrite the hand-edited file with the defaults;
// the Preferences dialog's Save is the one that may. A file that is there but cannot be read is
// broken too, not absent (codex #307 r5). A file that parses but carries keys this build does
// not know (prefs.Prefs.foreign) is protected the same way, and the dialog says what its Save
// would drop. This verdict is the STARTUP one, for the Log; an automatic save classifies the
// file again for itself (reclassify_prefs_file), since both conditions can arrive later.
fn (mut app App) load_prefs() {
	app.prefs_file = prefs_path()
	txt := os.read_file(app.prefs_file) or {
		if os.exists(app.prefs_file) {
			app.elog('settings: ${app.prefs_file}: ${err.msg()} — using defaults; not overwritten')
			app.prefs_broken = true
		}
		return
	}
	app.prefs = prefs.parse(txt) or {
		app.elog('settings: ${app.prefs_file}: ${err.msg()} — using defaults; fix or delete the file, or Save from Settings ▸ Preferences… to replace it')
		app.prefs_broken = true
		return
	}
	if app.prefs.foreign.len > 0 {
		app.elog('settings: ${app.prefs_file} carries settings this build does not know (${app.prefs.foreign.join(', ')}); it is not rewritten automatically')
	}
}

// save_prefs writes the whole file from what this instance holds: last writer wins, which is
// the policy ImGui's layout file beside it has always had (#308). The coordination that a
// read-merge-write under a lock directory bought cost 310 lines for three preferences, and what
// it protected against is two instances of one user changing a setting in the same window —
// while the dock layout, the larger loss of the two, was decided that way from the start (#309).
//
// Integrity is a different question and stays: written beside and moved into place, so a write
// that fails part-way (a full disk) does not leave the file it was replacing truncated (codex
// #307 r11). The move is replace_file, which on Windows is MoveFileEx with REPLACE_EXISTING —
// _wrename refuses an existing target.
//
// Refused, unless from the dialog, for a file that does not parse, cannot be read, or carries
// keys this build does not know (prefs.Prefs.foreign) — classified from the file AS IT IS, not
// from the load's verdict: a newer build can write its key, and an operator can be halfway
// through editing the file by hand, long after this instance started. The dialog's Save is the
// one writer that may replace such a file, and it says what it drops. A failure to write is
// said, not fatal; the return says whether the file was written.
fn (mut app App) save_prefs(from_dialog bool) bool {
	if !from_dialog && app.reclassify_prefs_file() {
		return false
	}
	app.collect_panes()
	// The directory first: on a fresh profile there is none yet (codex #307 r8).
	os.mkdir_all(os.dir(app.prefs_file)) or {
		app.notify('settings not saved: cannot create ${os.dir(app.prefs_file)} (${err.msg()})')
		return false
	}
	// A temp name THIS process owns. The lock that serialised writers is gone, so a shared
	// `<file>.tmp` would let two instances interleave into one temp — or let one rename it into
	// place while the other is still writing it, which is the truncated file the temp exists to
	// prevent — and the failure path below would delete the other's. Last writer wins is a lost
	// FIELD, never a corrupt file. A crash BETWEEN the write and the rename leaves one such
	// file behind; that is not swept, deliberately — scanning the config directory to tidy
	// after other processes is how the version this replaces reached 310 lines.
	tmp := '${app.prefs_file}.${os.getpid()}.tmp'
	os.write_file(tmp, app.prefs.serialize()) or {
		app.notify('settings not saved (${tmp}): ${err.msg()}')
		return false
	}
	replace_file(tmp, app.prefs_file) or {
		os.rm(tmp) or {}
		app.notify('settings not saved (${app.prefs_file}): ${err.msg()}')
		return false
	}
	// Whatever the file held is gone now: it is this instance's.
	app.prefs_broken = false
	app.prefs.foreign = []
	app.prefs_dirty = false
	return true
}

// pane_moved is the one caller shape for a persisted divider's splitter result: the stored
// value after the drag, and the DRAG recorded by pane name — what the exit save writes is the
// panes this instance dragged, not the ones it merely showed at their seeded default (codex
// #307 r10).
fn (mut app App) pane_moved(key string, stored f32, drawn_px f32, moved f32, sc f32) f32 {
	v, was_drag := panerule.dragged(stored, drawn_px, moved, sc)
	if was_drag {
		app.panes_dragged[key] = true
		app.prefs_dirty = true
	}
	return v
}

// reclassify_prefs_file re-reads the file and says whether an AUTOMATIC save must leave it
// alone. It is a read, not the read-merge-write this replaced (#309): it decides refuse or
// proceed and nothing else, so it needs no lock — a file that changes in the moment after it is
// classified is the lost field last-writer-wins already accepts. What it protects is CONTENT,
// which is a different question: a newer build's settings, and a hand edit in progress. It also
// clears a startup verdict the operator has since repaired (codex #307 r26), and refreshes what
// the dialog warns about.
fn (mut app App) reclassify_prefs_file() bool {
	txt := os.read_file(app.prefs_file) or {
		// absent is not protected — a save creates it; unreadable is, like unparseable
		app.prefs_broken = os.exists(app.prefs_file)
		return app.prefs_broken
	}
	now := prefs.parse(txt) or {
		app.prefs_broken = true
		return true
	}
	app.prefs_broken = false
	app.prefs.foreign = now.foreign.clone()
	return now.foreign.len > 0
}

// save_layout writes ImGui's layout file, which the APP owns rather than ImGui (#308): with
// ImGui's own writer disabled (vgui.set_ini_path) nothing else opens the file, so it goes out
// through the same temp-and-rename settings.toml uses and a half-written layout can never be
// what the next start reads — ImGui answers an unreadable one by falling back to the default
// layout, silently, which is the failure this closes. `force` is the exit save: ImGui raises its
// flag at most every 5 s, so a change in the last seconds of a run has not asked yet.
//
// Coordination is NOT bought back. Two instances of one user still race and the last writer
// still wins, as for settings.toml (#309) — a lost LAYOUT, never a corrupt file.
fn (mut app App) save_layout(force bool) {
	if app.layout_file == '' || !(force || vgui.ini_dirty()) {
		return
	}
	data := vgui.ini_data()
	// cleared whatever happens below: a disk that refuses must raise one warning, not one every
	// settling period for the rest of the run
	vgui.ini_saved()
	tmp := '${app.layout_file}.${os.getpid()}.tmp'
	os.write_file(tmp, data) or {
		app.warn_layout('${tmp}: ${err.msg()}')
		return
	}
	replace_file(tmp, app.layout_file) or {
		os.rm(tmp) or {}
		app.warn_layout('${app.layout_file}: ${err.msg()}')
	}
}

// warn_layout says a layout write failed, ONCE per run — through notify, which is the Log the
// operator can actually SEE: a warning about a silent loss that reaches only stderr and the
// session file is itself a silent loss, and save_prefs says the same class of failure the same
// way. Once, because the flag settles every few seconds: a config directory that is full or
// read-only would otherwise put a line in the Log every settling period for the rest of the run,
// and the first says everything the later ones would.
fn (mut app App) warn_layout(what string) {
	if app.layout_warned {
		return
	}
	app.layout_warned = true
	app.notify('layout not saved (${what}) — the window arrangement will not carry to the next start')
}

// collect_panes folds what THIS session dragged over the panes it loaded, into what a save
// writes. Every save, not just the exit one: a drag followed by a scale change used to leave
// the divider unwritten, because the successful mid-session save cleared what the exit save
// asks about. A pane merely shown at its seeded default is not a drag (pane_moved) and must not
// bake today's default into the file; one this session never touched keeps whatever the file
// said (codex #307 r9, r10).
fn (mut app App) collect_panes() {
	live := {
		'system_ecu':    app.sys_ecu_h
		'discover_list': app.disc_list_h
		'script_editor': app.script_ed_h
		'dbc_left':      app.dbc_ed.left_w
		'dbc_msgs':      app.dbc_ed.msgs_h
		'dbc_props':     app.dbc_ed.props_h
	}
	mut dragged := map[string]f32{}
	for k, v in live {
		if v > 0 && (app.panes_dragged[k] or { false }) {
			dragged[k] = v
		}
	}
	app.prefs.keep_panes(dragged)
}

// apply_ui_scale is the ONE writer of the scale: the value the panels read and the font scale
// move together, and the preference is what the next start reads.
fn (mut app App) apply_ui_scale(s f32) {
	app.prefs.ui_scale = prefs.clamp_scale(s)
	vgui.set_font_scale(app.prefs.ui_scale)
}

// open_in_editor opens `path` with the configured editor, or with the system's own "open" when
// none is configured — DETACHED either way (open_windows.v / open_nix.v): the GUI never waits
// for an editor, and a command that cannot start is a notification, not an exit.
fn (mut app App) open_in_editor(path string) {
	if path == '' {
		app.notify('nothing to open yet')
		return
	}
	a := app
	report := fn [a] (s string) {
		mut ap := unsafe { a }
		ap.notify(s)
	}
	argv := prefs.editor_argv(app.prefs.editor, path)
	if argv.len == 0 {
		ok, note := system_open(path, report)
		app.notify(if ok { note } else { note })
		return
	}
	// A Windows editor reached through WSL interop (`notepad++.exe %s`) cannot read a Linux
	// path: the file argument goes through wslpath, as the explorer.exe route does (r26).
	mut args := argv.clone()
	if argv[0].to_lower().ends_with('.exe') {
		if win := wsl_windows_path(path) {
			for i, arg in args {
				if arg.contains(path) {
					args[i] = arg.replace(path, win)
				}
			}
		}
	}
	launch_detached(args, report) or {
		app.notify('editor: ${err.msg()}')
		return
	}
	app.notify('opened ${path} in ${argv[0]}')
}

// open_prefs seeds the dialog's field from the preference and shows it.
fn (mut app App) open_prefs() {
	if app.show_prefs {
		return
	}
	// room for the command it holds plus editing, not a fixed size that a long one is cut to
	// and then saved back cut (codex #307 r3)
	cap := if app.prefs.editor.len * 2 > 256 { app.prefs.editor.len * 2 } else { 256 }
	app.prefs_editor_buf = mkbuf(app.prefs.editor, cap)
	app.prefs_caption = 'UI scale ${int(app.prefs.ui_scale * 100 + 0.5)}% (Settings menu) · file: ${app.prefs_file}'
	// the warning below the field is about the file the operator is about to replace, so it is
	// classified when the dialog OPENS rather than carried from startup
	app.reclassify_prefs_file()
	app.show_prefs = true
}

// draw_prefs is Settings ▸ Preferences…: the editor command, and what the file holds.
fn draw_prefs(mut app App) {
	vgui.set_next_window(300, 200, 560, 200)
	vis, op := vgui.begin_dialog('Preferences', app.show_prefs)
	app.show_prefs = op
	if !vis {
		vgui.end()
		return
	}
	vgui.text('Editor command')
	vgui.same_line()
	vgui.help_marker('What "Open in editor" runs. %s is the file (inside quotes or a longer argument too); without it the file is appended. Quote a path with a space. Empty = the system\'s own open, as a double click in a file manager. Examples: code -g %s · gvim %s · "C:\\Program Files\\Notepad++\\notepad++.exe" %s')
	vgui.set_next_item_width(vgui.content_avail_w())
	vgui.input_text('##prefs_editor', mut app.prefs_editor_buf)
	vgui.text_dim(if app.prefs.editor == '' {
		'now: the system open'
	} else {
		'now: ' + app.prefs.editor
	})
	vgui.text_dim(app.prefs_caption)
	if app.prefs_broken {
		vgui.text_colored(230, 120, 120,
			'the file could not be read (see the Log); Save here replaces it with what this session holds')
	} else if app.prefs.foreign.len > 0 {
		vgui.text_colored(230, 170, 70,
			'the file carries settings this build does not know (${app.prefs.foreign.join(', ')}); Save here drops them')
	}
	vgui.separator()
	if vgui.button('Save') {
		app.prefs.editor = vgui.buf_str(app.prefs_editor_buf).trim_space()
		// owed before it is attempted, so a save that fails to WRITE is retried at exit rather
		// than losing the command the operator typed. A file that is broken or foreign is not
		// retried — only the dialog may replace one, and the exit save refuses above — so that
		// failure is the notify below and nothing more, as it was before the lock came out.
		app.prefs_dirty = true
		if app.save_prefs(true) {
			app.notify('preferences saved')
		}
	}
	vgui.same_line()
	if vgui.button('Close') {
		app.show_prefs = false
	}
	vgui.end()
}
