module candb

import os
import yaml

// An ExtractEditor (E3) project file (`<name>.e3proj`, YAML) names the files one ECU extract is
// read from, so a project that is edited in E3 is read here as the same model E3 shows.
// The selection rules are E3's:
//   - `FileSelections.folders` are searched recursively for model sources; `files` are taken
//     as named; both are relative to the project file's folder. A symlink below a selected
//     folder is not followed.
//   - `unchecked` leaves an entry out and `checked` puts it back. A path's own entry decides
//     (checked first), else the nearest entry above it, else it is in.
//   - ARText sources (`.swcd`, `.artext`) are model sources to E3, which parses them; they
//     cannot be read here, so each is said and left out.
// `RootSelections.EcuInstance` names the ECU the extract is of (`E3Project.ecu`, its AUTOSAR path;
// `Arxml.ecu_names` is the name it goes by in the databases).

const e3_artext_suffixes = ['.swcd', '.artext']

// is_e3proj reports whether a path names an E3 project file.
pub fn is_e3proj(path string) bool {
	return path.to_lower().ends_with('.e3proj')
}

// E3Project is what an E3 project file selects.
pub struct E3Project {
pub:
	files   []string // the ARXML files, sorted by path
	folders []string // the selected folders that exist: where the files are searched for
	notes   []string // what was selected and cannot be read: ARText sources, paths that are gone
	ecu     string   // the AUTOSAR path of RootSelections.EcuInstance, '' where none is named
}

// load_e3proj reads an E3 project file and expands its selection.
pub fn load_e3proj(path string) !E3Project {
	text := os.read_file(path)!
	return parse_e3proj(text, os.dir(os.abs_path(path)))
}

// e3proj_ecu is the ECU an E3 project file's extract is of, without expanding its selection.
pub fn e3proj_ecu(path string) !string {
	return e3_ecu(e3_doc(os.read_file(path)!)!)
}

// parse_e3proj expands an E3 project file's text, its relative paths read from dir.
pub fn parse_e3proj(text string, dir0 string) !E3Project {
	// absolute, so the walk up to a path's nearest entry reaches an entry naming the base itself
	dir := os.abs_path(dir0)
	doc := e3_doc(text)!
	fs := doc.value_opt('FileSelections') or {
		return error('no FileSelections; not an E3 project file')
	}
	selected := e3_list(fs, 'folders', dir)!
	named := e3_list(fs, 'files', dir)!
	mut ticks := map[string]bool{}
	for p in e3_list(fs, 'checked', dir)! {
		ticks[e3_key(p)] = true
	}
	mut unticks := map[string]bool{}
	for p in e3_list(fs, 'unchecked', dir)! {
		unticks[e3_key(p)] = true
	}
	mut notes := []string{}
	mut seen := map[string]bool{}
	mut files := []string{}
	mut folders := []string{}
	mut sources := []string{}
	for f in selected {
		if !os.is_dir(f) {
			notes << '${f}: selected folder is not a folder; not read'
			continue
		}
		folders << f
		found, unreadable := e3_walk(f)
		sources << found
		notes << unreadable.map('${it}: folder cannot be listed; not read')
	}
	for f in named {
		if os.is_dir(f) {
			notes << '${f}: selected as a file but is a folder; not read'
		} else if !os.is_file(f) {
			notes << '${f}: selected file does not exist; not read'
		} else {
			sources << f
		}
	}
	for f in sources {
		if seen[f] || !e3_ticked(f, unticks, ticks) {
			continue
		}
		seen[f] = true
		low := f.to_lower()
		if low.ends_with('.arxml') {
			files << f
		} else if e3_artext_suffixes.any(low.ends_with(it)) {
			notes << '${f}: ARText source; not read'
		} else {
			notes << '${f}: not an ARXML file; not read'
		}
	}
	files.sort()
	notes.sort()
	return E3Project{
		files:   files
		folders: folders
		notes:   notes
		ecu:     e3_ecu(doc)
	}
}

fn e3_doc(text string) !yaml.Doc {
	return yaml.parse_text(indent_compact_sequences(text)) or { error('not YAML: ${err}') }
}

// e3_ecu is RootSelections.EcuInstance's path: a string, or the older `{path, ar_item}` mapping.
fn e3_ecu(doc yaml.Doc) string {
	roots := doc.value_opt('RootSelections') or { return '' }
	inst := roots.value_opt('EcuInstance') or { return '' }
	return match inst {
		string { inst }
		map[string]yaml.Any { (inst['ar_item'] or { yaml.Any('') }).string() }
		else { '' }
	}
}

