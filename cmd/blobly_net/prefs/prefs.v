module prefs

import toml

// WHAT THE APP REMEMBERS ACROSS RUNS — as opposed to what a project says (a .blobnet) and what
// a run measures. Three things today (#306): the external editor, the UI scale, which the
// Settings menu set and the next start forgot, and the dragged dividers. A GUI-free module in
// the shape ../saverule set, so the file's grammar and the editor command's are tested where
// the GUI cannot be.
//
// The file is SHARED: by every checkout and bundle of this user, and by every build they run.
// Two rules follow, and both are here rather than in the GUI. A file carrying keys this build
// does not know (`foreign`) is never rewritten by an automatic save — five review rounds went
// into a textual scan that preserved such keys through a rewrite, each round a TOML form the
// scan misread (quoted keys, quoted headers, dotted keys, multi-line strings, delimiters in
// comments), which is the signal to stop scanning: the Preferences dialog's Save is the one
// writer that may replace such a file, and it says what it drops. And a save MERGES: the file
// is read again and only the fields THIS instance changed are written over it, so a second
// instance closing later does not put back the scale the first one had just changed.

// Prefs is the settings file, as values. A field's zero value is the default, so a file that
// names neither key is the same as no file.
pub struct Prefs {
pub mut:
	// The command that opens a file for editing. '' means the system's own "open" (what a
	// double click in a file manager does). `%s` stands for the file; with no `%s` the file
	// is appended as the last argument. Quoted with double quotes where a path has a space.
	editor   string
	ui_scale f32 = 1.0
	// Dragged dividers, by pane name, unscaled px (panerule): what a session set, the next
	// finds. Written at exit, since a drag is many frames and the file is one write.
	panes map[string]f32
	// The file names keys or tables this build does not read — a newer build's — and so must
	// not be rewritten by an automatic save. Set by parse, from the parsed document.
	foreign []string
}

// Changed says which fields a save may write: the ones this instance changed. Anything else
// stays as the file has it now, whoever wrote that.
pub struct Changed {
pub:
	editor bool
	scale  bool
	panes  bool
}

// plus is both sets of changes: what a refused save left pending, and what is asked now.
pub fn (a Changed) plus(b Changed) Changed {
	return Changed{
		editor: a.editor || b.editor
		scale:  a.scale || b.scale
		panes:  a.panes || b.panes
	}
}

// parse reads the settings file's text. A scale outside what the Settings menu offers is
// clamped, since a file saying 0 would hide the whole UI. Keys this build does not know are
// listed in `foreign` — from the parsed document, so a quoted, dotted or multi-line spelling is
// whatever TOML says it is.
pub fn parse(text string) !Prefs {
	doc := toml.parse_text(text)!
	mut p := Prefs{}
	if v := doc.value_opt('editor') {
		p.editor = v.string()
	}
	if v := doc.value_opt('ui_scale') {
		p.ui_scale = clamp_scale(f32(v.f64()))
	}
	if v := doc.value_opt('panes') {
		for k, x in v.as_map() {
			h := f32(x.f64())
			if h > 0 {
				p.panes[k] = h
			}
		}
	}
	for k, _ in doc.to_any().as_map() {
		if k !in ['editor', 'ui_scale', 'panes'] {
			p.foreign << k
		}
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

// merge is what a save writes: `base` (the file as it is now) with the fields `ch` names taken
// from `mine`. A file that is not there is the defaults, so `base` may be Prefs{}.
pub fn merge(base Prefs, mine Prefs, ch Changed) Prefs {
	mut out := base
	if ch.editor {
		out.editor = mine.editor
	}
	if ch.scale {
		out.ui_scale = mine.ui_scale
	}
	if ch.panes {
		out.panes = mine.panes.clone()
	}
	return out
}

// serialize is the file's text: one line per key, a TOML basic string for the editor (a
// Windows path carries backslashes, which the basic string escapes — by hand, because vlib's
// toml.encode quotes a string without escaping anything), then the dragged panes. What the
// build does not know is not here: see `foreign`.
pub fn (p Prefs) serialize() string {
	mut out := 'editor = "${toml_escape(p.editor)}"\nui_scale = ${p.ui_scale:.2f}\n'
	if p.panes.len > 0 {
		out += '\n[panes]\n'
		mut keys := p.panes.keys()
		keys.sort()
		for k in keys {
			out += '${toml_key(k)} = ${p.panes[k]:.1f}\n'
		}
	}
	return out
}

// toml_key spells a map key as a TOML key: bare when it is one (letters, digits, `_`, `-`),
// quoted otherwise — a pane named with a space is still a valid file.
fn toml_key(k string) string {
	mut bare := k.len > 0
	for c in k {
		if !((c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
			|| (c >= `0` && c <= `9`) || c == `_` || c == `-`) {
			bare = false
			break
		}
	}
	return if bare { k } else { '"' + toml_escape(k) + '"' }
}

fn toml_escape(s string) string {
	return s.replace('\\', '\\\\').replace('"', '\\"')
}

// editor_argv is the argv that opens `path` with the editor command `cmd`: the command split
// on whitespace with double quotes grouping (`"C:\Program Files\X\x.exe" -g %s`), every `%s`
// replaced by the path — inside a token too, so `"%s"` (quoted, as a shell tutorial would) and
// `--file=%s` both work — and the path appended when the command names none. Quotes only
// group; they add nothing to the argv, and an empty quoted token is dropped. An empty command
// yields an empty argv — the caller's cue to use the system's own open.
pub fn editor_argv(cmd string, path string) []string {
	mut out := []string{}
	mut cur := ''
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
			continue
		}
		if c == ` ` || c == `\t` {
			if cur != '' {
				out << cur
				cur = ''
			}
			continue
		}
		cur += c.ascii_str()
	}
	if cur != '' {
		out << cur
	}
	if out.len == 0 {
		return out
	}
	mut named := false
	for i, a in out {
		if a.contains('%s') {
			out[i] = a.replace('%s', path)
			named = true
		}
	}
	if !named {
		out << path
	}
	return out
}
