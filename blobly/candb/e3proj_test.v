module candb

import os

fn e3_tree(name string) string {
	dir := os.join_path(os.temp_dir(), 'candb_e3proj_${name}_${os.getpid()}')
	os.rmdir_all(dir) or {}
	for sub in ['proj/gen/keep', 'proj/swc', 'base/build', 'base/types', 'other'] {
		os.mkdir_all(os.join_path(dir, sub)) or { panic(err) }
	}
	for f in ['proj/net.arxml', 'proj/gen/a.arxml', 'proj/gen/keep/b.ARXML', 'proj/swc/c.swcd',
		'proj/notes.txt', 'base/types/t.arxml', 'base/build/old.arxml', 'other/o.arxml'] {
		os.write_file(os.join_path(dir, f), '') or { panic(err) }
	}
	return dir
}

// E3's rules: folders searched recursively, a path's own entry deciding (checked first), else the
// nearest entry above it, else in; files taken as named; ARText said and left out.
fn test_an_e3_project_selects_by_e3s_rules() {
	dir := e3_tree('rules')
	defer {
		os.rmdir_all(dir) or {}
	}
	proj := os.join_path(dir, 'proj')
	text := 'ProjectName: p
FileSelections:
  folders:
  - .
  - ../base
  - ../gone
  files:
  - ../other/o.arxml
  - ../other/none.arxml
  unchecked:
  - gen
  - ../base/build
  checked:
  - gen/keep
RootSelections:
  System: /BSW_pkg/BSW_pkg
  EcuInstance: /System/TestECU
'
	p := parse_e3proj(text, proj)!
	rel := p.files.map(it.all_after(dir + os.path_separator))
	assert rel == ['base/types/t.arxml', 'other/o.arxml', 'proj/gen/keep/b.ARXML', 'proj/net.arxml'].map(it.replace('/',
		os.path_separator))
	assert p.ecu == '/System/TestECU'
	assert p.notes.len == 3
	assert p.notes.any(it.contains('c.swcd') && it.contains('ARText'))
	assert p.notes.any(it.contains('gone') && it.contains('not a folder'))
	assert p.notes.any(it.contains('none.arxml') && it.contains('does not exist'))
}

// A path named both unchecked and checked is in; a file unchecked inside a ticked folder is out.
fn test_an_own_entry_beats_the_folders() {
	dir := e3_tree('own')
	defer {
		os.rmdir_all(dir) or {}
	}
	p := parse_e3proj('FileSelections:\n  folders: [.]\n  unchecked: [net.arxml, gen/keep/b.ARXML]\n  checked: [gen/keep/b.ARXML]\n',
		os.join_path(dir, 'proj'))!
	names := p.files.map(os.file_name(it))
	assert names == ['a.arxml', 'b.ARXML']
	assert p.ecu == ''
}

// A symlinked folder is not followed, as E3 does not follow one.
fn test_a_symlinked_folder_is_not_followed() {
	$if windows {
		return
	}
	dir := e3_tree('link')
	defer {
		os.rmdir_all(dir) or {}
	}
	os.symlink(os.join_path(dir, 'other'), os.join_path(dir, 'proj', 'linked')) or { panic(err) }
	p := parse_e3proj('FileSelections:\n  folders: [.]\n', os.join_path(dir, 'proj'))!
	assert !p.files.any(it.contains('o.arxml'))
}

fn test_a_file_that_is_not_an_e3_project_is_refused() {
	parse_e3proj('ProjectName: p\n', '.') or {
		assert err.msg().contains('no FileSelections')
		return
	}
	assert false
}

// A list written at its key's own indentation (PyYAML's default, so E3's) reads like an indented one.
fn test_compact_sequences_are_indented() {
	assert indent_compact_sequences('a:\n  b:\n  - x\n  # c\n  - y\n  c: 1\nd:\n- z\ne: 2\n') == 'a:\n  b:\n    - x\n    # c\n    - y\n  c: 1\nd:\n  - z\ne: 2\n'
	assert indent_compact_sequences('a:\n  - x\n') == 'a:\n  - x\n'
}

// An E3 project is a database reference like a model file: its selection is the input set, the
// project file a dependency, and what it selects and cannot read a reader note.
fn test_an_e3_project_is_an_arxml_reference() {
	dir := e3_tree('ref')
	defer {
		os.rmdir_all(dir) or {}
	}
	example := os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'example.arxml')
	os.cp(example, os.join_path(dir, 'other', 'o.arxml'))!
	ep := os.join_path(dir, 'proj', 'p.e3proj')
	os.write_file(ep, 'FileSelections:\n  folders:\n  - swc\n  files:\n  - ../other/o.arxml\n')!
	assert is_arxml_path(ep)
	assert is_arxml_ref(ep + '#Body')
	inputs := arxml_inputs([ep])!
	assert inputs.files.map(os.file_name(it)) == ['o.arxml']
	assert inputs.deps == [ep]
	got := open_database(ep + '#Body')!
	want := open_database(example + '#Body')!
	assert got.db.messages.str() == want.db.messages.str()
	a := load_arxml_file(ep)!
	assert a.report.notes.any(it.starts_with('input: ') && it.contains('c.swcd'))
	arxml_inputs([ep, example]) or {
		assert err.msg().contains('name it alone')
		return
	}
	assert false
}

