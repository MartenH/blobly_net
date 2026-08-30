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

fn test_reserialize_drops_comments() {
	assert reserialize_drops_comments('# a header\nbuses:\n')
	// trailing YAML comment after a value IS dropped by a reserializing Save (codex #268)
	assert reserialize_drops_comments('buses:\n  - name: CAN0  # a hint\n')
	assert reserialize_drops_comments('    # indented comment\nx: 1') // leading whitespace before #
	assert reserialize_drops_comments('buses:\n  - name: CAN0\n') == false
	assert reserialize_drops_comments('') == false
	assert reserialize_drops_comments('name: "a # b"') == false // # inside a double-quoted value
	assert reserialize_drops_comments("name: 'a # b'") == false // # inside a single-quoted value
	assert reserialize_drops_comments('url: http://x#frag') == false // # not preceded by whitespace
	assert reserialize_drops_comments('addr: can0  # note  # two') // first valid # wins
}

fn test_line_has_yaml_comment() {
	assert line_has_yaml_comment('# whole line')
	assert line_has_yaml_comment('   # indented')
	assert line_has_yaml_comment('k: v # trailing')
	assert line_has_yaml_comment('k: "v # not"') == false
	assert line_has_yaml_comment("k: 'v # not'") == false
	assert line_has_yaml_comment('k: v#glued') == false // no whitespace before #
	assert line_has_yaml_comment('k: v') == false
	assert line_has_yaml_comment('') == false
	assert line_has_yaml_comment("name: driver's CAN # bench note")
	assert line_has_yaml_comment("it's fine # note")
	assert line_has_yaml_comment("name: 'a # b'") == false
	assert line_has_yaml_comment("- 'a # b'") == false
}
