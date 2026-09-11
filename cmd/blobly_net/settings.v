module main

import os
import prefs
import vgui

// prefs_path is where the settings live: the user's config directory, so every project and
// every checkout shares one file (%AppData%\blobly_net\settings.toml on Windows,
// ~/.config/blobly_net/settings.toml on Linux).
fn prefs_path() string {
	dir := os.config_dir() or { os.home_dir() }
	return os.join_path(dir, 'blobly_net', 'settings.toml')
}

// load_prefs reads the file at startup. No file is the defaults; a broken one is logged and
// the defaults stand, since a settings file must never keep the app from starting.
fn (mut app App) load_prefs() {
	p := prefs_path()
	txt := os.read_file(p) or { return }
	app.prefs = prefs.parse(txt) or {
		app.elog('settings: ${p}: ${err.msg()} — using defaults')
		return
	}
}

// save_prefs writes the file. Called at every change (a scale picked, the editor set), so the
// next start finds it; a failure is said, not fatal.
fn (mut app App) save_prefs() {
	p := prefs_path()
	os.mkdir_all(os.dir(p)) or {}
	os.write_file(p, app.prefs.serialize()) or {
		app.notify('settings not saved (${p}): ${err.msg()}')
		return
	}
}

// open_in_editor opens `path` with the configured editor, or with the system's own "open" when
// none is configured — the same route Help takes to the browser, which knows about WSL.
// The editor runs DETACHED: the GUI does not wait for it.
fn (mut app App) open_in_editor(path string) {
	if path == '' {
		app.notify('nothing to open yet')
		return
	}
	argv := prefs.editor_argv(app.prefs.editor, path)
	if argv.len == 0 {
		ok, note := open_uri_in_browser(path)
		app.notify(if ok { 'opened ${path} with the system editor' } else { note })
		return
	}
	exe := os.find_abs_path_of_executable(argv[0]) or { argv[0] }
	mut proc := os.new_process(exe)
	proc.set_args(argv[1..])
	proc.run()
	if proc.err != '' {
		app.notify('editor: ${proc.err} — set the command in Settings ▸ Preferences…')
		return
	}
	app.notify('opened ${path} in ${argv[0]}')
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
	sc := app.ui_scale
	vgui.text('Editor command')
	vgui.same_line()
	vgui.help_marker('What "Open in editor" runs. %s is the file; without it the file is appended. Quote a path with a space. Empty = the system\'s own open, as a double click in a file manager. Examples: code -g %s · gvim %s · "C:\\Program Files\\Notepad++\\notepad++.exe" %s')
	vgui.set_next_item_width(vgui.content_avail_w())
	vgui.input_text('##prefs_editor', mut app.prefs_editor_buf)
	vgui.text_dim(if app.prefs.editor == '' {
		'now: the system open'
	} else {
		'now: ${app.prefs.editor}'
	})
	vgui.text_dim('UI scale ${int(app.prefs.ui_scale * 100 + 0.5)}% (Settings menu) · file: ${prefs_path()}')
	vgui.separator()
	if vgui.button('Save') {
		app.prefs.editor = vgui.buf_str(app.prefs_editor_buf).trim_space()
		app.save_prefs()
		app.notify('preferences saved')
	}
	vgui.same_line()
	if vgui.button('Close') {
		app.show_prefs = false
	}
	_ = sc
	vgui.end()
}
