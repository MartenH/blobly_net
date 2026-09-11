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

fn test_a_newer_builds_settings_survive_an_older_builds_save() {
	newer := 'editor = "vi"\nrecent_limit = 12\nui_scale = 1.25\n\n[panes]\nx = 200\n\n[colors]\ntheme = "dark"\n# a comment in it\n'
	p := parse(newer)!
	assert p.editor == 'vi'
	assert p.unknown == ['recent_limit = 12', '[colors]', 'theme = "dark"', '# a comment in it']
	// what this build writes still carries them, and reads back the same
	q := parse(p.serialize())!
	assert q.unknown == p.unknown
	assert q.panes['x'] == 200
	// a top-level line this build owns is NOT kept twice
	assert p.serialize().count('ui_scale') == 1
}

fn test_a_quoted_spelling_of_a_known_key_is_not_kept_as_unknown() {
	p := parse('"editor" = "vi"\n\'ui_scale\' = 1.5\n')!
	assert p.editor == 'vi'
	assert p.ui_scale == 1.5
	assert p.unknown == []
	// and so the rewrite has each key once
	assert p.serialize().count('editor') == 1
}

fn test_a_quoted_panes_header_and_a_quoted_pane_name_round_trip() {
	p := parse('["panes"]\n"DBC editor" = 240\nplain = 10\n')!
	assert p.panes['DBC editor'] == 240
	assert p.panes['plain'] == 10
	assert p.unknown == []
	out := p.serialize()
	assert out.count('panes]') == 1
	assert out.contains('"DBC editor" = 240.0')
	q := parse(out)!
	assert q.panes['DBC editor'] == 240
}

fn test_a_bracket_inside_a_multiline_string_is_not_a_header() {
	src := 'future = """\n[section]\nx = 1\n"""\nui_scale = 1.5\n\n[panes]\np = 9\n'
	p := parse(src)!
	assert p.ui_scale == 1.5
	assert p.panes['p'] == 9
	assert p.unknown == ['future = """', '[section]', 'x = 1', '"""']
	// written back, the string is whole and [panes] is outside it
	q := parse(p.serialize())!
	assert q.unknown == p.unknown
	assert q.panes['p'] == 9
}
