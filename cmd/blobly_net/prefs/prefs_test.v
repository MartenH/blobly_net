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

// TWO INSTANCES: A changes the scale and saves; B, still open with the old snapshot, exits and
// saves its panes. B's save writes only what B changed, over the file as A left it.
fn test_a_save_writes_only_what_this_instance_changed_over_the_file_as_it_is() {
	mut a := Prefs{
		editor:   'vi'
		ui_scale: 1.5
	}
	a.panes['x'] = 100
	mut b := Prefs{
		editor:   'vi'
		ui_scale: 1.0 // B's stale snapshot
	}
	b.panes['x'] = 300 // what B dragged — and ONLY that: a pane B never touched is not in its map
	on_disk := parse(a.serialize())!
	written := merge(on_disk, b, Changed{ panes: true })
	assert written.ui_scale == 1.5 // A's scale survives B's exit
	assert written.editor == 'vi'
	assert written.panes['x'] == 300
	// a pane A dragged and B did not stays A's
	mut a2 := a
	a2.panes['y'] = 55
	mut b2 := Prefs{}
	b2.panes['x'] = 300
	kept := merge(parse(a2.serialize())!, b2, Changed{ panes: true })
	assert kept.panes['y'] == 55
	assert kept.panes['x'] == 300
	// and a change of the scale writes the scale alone
	scaled := merge(on_disk, Prefs{ ui_scale: 0.75 }, Changed{
		scale: true
	})
	assert scaled.ui_scale == 0.75
	assert scaled.editor == 'vi'
	assert scaled.panes['x'] == 100
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

fn test_pending_changes_add_up() {
	c := Changed{
		scale: true
	}.plus(Changed{ editor: true })
	assert c.scale && c.editor && !c.panes
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
