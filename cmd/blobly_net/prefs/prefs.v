module prefs

import toml

// WHAT THE APP REMEMBERS ACROSS RUNS — as opposed to what a project says (a .blobnet) and what
// a run measures. Two things today (#306): the external editor, and the UI scale, which the
// Settings menu set and the next start forgot. A GUI-free module in the shape ../saverule set,
// so the file's grammar and the editor command's are tested where the GUI cannot be.

// Prefs is the settings file, as values. A field's zero value is the default, so a file that
// names neither key is the same as no file.
pub struct Prefs {
pub mut:
	// The command that opens a file for editing. '' means the system's own "open" (what a
	// double click in a file manager does). `%s` stands for the file; with no `%s` the file
	// is appended as the last argument. Quoted with double quotes where a path has a space.
	editor   string
	ui_scale f32 = 1.0
}

// parse reads the settings file's text. Unknown keys are ignored (a newer build's file opens
// in an older one); a scale outside what the Settings menu offers is clamped, since a file
// saying 0 would hide the whole UI.
pub fn parse(text string) !Prefs {
	doc := toml.parse_text(text)!
	mut p := Prefs{}
	if v := doc.value_opt('editor') {
		p.editor = v.string()
	}
	if v := doc.value_opt('ui_scale') {
		p.ui_scale = clamp_scale(f32(v.f64()))
	}
	return p
}

// clamp_scale keeps a UI scale inside the range the Settings menu offers (75%..175%), with room
// either side for a hand-edited file — and never 0, which a missing value reads as through f64.
pub fn clamp_scale(s f32) f32 {
	if s < 0.5 {
		return 0.5
	}
	if s > 3.0 {
		return 3.0
	}
	return s
}

// serialize is the file's text: one line per key, a TOML basic string for the editor (a
// Windows path carries backslashes, which the basic string escapes).
pub fn (p Prefs) serialize() string {
	return 'editor = "${toml_escape(p.editor)}"\nui_scale = ${p.ui_scale:.2f}\n'
}

fn toml_escape(s string) string {
	return s.replace('\\', '\\\\').replace('"', '\\"')
}

// editor_argv is the argv that opens `path` with the editor command `cmd`: the command split
// on whitespace with double quotes grouping (`"C:\Program Files\X\x.exe" -g %s`), every `%s`
// token replaced by the path, and the path appended when the command names none. An empty
// command yields an empty argv — the caller's cue to use the system's own open.
pub fn editor_argv(cmd string, path string) []string {
	mut out := []string{}
	mut cur := ''
	mut in_word := false
	mut quoted := false
	for c in cmd {
		if quoted {
			if c == `"` {
				quoted = false
			} else {
				cur += c.ascii_str()
			}
			continue
		}
		if c == `"` {
			quoted = true
			in_word = true
			continue
		}
		if c == ` ` || c == `\t` {
			if in_word {
				out << cur
				cur = ''
				in_word = false
			}
			continue
		}
		cur += c.ascii_str()
		in_word = true
	}
	if in_word {
		out << cur
	}
	if out.len == 0 {
		return out
	}
	mut named := false
	for i, a in out {
		if a == '%s' {
			out[i] = path
			named = true
		}
	}
	if !named {
		out << path
	}
	return out
}
