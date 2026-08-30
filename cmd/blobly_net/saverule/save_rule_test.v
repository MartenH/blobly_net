module saverule

fn test_save_target_by_state() {
	assert save_target(SaveState{}) == .model
	assert save_target(SaveState{ text_dirty: true, file_visible: true }) == .text
	assert save_target(SaveState{ text_dirty: true, file_visible: false }) == .model
	assert save_target(SaveState{ text_dirty: false, file_visible: true }) == .model
	assert save_target(SaveState{ text_dirty: true, file_visible: true, running: true }) == .nothing
	assert save_target(SaveState{ running: true }) == .model
	assert save_target(SaveState{ picker_open: true }) == .nothing
	assert save_target(SaveState{ picker_open: true, text_dirty: true, file_visible: true }) == .nothing
}

fn test_line_has_yaml_comment() {
	assert line_has_yaml_comment('# whole line')
	assert line_has_yaml_comment('   # indented')
	assert line_has_yaml_comment('k: v # trailing')
	assert line_has_yaml_comment("name: driver's CAN # note") // plain-scalar apostrophe: still a comment
	assert line_has_yaml_comment("name: rock 'n roll # note")
	assert line_has_yaml_comment('k: v#glued') == false // # not preceded by whitespace
	assert line_has_yaml_comment('url: http://x#frag') == false
	assert line_has_yaml_comment('k: v') == false
	assert line_has_yaml_comment('') == false
	// bias-to-warn: a # inside a quoted value is reported too (a safe over-warn, by design)
	assert line_has_yaml_comment('name: "a # b"')
}

fn test_reserialize_drops_comments() {
	assert reserialize_drops_comments('# a header\nbuses:\n')
	assert reserialize_drops_comments('buses:\n  - name: CAN0  # a hint\n')
	assert reserialize_drops_comments('buses:\n  - name: CAN0\n') == false
	assert reserialize_drops_comments('') == false
	assert reserialize_drops_comments('url: x#y\nk: v\n') == false
}
