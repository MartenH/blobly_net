module main

import os
import time
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
// would drop.
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

// save_prefs writes the fields `ch` names — the ones this instance changed — over the file AS
// IT IS NOW (read again, merged, under the lock below), so a second instance closing later
// does not put back what the first one changed (codex #307 r6). Refused, unless from the
// dialog, for a file that will not parse, cannot be read, or carries keys this build does not
// know: the dialog's Save replaces such a file whole, and says so. A refused or failed save
// keeps its flags PENDING, so the scale picked while the file was foreign is still in the
// dialog's Save later (r7). A failure to write is said, not fatal; the return says whether the
// file was written.
fn (mut app App) save_prefs(ch prefs.Changed, from_dialog bool) bool {
	want := app.prefs_pending.plus(ch)
	app.prefs_pending = want
	if app.prefs_broken && !from_dialog {
		return false
	}
	// The directory first: the lock is a directory INSIDE it, and on a fresh profile every
	// save was refused as if another instance held a lock nothing could create (codex #307 r8).
	os.mkdir_all(os.dir(app.prefs_file)) or {}
	if !prefs_lock(app.prefs_file) {
		app.notify('settings not saved: another instance holds ${app.prefs_file}.lock')
		return false
	}
	defer {
		prefs_unlock(app.prefs_file)
	}
	mut base := prefs.Prefs{}
	if txt := os.read_file(app.prefs_file) {
		if now := prefs.parse(txt) {
			if now.foreign.len > 0 {
				// Discovered at save — added by a newer instance or by hand since start: kept, so
				// the dialog can say what its Save would drop (codex #307 r8).
				app.prefs.foreign = now.foreign
				if !from_dialog {
					return false
				}
			}
			base = now
		} else {
			// Broken since start: recorded, so the dialog warns before its Save replaces it
			// (codex #307 r9).
			app.prefs_broken = true
			if !from_dialog {
				return false
			}
		}
	} else if os.exists(app.prefs_file) {
		app.prefs_broken = true
		if !from_dialog {
			return false
		}
	}
	merged := prefs.merge(base, app.prefs, want)
	os.write_file(app.prefs_file, merged.serialize()) or {
		app.notify('settings not saved (${app.prefs_file}): ${err.msg()}')
		return false
	}
	app.prefs_broken = false
	app.prefs.foreign = []
	app.prefs_pending = prefs.Changed{}
	return true
}

// prefs_lock takes `<file>.lock`, a directory, which mkdir creates for ONE caller — the shape
// cmd/arxml2dbc publishes under. It serialises the read-merge-write across instances: two
// saving at once could each read the same snapshot and the second write drop the first's
// field (codex #307 r7). A lock older than ten seconds is a crashed holder's, and is taken.
fn prefs_lock(file string) bool {
	dir := file + '.lock'
	for _ in 0 .. 50 {
		os.mkdir(dir) or {
			if os.exists(dir) {
				age := time.now().unix() - os.file_last_mod_unix(dir)
				if age > 10 {
					os.rmdir(dir) or {}
					continue
				}
			}
			time.sleep(20 * time.millisecond)
			continue
		}
		return true
	}
	return false
}

fn prefs_unlock(file string) {
	os.rmdir(file + '.lock') or {}
}

// pane_moved is the one caller shape for a persisted divider's splitter result: the stored
// value after the drag, and the DRAG recorded by pane name — what the exit save writes is the
// panes this instance dragged, not the ones it merely showed at their seeded default (codex
// #307 r10).
fn (mut app App) pane_moved(key string, stored f32, drawn_px f32, moved f32, sc f32) f32 {
	v, was_drag := panerule.dragged(stored, drawn_px, moved, sc)
	if was_drag {
		app.panes_dragged[key] = true
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
	launch_detached(argv, report) or {
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
			'the file could not be read (see the Log); Save here replaces it')
	} else if app.prefs.foreign.len > 0 {
		vgui.text_colored(230, 170, 70,
			'the file carries settings this build does not know (${app.prefs.foreign.join(', ')}); Save here drops them')
	}
	vgui.separator()
	if vgui.button('Save') {
		app.prefs.editor = vgui.buf_str(app.prefs_editor_buf).trim_space()
		if app.save_prefs(prefs.Changed{ editor: true }, true) {
			app.notify('preferences saved')
		}
	}
	vgui.same_line()
	if vgui.button('Close') {
		app.show_prefs = false
	}
	vgui.end()
}
