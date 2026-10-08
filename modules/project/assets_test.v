module project

import os

// a scratch tree: <root>/proj (the project), <root>/dbc/x.dbc, <root>/net.arxml, <root>/proj/sub/m.csv
fn asset_tree() !string {
	root := os.join_path(os.vtmp_dir(), 'assets_${os.getpid()}')
	os.mkdir_all(os.join_path(root, 'proj', 'sub'))!
	os.mkdir_all(os.join_path(root, 'dbc'))!
	os.mkdir_all(os.join_path(root, 'other', 'deeper'))!
	os.write_file(os.join_path(root, 'dbc', 'x.dbc'), '')!
	os.write_file(os.join_path(root, 'net.arxml'), '')!
	os.write_file(os.join_path(root, 'proj', 'sub', 'm.csv'), '')!
	return root
}

fn same_file(a string, b string) bool {
	return os.real_path(a) == os.real_path(b)
}

// A reference names its file from the project's directory, and resolve_asset reads it back to
// the same file — wherever the program was started.
fn test_asset_ref_is_relative_to_the_project_and_resolves_back() {
	root := asset_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	proj := os.join_path(root, 'proj')
	x := os.join_path(root, 'dbc', 'x.dbc')
	m := os.join_path(proj, 'sub', 'm.csv')
	assert asset_ref(proj, x) == '../dbc/x.dbc'
	assert asset_ref(proj, m) == 'sub/m.csv'
	for p in [x, m, os.join_path(root, 'net.arxml')] {
		assert same_file(resolve_asset(proj, asset_ref(proj, p)), p)
	}
	// nothing in common but the root: absolute
	$if !windows {
		assert asset_ref(proj, '/etc/hosts') == '/etc/hosts'
	}
}

// An unsaved project (no directory) names a file under the working directory relative to it,
// as the GUI always did, and anything else absolutely.
fn test_asset_ref_of_an_unsaved_project() {
	root := asset_tree()!
	was := os.getwd()
	defer {
		os.chdir(was) or {}
		os.rmdir_all(root) or {}
	}
	os.chdir(root)!
	assert asset_ref('', os.join_path(root, 'dbc', 'x.dbc')) == 'dbc/x.dbc'
	$if !windows {
		assert asset_ref('', '/etc/hosts') == '/etc/hosts'
	}
}

// Save As: a reference that resolved against the old directory names the same file from the new
// one, fragment and all; an absolute one, and one that never resolved there, are left as written.
fn test_rebase_assets_follows_a_save_as() {
	root := asset_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	proj := os.join_path(root, 'proj')
	deeper := os.join_path(root, 'other', 'deeper')
	abs := os.join_path(root, 'dbc', 'x.dbc')
	mut p := Project{
		channels: [
			Channel{
				name:      'CAN1'
				databases: ['../dbc/x.dbc', '../net.arxml#Body', abs, 'nowhere.dbc']
				manifest:  'sub/m.csv'
				replay:    Replay{
					source: '../net.arxml'
				}
			},
		]
	}
	p.rebase_assets(proj, deeper)
	ch := p.channels[0]
	assert ch.databases == ['../../dbc/x.dbc', '../../net.arxml#Body', abs, 'nowhere.dbc']
	assert ch.manifest == '../../proj/sub/m.csv'
	r := ch.replay or { panic('replay lost') }
	assert r.source == '../../net.arxml'
	assert same_file(resolve_asset(deeper, ch.databases[0]), abs)
	assert same_file(resolve_asset(deeper, ch.databases[1].all_before('#')), os.join_path(root, 'net.arxml'))
	assert same_file(resolve_asset(deeper, ch.manifest), os.join_path(proj, 'sub', 'm.csv'))
}

// A project saved for the first time rebases what it referenced from the working directory.
fn test_rebase_from_an_unsaved_project() {
	root := asset_tree()!
	was := os.getwd()
	defer {
		os.chdir(was) or {}
		os.rmdir_all(root) or {}
	}
	os.chdir(root)!
	assert rebase_ref('', os.join_path(root, 'proj'), 'dbc/x.dbc', true) == '../dbc/x.dbc'
	assert rebase_ref('', os.join_path(root, 'proj'), 'net.arxml#Body', true) == '../net.arxml#Body'
}
