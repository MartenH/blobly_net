module saverule

// SaveTarget is what one Save — File ▸ Save or Ctrl+S — means in a given state of the GUI.
pub enum SaveTarget {
	// Write the project model to its file (or open Save As when it has none).
	model
	// Write the Configuration window's File-tab TEXT to the file: that tab holds the project as
	// text in its own buffer, and while it is drawn with unsaved text, saving the model would
	// overwrite what the user is looking at.
	text
	// Do nothing: the Save As picker is up (a second Save would reopen it over the name being
	// typed), or the text would be applied to a RUNNING model (applying the text rebuilds the
	// runtime, which is stopped-only).
	nothing
}

// SaveState is the state the rule reads. Five booleans, each a fact the GUI already tracks.
pub struct SaveState {
pub:
	// The File tab holds text that differs from the file.
	text_dirty bool
	// The File tab was actually DRAWN this frame — not merely selected in a window that is
	// collapsed or docked behind another.
	file_visible bool
	// The file browser (Open / Save As) is showing.
	picker_open bool
	// A measurement is running.
	running bool
}

// save_target is THE rule behind Save. Pure, and in a sub-module of the GUI rather than in
// its main package so it has a test without linking ImGui: five review rounds on #250 each
// moved this decision, and each fix was checked by reading. It is GUI policy — what the File
// tab, the picker and the run state mean to Save — so it does NOT live in modules/, which
// knows nothing of any of them (codex round 6 on #250). CI runs it as
// `v test cmd/blobly_net/saverule/`. The order matters and is the point:
//
//  1. the picker wins — a Save while it is up must not reopen it;
//  2. drawn dirty text is what Save means — the text, never the model under it;
//  3. but not while running — the text is applied on save and the rebuild is stopped-only;
//  4. otherwise the model.
//
// Dirty text that is NOT drawn does not count: the user is looking at something else, and
// save_project refuses on its own if the text is dirty (it will not overwrite the text's file).
pub fn save_target(s SaveState) SaveTarget {
	if s.picker_open {
		return .nothing
	}
	if s.text_dirty && s.file_visible {
		return if s.running { SaveTarget.nothing } else { SaveTarget.text }
	}
	return .model
}

// reserialize_drops_comments reports whether writing the model back over `file_text` (a Buses-tab
// Save, which reserializes from the model) would silently drop authored comments — the header and
// inline hints that are how the .blobnet format is learned (#80). A reserializing Save is the ONLY
// path that loses them (File ▸ Save writes the buffer verbatim). Pure so it is tested here rather
// than discovered on a file. A comment is a '#' that YAML would treat as one: at line start (after
// whitespace) OR preceded by whitespace, and NOT inside a quoted scalar — so `name: "a # b"` and
// `url: x#y` are not comments, but `interface: can0  # note` is (codex #268: trailing hints count).
fn opens_quote(prev u8) bool {
	// a quote begins a quoted scalar only where a scalar can start: after whitespace or a YAML
	// value delimiter. An apostrophe inside a plain scalar (driver's CAN) is therefore content.
	return prev == ` ` || prev == `\t` || prev == `:` || prev == `-` || prev == `[`
		|| prev == `{` || prev == `,` || prev == 0
}

pub fn line_has_yaml_comment(line string) bool {
	mut in_s := false // inside '...'
	mut in_d := false // inside "..."
	mut prev := u8(0)  // 0 = start of line
	for c in line {
		if in_s {
			if c == `'` {
				in_s = false
			}
		} else if in_d {
			if c == `"` {
				in_d = false
			}
		} else if c == `'` && opens_quote(prev) {
			in_s = true
		} else if c == `"` && opens_quote(prev) {
			in_d = true
		} else if c == `#` && (prev == ` ` || prev == `\t` || prev == 0) {
			return true
		}
		prev = c
	}
	return false
}

pub fn reserialize_drops_comments(file_text string) bool {
	for line in file_text.split_into_lines() {
		if line_has_yaml_comment(line) {
			return true
		}
	}
	return false
}
