module prefs

import math

fn test_no_file_and_an_empty_file_are_the_defaults() {
	p := parse('')!
	assert p.editor == ''
	assert p.ui_scale == 1.0
	assert p.foreign == []
}

fn test_the_file_round_trips_including_a_windows_editor_path() {
	p := Prefs{
		editor:   '"C:\\Program Files\\Editor\\ed.exe" -g %s'
		ui_scale: 1.25
	}
	q := parse(p.serialize())!
	assert q.editor == p.editor
	assert q.ui_scale == 1.25
	assert q.foreign == []
}

fn test_an_unchanged_scale_keeps_its_precision_through_a_save() {
	p := parse('ui_scale = 1.125\n')!
	assert p.ui_scale == 1.125
	q := parse(p.serialize())!
	assert q.ui_scale == 1.125
	assert parse(Prefs{ ui_scale: 1.0 }.serialize())!.ui_scale == 1.0
}

fn test_a_wild_scale_is_clamped() {
	p := parse('editor = "vi"\nui_scale = 0\n')!
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

// THE CLASS: a newer build's keys, in every spelling TOML allows. None is read, all are
// reported as foreign — which is what keeps an automatic save away from the file — and our
// own keys in an unusual spelling are NOT foreign, since the parsed document, not the text,
// says what a key is.
fn test_keys_this_build_does_not_know_are_foreign_whatever_their_spelling() {
	newer := 'editor = "vi"\nrecent_limit = 12\n"quoted key" = 1\nfuture = """\n[not a table]\n"""\n# a comment with """ in it\nui_scale = 1.25\n\n[panes]\nx = 200\n\n[colors]\ntheme = "dark"\n'
	p := parse(newer)!
	assert p.editor == 'vi'
	assert p.ui_scale == 1.25
	assert p.panes['x'] == 200
	assert p.foreign == ['recent_limit', 'quoted key', 'future', 'colors']
	// and [panes] itself as something other than a table
	nt := parse('panes = "auto"\n')!
	assert nt.foreign == ['panes']
	// a known key of a type this build cannot read
	t := parse('ui_scale = "system"\neditor = 3\n')!
	assert t.ui_scale == 1.0
	assert t.editor == ''
	assert t.foreign == ['editor', 'ui_scale']
	// and a value under [panes] that is not a number
	f := parse('[panes]\nx = 200\nfuture_layout = "auto"\n')!
	assert f.panes['x'] == 200
	assert f.foreign == ['panes.future_layout']
	// our keys spelled quoted, and the panes table spelled dotted and quoted, are ours
	q := parse('"editor" = "vi"\n\'ui_scale\' = 1.5\npanes.script_editor = 200\n')!
	assert q.editor == 'vi'
	assert q.ui_scale == 1.5
	assert q.panes['script_editor'] == 200
	assert q.foreign == []
	r := parse('["panes"]\n"DBC editor" = 240\n')!
	assert r.panes['DBC editor'] == 240
	assert r.foreign == []
}

fn test_a_pane_name_outside_the_bare_key_grammar_is_written_quoted() {
	mut p := Prefs{}
	p.panes['DBC editor'] = 240
	p.panes['plain'] = 10
	out := p.serialize()
	assert out.contains('"DBC editor" = 240.0')
	assert out.contains('plain = 10.0')
	q := parse(out)!
	assert q.panes['DBC editor'] == 240
	assert q.panes['plain'] == 10
}

// A save writes the WHOLE file from what this instance holds (#309), so what it holds must
// include the panes it loaded and never touched — otherwise a session that dragged one divider
// would erase the other five.
fn test_a_session_keeps_the_panes_it_did_not_drag() {
	mut on_disk := parse(Prefs{
		editor:   'vi'
		ui_scale: 1.5
		panes:    {
			'x': f32(100)
			'y': 55
		}
	}.serialize())!
	// this session dragged x and nothing else: y is not in the map, and stays as the session
	// that dragged it left it
	on_disk.keep_panes({
		'x': f32(300)
	})
	assert on_disk.panes['x'] == 300
	assert on_disk.panes['y'] == 55
	// what is written is the whole file, from what this instance holds: last writer wins (#309)
	back := parse(on_disk.serialize())!
	assert back.ui_scale == 1.5
	assert back.editor == 'vi'
	assert back.panes['x'] == 300
	assert back.panes['y'] == 55
	// a session that dragged nothing writes the panes it loaded, unchanged
	mut none_dragged := parse(on_disk.serialize())!
	none_dragged.keep_panes(map[string]f32{})
	assert none_dragged.panes == on_disk.panes
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

fn test_a_nan_scale_is_the_default() {
	// vlib's toml reads `nan` as 0 (clamped to the floor); the guard is for the value itself
	assert clamp_scale(f32(math.nan())) == 1.0
	p := parse('ui_scale = nan\n')!
	assert p.ui_scale == p.ui_scale // whatever the parser made of it, it is a number
	assert clamp_scale(f32(math.inf(1))) == 3.0 // and inf, which the parser also reads as 0
}

fn test_control_characters_in_the_editor_command_survive_a_rewrite() {
	p := parse('editor = "a\\nb\\tc\\u0001d"\n')!
	assert p.editor == 'a\nb\tc\x01d'
	q := parse(p.serialize())!
	assert q.editor == p.editor
}
