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
// would drop. This verdict is the only one there is: a save does not read the file again.
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
// Refused, unless from the dialog, for a file that did not parse, could not be read, or carries
// keys this build does not know (prefs.Prefs.foreign) — the verdict the LOAD reached, since
// nothing re-reads the file now. The dialog's Save is the one writer that may replace such a
// file, and it says what it drops. A failure to write is said, not fatal; the return says
// whether the file was written.
fn (mut app App) save_prefs(from_dialog bool) bool {
	if !from_dialog && (app.prefs_broken || app.prefs.foreign.len > 0) {
		return false
	}
	// The directory first: on a fresh profile there is none yet (codex #307 r8).
	os.mkdir_all(os.dir(app.prefs_file)) or {
		app.notify('settings not saved: cannot create ${os.dir(app.prefs_file)} (${err.msg()})')
		return false
	}
	tmp := app.prefs_file + '.tmp'
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
		// owed before it is attempted, so a save that FAILS to write is retried at exit rather
		// than losing the command the operator typed
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
