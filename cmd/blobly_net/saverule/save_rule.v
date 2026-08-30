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

// line_has_yaml_comment reports whether a line carries a YAML comment a reserializing Save would
// drop: a '#' at line start (after whitespace) or preceded by whitespace. It DELIBERATELY does
// not track quoting — a '#' inside a quoted value (`name: "a # b"`) is reported as a comment too.
// This biases to WARN: a false warning costs one extra confirmation, a missed comment loses the
// user's text silently, and only the latter is a real failure (codex #268 — three rounds chasing
// quote edge cases the other way). '#' glued to a non-space char (`url: x#y`) is not a comment.
pub fn line_has_yaml_comment(line string) bool {
	mut prev := u8(0) // 0 = start of line
	for c in line {
		if c == `#` && (prev == ` ` || prev == `\t` || prev == 0) {
			return true
		}
		prev = c
	}
	return false
}

// reserialize_drops_comments reports whether reserializing over `file_text` (a Buses-tab Save,
// which rebuilds the file from the model) would drop authored comments — the header and inline
// hints that are how the .blobnet format is learned (#80). Only File ▸ Save keeps them verbatim.
pub fn reserialize_drops_comments(file_text string) bool {
	// A UTF-8 BOM (EF BB BF) precedes the first character, so a BOM'd file whose first line is
	// `# header` would otherwise not be seen as a comment on line 1 (codex #268). Strip it first.
	text := file_text.trim_string_left('\ufeff')
	for line in text.split_into_lines() {
		if line_has_yaml_comment(line) {
			return true
		}
	}
	return false
}