// indent_compact_sequences indents a block sequence written at its key's own indentation (`k:`
// then `- v` beneath it at the same column, which PyYAML and so E3 write) by two spaces, since
// vlib's yaml reads only the indented form. Remove once .v-version is past vlang/v#31969.
fn indent_compact_sequences(text string) string {
	mut lines := text.split_into_lines()
	for i in 0 .. lines.len {
		// a key with nothing after it but, perhaps, a comment
		t := lines[i].all_before(' #').trim_space()
		if !t.ends_with(':') || t.starts_with('-') || t.starts_with('#') {
			continue
		}
		ind := e3_indent(lines[i])
		mut j := i + 1
		for j < lines.len && e3_ignorable(lines[j]) {
			j++
		}
		if j >= lines.len || e3_indent(lines[j]) != ind || !e3_item(lines[j]) {
			continue
		}
		for k in i + 1 .. lines.len {
			l := lines[k]
			if !e3_ignorable(l) && (e3_indent(l) < ind || (e3_indent(l) == ind && !e3_item(l))) {
				break
			}
			lines[k] = '  ' + l
		}
	}
	return lines.join('\n') + '\n'
}

fn e3_indent(l string) int {
	return l.len - l.trim_left(' ').len
}

fn e3_ignorable(l string) bool {
	t := l.trim_space()
	return t == '' || t.starts_with('#')
}

fn e3_item(l string) bool {
	t := l.trim_space()
	return t == '-' || t.starts_with('- ')
}

// e3_list is a FileSelections list as absolute, normalised paths; an absent key is empty.
fn e3_list(fs yaml.Any, key string, dir string) ![]string {
	v := fs.value_opt(key) or { return []string{} }
	if v is yaml.Null {
		return []string{}
	}
	if v !is []yaml.Any {
		return error('FileSelections.${key} is not a list')
	}
	mut out := []string{}
	for item in v.array() {
		// an empty item names nothing (`.string()` would make it a path called null)
		p := match item {
			yaml.Null { continue }
			string { item }
			[]yaml.Any, map[string]yaml.Any { return error('FileSelections.${key} holds an entry that is not a path') }
			else { item.string() }
		}
		if p == '' {
			continue
		}
		out << e3_abs(p, dir)
	}
	return out
}

// e3_key is a path as compared: without case on Windows, as E3 compares.
fn e3_key(p string) string {
	$if windows {
		return p.to_lower()
	} $else {
		return p
	}
}

fn e3_abs(p0 string, dir string) string {
	full0 := e3_join(dir, p0)
	// a project file saved on Windows may spell its paths with backslashes; a name that exists as
	// written (a backslash is a legal character on Linux) is kept
	$if !windows {
		if p0.contains('\\') && !os.exists(full0) {
			return e3_join(dir, p0.replace('\\', '/'))
		}
	}
	return full0
}

// e3_join is p under dir unless absolute, normalised. Not os.join_path, which turns a backslash
// into a separator on every platform.
fn e3_join(dir string, p string) string {
	return os.norm_path(if os.is_abs_path(p) { p } else { dir + os.path_separator + p })
}

// e3_walk is every model source below a folder, as E3 finds them (directories and files that
// are symlinks are not followed), and the folders that could not be listed.
fn e3_walk(root string) ([]string, []string) {
	mut out := []string{}
	mut unreadable := []string{}
	mut stack := [root]
	for stack.len > 0 {
		cur := stack.pop()
		entries := os.ls(cur) or {
			unreadable << cur
			continue
		}
		for e in entries {
			p := cur + os.path_separator + e
			if os.is_link(p) {
				continue
			}
			if os.is_dir(p) {
				stack << p
			} else if os.is_file(p) {
				low := e.to_lower()
				if low.ends_with('.arxml') || e3_artext_suffixes.any(low.ends_with(it)) {
					out << p
				}
			}
		}
	}
	return out, unreadable
}

// e3_ticked is E3's decision for a file: its own entry, else the nearest entry above it
// (`checked` winning where a path is in both), else in. The entries are keyed by e3_key.
fn e3_ticked(path string, unticks map[string]bool, ticks map[string]bool) bool {
	mut p := path
	for {
		k := e3_key(p)
		if k in ticks {
			return true
		}
		if k in unticks {
			return false
		}
		parent := os.dir(p)
		if parent == p || parent == '' || parent == '.' {
			return true
		}
		p = parent
	}
	return true
}
