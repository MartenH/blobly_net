module prefs

import toml

// WHAT THE APP REMEMBERS ACROSS RUNS — as opposed to what a project says (a .blobnet) and what
// a run measures. Three things today (#306): the external editor, the UI scale, which the
// Settings menu set and the next start forgot, and the dragged dividers. A GUI-free module in
// the shape ../saverule set, so the file's grammar and the editor command's are tested where
// the GUI cannot be.
//
// The file is SHARED: by every checkout and bundle of this user, and by every build they run.
// One rule follows, and it is here rather than in the GUI — a file carrying keys this build does
// not know (`foreign`) is never rewritten by an automatic save: five review rounds went into a
// textual scan that preserved such keys through a rewrite, each round a TOML form the scan
// misread (quoted keys, quoted headers, dotted keys, multi-line strings, delimiters in
// comments), which is the signal to stop scanning. The Preferences dialog's Save is the one
// writer that may replace such a file, and it says what it drops.
//
// Between two INSTANCES of one user, last writer wins (#309): a save writes the whole file from
// what that instance holds. It is the policy ImGui's layout file beside it has always had
// (#308), and the field-by-field merge under a lock that settings.toml had instead cost 310
// lines for three preferences.

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
	// finds. Written at exit, since a drag is many frames and the file is one write — the
	// session's own drags folded over the ones it loaded, so a pane nobody touched keeps what
	// the file said (main.v).
	panes map[string]f32
	// The file names keys or tables this build does not read — a newer build's — and so must
	// not be rewritten by an automatic save. Set by parse, from the parsed document.
	foreign []string
}

// parse reads the settings file's text. A scale outside what the Settings menu offers is
// clamped, since a file saying 0 would hide the whole UI. Keys this build does not know are
// listed in `foreign` — from the parsed document, so a quoted, dotted or multi-line spelling is
// whatever TOML says it is.
pub fn parse(text string) !Prefs {
	doc := toml.parse_text(text)!
	mut p := Prefs{}
	// A known key of a type this build cannot read (`ui_scale = "system"`, a newer build's) is
	// foreign like an unknown key: not read, and not rewritten automatically (codex #307 r15).
	if v := doc.value_opt('editor') {
		if v is string {
			p.editor = v
		} else {
			p.foreign << 'editor'
		}
	}
	if v := doc.value_opt('ui_scale') {
		if v is f64 || v is i64 || v is int || v is u64 {
			p.ui_scale = clamp_scale(f32(v.f64()))
		} else {
			p.foreign << 'ui_scale'
		}
	}
	if v := doc.value_opt('panes') {
		if v is map[string]toml.Any {
			for k, x in v {
				// a pane is a number; anything else under [panes] is a newer build's and
				// foreign, like an unknown top-level key (codex #307 r14)
				if x is f64 || x is i64 || x is int || x is u64 {
					h := f32(x.f64())
					if h > 0 {
						p.panes[k] = h
					}
				} else {
					p.foreign << 'panes.' + k
				}
			}
		} else {
			p.foreign << 'panes' // `panes = "auto"`: a newer build's, foreign like the rest (r16)
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
// either side for a hand-edited file — never 0, which a missing value reads as through f64, and
// never NaN, which TOML can spell.
pub fn clamp_scale(s f32) f32 {
	if s != s {
		return 1.0 // NaN, which a hand-edited file may say and no comparison catches (codex #307 r9)
	}
	if s < 0.5 {
		return 0.5
	}
	if s > 3.0 {
		return 3.0
	}
	return s
}

// keep_panes folds this session's dragged panes over the ones the file had: a pane it never
// touched keeps whatever the last session that DID drag it left, and a pane merely shown at its
// seeded default is not a drag and so is not in `dragged` at all (panerule, codex #307 r9, r10).
// The caller decides which of its live values were dragged; this decides what the file keeps.
pub fn (mut p Prefs) keep_panes(dragged map[string]f32) {
	for k, v in dragged {
		p.panes[k] = v
	}
}

// serialize is the file's text: one line per key, a TOML basic string for the editor (a
// Windows path carries backslashes, which the basic string escapes — by hand, because vlib's
// toml.encode quotes a string without escaping anything), then the dragged panes. What the
// build does not know is not here: see `foreign`.
pub fn (p Prefs) serialize() string {
	// the scale as it is, not rounded to two places: an unchanged 1.125 must come back 1.125
	// through an unrelated save (codex #307 r23)
	mut out := 'editor = "${toml_escape(p.editor)}"\nui_scale = ${p.ui_scale}\n'
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

// toml_escape spells `s` inside a basic string: backslash and quote escaped, and every control
// character too — a hand-edited `"foo\nbar"` parses to a real newline, which written back raw
// splits the line and breaks the file (codex #307 r10).
fn toml_escape(s string) string {
	mut out := ''
	for c in s {
		match c {
			`\\` {
				out += '\\\\'
			}
			`"` {
				out += '\\"'
			}
			`\n` {
				out += '\\n'
			}
			`\r` {
				out += '\\r'
			}
			`\t` {
				out += '\\t'
			}
			8 {
				out += '\\b'
			}
			12 {
				out += '\\f'
			}
			else {
				if c < 0x20 || c == 0x7f {
					out += '\\u00' + c.hex().to_upper()
				} else {
					out += c.ascii_str()
				}
			}
		}
	}
	return out
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
