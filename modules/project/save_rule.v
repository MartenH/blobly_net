module project

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

// save_target is THE rule behind Save. Pure, and here rather than in the GUI so it has a test:
// five review rounds on #250 each moved this decision, and each fix was checked by reading
// (the GUI has no tests; CI runs `v test modules/`). The order matters and is the point:
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
