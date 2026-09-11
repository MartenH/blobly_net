module prefs

fn test_no_file_and_an_empty_file_are_the_defaults() {
	p := parse('')!
	assert p.editor == ''
	assert p.ui_scale == 1.0
}

fn test_the_file_round_trips_including_a_windows_editor_path() {
	p := Prefs{
		editor:   '"C:\\Program Files\\Editor\\ed.exe" -g %s'
		ui_scale: 1.25
	}
	q := parse(p.serialize())!
	assert q.editor == p.editor
	assert q.ui_scale == 1.25
}

fn test_unknown_keys_are_ignored_and_a_wild_scale_is_clamped() {
	p := parse('editor = "vi"\nfuture = 3\nui_scale = 0\n')!
	assert p.editor == 'vi'
	assert p.ui_scale == 0.5
	q := parse('ui_scale = 40\n')!
	assert q.ui_scale == 3.0
}

fn test_a_broken_file_is_an_error_not_defaults() {
	if _ := parse('editor = "unterminated\n') {
		assert false
	}
}

fn test_the_editor_command_is_split_with_quotes_and_the_file_substituted() {
	assert editor_argv('code -g %s', 'D:\\x\\a.lua') == ['code', '-g', 'D:\\x\\a.lua']
	// no %s: appended
	assert editor_argv('gvim', '/tmp/a.lua') == ['gvim', '/tmp/a.lua']
	// a quoted executable path with a space
	assert editor_argv('"C:\\Program Files\\E\\e.exe" --wait %s', 'C:\\a b\\s.lua') == [
		'C:\\Program Files\\E\\e.exe',
		'--wait',
		'C:\\a b\\s.lua',
	]
	// %s quoted (the shell habit) and %s inside a token both mean the file; nothing is appended
	assert editor_argv('code -g "%s"', '/t/a b.lua') == ['code', '-g', '/t/a b.lua']
	assert editor_argv('ed --file=%s', '/t/a.lua') == ['ed', '--file=/t/a.lua']
	// quotes only group: an empty quoted token is dropped
	assert editor_argv('ed "" %s', '/t/a.lua') == ['ed', '/t/a.lua']
	assert editor_argv('  ', 'x') == []
	assert editor_argv('', 'x') == []
}

fn test_dragged_panes_round_trip_and_a_zero_is_dropped() {
	mut p := Prefs{}
	p.panes['script_editor'] = 300
	p.panes['system_ecu'] = 160.5
	q := parse(p.serialize())!
	assert q.panes['script_editor'] == 300
	assert q.panes['system_ecu'] == 160.5
	r := parse('[panes]\nx = 0\ny = -5\n')!
	assert r.panes.len == 0
}