// A project file saved on Windows spells its paths with backslashes; elsewhere they still select.
fn test_backslash_paths_select() {
	$if windows {
		return
	}
	dir := e3_tree('bslash')
	defer {
		os.rmdir_all(dir) or {}
	}
	p := parse_e3proj('FileSelections:\n  folders:\n  - ..\\base\n  unchecked:\n  - ..\\base\\build\n',
		os.join_path(dir, 'proj'))!
	assert p.files.map(os.file_name(it)) == ['t.arxml']
	assert p.notes.len == 0
}

// What is selected and not read is said: a folder that cannot be listed, a folder under files,
// a file that is not ARXML.
fn test_what_cannot_be_read_is_said() {
	$if windows {
		return
	}
	dir := e3_tree('said')
	defer {
		os.chmod(os.join_path(dir, 'base', 'build'), 0o755) or {}
		os.rmdir_all(dir) or {}
	}
	os.chmod(os.join_path(dir, 'base', 'build'), 0o000)!
	p := parse_e3proj('FileSelections:\n  folders: [../base]\n  files: [notes.txt, gen]\n',
		os.join_path(dir, 'proj'))!
	assert p.files.map(os.file_name(it)) == ['t.arxml']
	assert p.notes.any(it.contains('notes.txt') && it.contains('not an ARXML file'))
	assert p.notes.any(it.ends_with('gen: selected as a file but is a folder; not read'))
	// root lists any folder, so the refusal is only asserted where it happens
	if os.getuid() != 0 {
		assert p.notes.any(it.contains('build: folder cannot be listed'))
	}
}

// The folders a project walks are roots of its input set, and its ECU is read without a walk.
fn test_walked_folders_are_roots() {
	dir := e3_tree('roots')
	defer {
		os.rmdir_all(dir) or {}
	}
	ep := os.join_path(dir, 'proj', 'p.e3proj')
	os.write_file(ep, 'FileSelections:\n  folders:\n  - ../base\nRootSelections:\n  EcuInstance: /S/Ecu1\n')!
	inputs := arxml_inputs([ep])!
	assert inputs.opts.roots.any(os.real_path(it) == os.real_path(os.join_path(dir, 'base')))
	assert e3proj_ecu(ep)! == '/S/Ecu1'
}

// The ECU: a path or the older {path, ar_item} mapping, none for null.
fn test_the_ecu_and_its_name() {
	m := parse_e3proj('FileSelections:\n  folders: []\nRootSelections:\n  EcuInstance:\n    path: m.arxml\n    ar_item: /ECUs/ECU_A\n',
		'.')!
	assert m.ecu == '/ECUs/ECU_A'
	assert parse_e3proj('FileSelections:\n  folders: []\nRootSelections:\n  EcuInstance: null\n',
		'.')!.ecu == ''
}

// A key with a trailing comment still takes the list beneath it; an empty entry names nothing;
// an entry naming the base folder itself is honoured from a relative base.
fn test_comments_nulls_and_the_base_folder() {
	dir := e3_tree('edge')
	defer {
		os.rmdir_all(dir) or {}
	}
	proj := os.join_path(dir, 'proj')
	p := parse_e3proj('FileSelections:\n  files: # the model\n  - net.arxml\n', proj)!
	assert p.files.map(os.file_name(it)) == ['net.arxml']
	os.mkdir_all(os.join_path(proj, 'null'))!
	os.write_file(os.join_path(proj, 'null', 'n.arxml'), '')!
	q := parse_e3proj('FileSelections:\n  folders: [.]\n  unchecked: [.]\n  checked: [null]\n',
		proj)!
	assert q.files.len == 0
	old := os.getwd()
	os.chdir(proj)!
	defer {
		os.chdir(old) or {}
	}
	r := parse_e3proj('FileSelections:\n  files: [net.arxml]\n  unchecked: [.]\n', '.')!
	assert r.files.len == 0
}

// A Linux file name holding a backslash is the file it names, where it exists.
fn test_a_native_backslash_name_is_kept() {
	$if windows {
		return
	}
	dir := e3_tree('native')
	defer {
		os.rmdir_all(dir) or {}
	}
	proj := os.join_path(dir, 'proj')
	os.write_file(proj + '/weird\\name.arxml', '')!
	os.mkdir_all(os.join_path(proj, 'weird'))!
	os.write_file(os.join_path(proj, 'weird', 'name.arxml'), '')!
	p := parse_e3proj("FileSelections:\n  files: ['weird\\name.arxml']\n", proj)!
	assert p.files.map(os.file_name(it)) == ['weird\\name.arxml']
}
