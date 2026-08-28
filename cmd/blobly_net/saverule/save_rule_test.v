module saverule

// WHAT SAVE MEANS, state by state — the table five review rounds on #250 kept re-deciding by
// hand. Each row is one finding's scenario.
fn test_save_target_by_state() {
	// Nothing special: the model.
	assert save_target(SaveState{}) == .model
	// Drawn dirty text: the text (round 1 — the menu and the chord must agree on this).
	assert save_target(SaveState{ text_dirty: true, file_visible: true }) == .text
	// Dirty text that is NOT drawn — collapsed, docked behind, another tab — is not what the
	// user is saving (round 3): the model path, where save_project refuses on its own.
	assert save_target(SaveState{ text_dirty: true, file_visible: false }) == .model
	// The File tab drawn but clean: the model.
	assert save_target(SaveState{ text_dirty: false, file_visible: true }) == .model
	// Running: the text is applied on save and the rebuild is stopped-only (round 2).
	assert save_target(SaveState{ text_dirty: true, file_visible: true, running: true }) == .nothing
	// Running with no drawn dirty text is an ordinary model save — that path is run-safe.
	assert save_target(SaveState{ running: true }) == .model
	// The picker up: nothing, whatever else is true (rounds 3 and 4 — chord and menu alike).
	assert save_target(SaveState{ picker_open: true }) == .nothing
	assert save_target(SaveState{ picker_open: true, text_dirty: true, file_visible: true }) == .nothing
}
