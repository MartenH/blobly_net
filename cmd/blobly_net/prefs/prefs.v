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
	// Dragged dividers, by pane name, unscaled px (panerule): what a session set, the next
	// finds. Written at exit, since a drag is many frames and the file is one write.
	panes map[string]f32
	// What this build does not know, kept as the lines it came in — a newer build's keys and
	// tables — so an older build's exit does not erase them from the shared file (codex #307
	// r2). Written back after the known keys.
	unknown []string
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
	if v := doc.value_opt('panes') {
		for k, x in v.as_map() {
			h := f32(x.f64())
			if h > 0 {
				p.panes[k] = h
			}
		}
	}
	p.unknown = unknown_lines(text)
	return p
}

// unknown_lines is every line of the file this build does not read: a top-level `key = …`
// whose key is not one of ours, and every table but [panes] with its lines. Kept verbatim —
// the value's own grammar is not parsed back — and re-emitted by serialize, so a newer build's
// settings survive an older build's save. Blank lines and comments go with the section they
// are in; ours are dropped, since serialize rewrites those sections.
fn unknown_lines(text string) []string {
	known := ['editor', 'ui_scale']
	mut out := []string{}
	mut in_ours := true // the top level, until a table header
	mut keep_table := false
	for raw in text.split_into_lines() {
		line := raw.trim_space()
		if line.starts_with('[') {
			// the parsed identity: `["panes"]` is [panes] (codex #307 r4)
			name := line.all_after('[').all_before(']').trim_space().trim('"\'')
			keep_table = name != 'panes'
			in_ours = false
			if keep_table {
				out << raw
			}
			continue
		}
		if in_ours {
			if line == '' || line.starts_with('#') {
				continue
			}
			// the parsed identity, not the raw spelling: `"editor" = …` is editor (codex #307 r3)
			key := line.all_before('=').trim_space().trim('"\'')
			if key !in known {
				out << raw
			}
			continue
		}
		if keep_table {
			out << raw
		}
	}
	return out
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
// Windows path carries backslashes, which the basic string escapes — by hand, because vlib's
// toml.encode quotes a string without escaping anything), then the dragged panes.
pub fn (p Prefs) serialize() string {
	mut out := 'editor = "${toml_escape(p.editor)}"\nui_scale = ${p.ui_scale:.2f}\n'
	// Unknown TOP-LEVEL lines go before any table, or they would land inside [panes]; unknown
	// tables go after it. The list is in file order, and a top-level line cannot follow a header.
	mut first_table := p.unknown.len
	for i, l in p.unknown {
		if l.trim_space().starts_with('[') {
			first_table = i
			break
		}
	}
	for l in p.unknown[..first_table] {
		out += l + '\n'
	}
	if p.panes.len > 0 {
		out += '\n[panes]\n'
		mut keys := p.panes.keys()
		keys.sort()
		for k in keys {
			out += '${toml_key(k)} = ${p.panes[k]:.1f}\n'
		}
	}
	if first_table < p.unknown.len {
		out += '\n' + p.unknown[first_table..].join('\n') + '\n'
	}
	return out
}

// toml_key spells a map key as a TOML key: bare when it is one (letters, digits, `_`, `-`),
// quoted otherwise — a pane a newer build names with a space is still a valid file after this
// build rewrites it (codex #307 r4).
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
