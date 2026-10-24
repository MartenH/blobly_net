module project

import os
import blobly.candb

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
	// a reference that resolves nowhere keeps naming where it would be looked for first
	assert ch.databases == ['../../dbc/x.dbc', '../../net.arxml#Body', abs, '../../proj/nowhere.dbc']
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
	proj := os.join_path(root, 'proj')
	assert rebase_ref('', proj, 'dbc/x.dbc') == '../dbc/x.dbc'
	assert rebase_ref('', proj, 'net.arxml#Body') == '../net.arxml#Body'
	// an unsaved project wrote a file outside the working directory absolutely; the first Save
	// As gives it a relative spelling where the new home shares more than the root
	assert rebase_ref('', proj, os.join_path(root, 'dbc', 'x.dbc')) == '../dbc/x.dbc'
}

// A reference that resolves only from the working directory (`dbc/…` written against the folder
// the program was started in) is rebased too, since resolve_asset says where it resolves now; a
// saved project's absolute reference is left alone.
fn test_rebase_follows_resolve_asset() {
	root := asset_tree()!
	was := os.getwd()
	defer {
		os.chdir(was) or {}
		os.rmdir_all(root) or {}
	}
	os.chdir(root)!
	proj := os.join_path(root, 'proj')
	deeper := os.join_path(root, 'other', 'deeper')
	assert rebase_ref(proj, deeper, 'dbc/x.dbc') == '../../dbc/x.dbc'
	abs := os.join_path(root, 'dbc', 'x.dbc')
	assert rebase_ref(proj, deeper, abs) == abs
	// a file whose own name carries `#`: resolve_asset reads it whole, and so does the rebase
	os.write_file(os.join_path(proj, 'cap.arxml#run'), '')!
	assert rebase_ref(proj, deeper, 'cap.arxml#run') == '../../proj/cap.arxml#run'
	assert os.exists(resolve_asset(deeper, '../../proj/cap.arxml#run'))
}

// A failed Save As puts back the references and only them.
fn test_restore_assets_puts_back_the_references_only() {
	root := asset_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	mut p := Project{
		channels: [
			Channel{
				name:      'CAN1'
				databases: ['../dbc/x.dbc']
				manifest:  'sub/m.csv'
			},
		]
	}
	was := p.rebase_assets(os.join_path(root, 'proj'), os.join_path(root, 'other', 'deeper'))
	p.channels[0].senders << Sender{
		name: 'gen'
	}
	p.restore_assets(was)
	assert p.channels[0].databases == ['../dbc/x.dbc']
	assert p.channels[0].manifest == 'sub/m.csv'
	assert p.channels[0].senders.len == 1
}

// Through a symlinked directory the kernel walks `../` physically, so the climb is computed
// over real paths: a lexical one would land beside the link, not beside its target.
fn test_asset_ref_through_a_symlink() {
	$if windows {
		return
	}
	root := asset_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	// a project in <root>/link, which is <root>/other/deeper, naming <root>/dbc/x.dbc: a lexical
	// climb says `../dbc/x.dbc`, which the kernel walks from <root>/other/deeper to nothing
	os.symlink(os.join_path(root, 'other', 'deeper'), os.join_path(root, 'link'))!
	proj := os.join_path(root, 'link')
	ref := asset_ref(proj, os.join_path(root, 'dbc', 'x.dbc'))
	assert ref == '../../dbc/x.dbc'
	assert os.exists(resolve_asset(proj, ref))
}

// A reference that climbs OUT of a symlinked directory names the file beside the link's target,
// as the kernel walks it — os.abs_path's paper collapse would have named the one beside the link.
fn test_rebase_walks_dotdot_physically() {
	$if windows {
		return
	}
	root := asset_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	proj := os.join_path(root, 'proj')
	// proj/link -> <root>/other/deeper; `link/../m2.csv` is <root>/other/m2.csv
	os.symlink(os.join_path(root, 'other', 'deeper'), os.join_path(proj, 'link'))!
	os.write_file(os.join_path(root, 'other', 'm2.csv'), '')!
	moved := rebase_ref(proj, os.join_path(root, 'dbc'), 'link/../m2.csv')
	assert moved == '../other/m2.csv'
	assert os.exists(resolve_asset(os.join_path(root, 'dbc'), moved))
}

// On Unix a backslash is part of a name: a file the loader opens from the working directory as
// written keeps its name through a Save As.
fn test_rebase_keeps_a_literal_backslash_on_unix() {
	$if windows {
		return
	}
	root := asset_tree()!
	was := os.getwd()
	defer {
		os.chdir(was) or {}
		os.rmdir_all(root) or {}
	}
	os.chdir(root)!
	os.write_file(root + '/a\\b.dbc', '')! // not os.join_path, which rewrites the `\\`
	assert rebase_ref(os.join_path(root, 'proj'), os.join_path(root, 'proj'), 'a\\b.dbc') == '../a\\b.dbc'
}

// A UNC path stays absolute: resolve_asset's join collapses the server prefix, so a relative
// reference under a share would resolve nowhere.
fn test_unc_stays_absolute() {
	assert asset_ref('//srv/share/proj', '//srv/share/proj/db/x.dbc') == '//srv/share/proj/db/x.dbc'
	assert asset_ref('/home/u/proj', '\\\\srv\\share\\x.dbc') == '\\\\srv\\share\\x.dbc'
}

// A Windows project opened on Linux: its drive and UNC references are absolute whatever this
// host's grammar says, and a Save As leaves them as written.
fn test_foreign_absolute_references_are_left_alone() {
	for ref in ['C:/bench/net.arxml#Body', 'C:\\bench\\x.dbc', '\\\\srv\\share\\x.dbc', '//srv/share/x.dbc'] {
		assert rebase_ref('/home/u/old', '/home/u/new', ref) == ref
		assert rebase_ref('', '/home/u/new', ref) == ref
	}
}

// A file that is itself a symlink is named as the link, not its target: retargeting
// `current.dbc` still moves the project, and the reference stays project-local.
fn test_a_symlinked_file_keeps_its_name() {
	$if windows {
		return
	}
	root := asset_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	os.symlink(os.join_path(root, 'dbc', 'x.dbc'), os.join_path(root, 'proj', 'current.dbc'))!
	proj := os.join_path(root, 'proj')
	assert asset_ref(proj, os.join_path(proj, 'current.dbc')) == 'current.dbc'
	assert rebase_ref(proj, os.join_path(root, 'other'), 'current.dbc') == '../proj/current.dbc'
}

// A reference to a file in directories not made yet, under a project opened through a symlinked
// directory: the existing ancestor is resolved and the rest appended, so the rebased reference
// names where the original project would find the file once it appears.
fn test_missing_nested_reference_through_a_symlinked_project() {
	$if windows {
		return
	}
	root := asset_tree()!
	defer {
		os.rmdir_all(root) or {}
	}
	// <root>/link -> <root>/proj; the project is opened as <root>/link
	os.symlink(os.join_path(root, 'proj'), os.join_path(root, 'link'))!
	moved := rebase_ref(os.join_path(root, 'link'), os.join_path(root, 'other'), 'gen/db/net.dbc')
	assert moved == '../proj/gen/db/net.dbc'
}

// Every reference a shipped project makes into this repository resolves from the project's own
// directory, never only through resolve_asset's working-directory fallback: CI and the suites run
// from the repository root, where that fallback hides a wrong spelling, and a bundle opened from a
// shortcut loads an empty database through it. A reference leaving the repository (a sibling
// checkout's generated file) is not this repository's to check.
fn test_shipped_projects_resolve_from_their_own_directory() {
	root := os.norm_path(@VMODROOT)
	mut seen := 0
	for path in os.walk_ext(os.join_path(root, 'projects'), '.blobnet') {
		dir := os.dir(path)
		p := parse(os.read_file(path)!)!
		for ch in p.channels {
			mut refs := [ch.manifest]
			for db in ch.databases {
				file, _ := candb.split_database_ref(db)
				refs << file
			}
			if r := ch.replay {
				refs << r.source
			}
			for ref in refs {
				if ref == '' {
					continue
				}
				assert !os.is_abs_path(ref), '${path}: ${ref} is absolute'
				full := os.norm_path(os.join_path(dir, ref))
				if full.starts_with(root + os.path_separator) {
					assert os.exists(full), '${path}: ${ref} does not resolve from the project file'
					seen++
				}
			}
		}
	}
	assert seen > 0, 'no shipped project references were checked'
}

// A reference that misses from the project's directory and names a file only from the working
// directory is said, with the spelling that names it from the project (#494); nothing is said
// for one that resolves from the project, resolves nowhere, or is absolute.
fn test_a_reference_resolving_only_from_the_working_directory_is_said() {
	root := asset_tree()!
	was := os.getwd()
	defer {
		os.chdir(was) or {}
		os.rmdir_all(root) or {}
	}
	os.chdir(root)!
	proj := os.join_path(root, 'proj')
	note := cwd_only_note(proj, 'dbc/x.dbc') or { panic('no note') }
	assert note.starts_with('`dbc/x.dbc` resolves only from the folder the program was started in')
	assert note.ends_with('write it relative to the project file (`../dbc/x.dbc`)')
	// the suggestion names the file from the project
	assert same_file(resolve_asset(proj, '../dbc/x.dbc'), os.join_path(root, 'dbc', 'x.dbc'))
	// a fragment rides along
	n2 := cwd_only_note(proj, 'net.arxml#Body') or { panic('no note') }
	assert n2.ends_with('(`../net.arxml#Body`)')
	assert cwd_only_note(proj, 'sub/m.csv') == none // resolves from the project
	assert cwd_only_note(proj, 'dbc/missing.dbc') == none // resolves nowhere
	assert cwd_only_note(proj, os.join_path(root, 'dbc', 'x.dbc')) == none
	assert cwd_only_note('', 'dbc/x.dbc') == none // an unsaved project
	// a spelling the project-relative lookup cannot read back is given absolute
	$if !windows {
		os.write_file(root + '/dbc/a\\b.dbc', '')!
		n3 := cwd_only_note(proj, 'dbc/a\\b.dbc') or { panic('no note') }
		assert n3.ends_with('(`${root}/dbc/a\\b.dbc`)')
	}
	// once per reference, every kind of reference, the first channel naming it
	p := Project{
		channels: [
			Channel{
				name:      'CAN1'
				databases: ['dbc/x.dbc', 'sub/m.csv']
			},
			Channel{
				name:      'CAN2'
				databases: ['dbc/x.dbc']
				manifest:  'proj/sub/m.csv'
			},
		]
	}
	notes := p.reference_notes(proj, [])
	assert notes.len == 2
	assert notes[0].starts_with('CAN1: `dbc/x.dbc`')
	assert notes[1].starts_with('CAN2: `proj/sub/m.csv`')
	assert notes[1].ends_with('(`sub/m.csv`)')
	assert p.reference_notes(proj, ['dbc/x.dbc']).len == 1 // what the caller already said
	// project.load says them; started from the project's own folder nothing is said
	pf := os.join_path(proj, 'p.blobnet')
	os.write_file(pf, 'project:\n  name: t\nchannels:\n  - name: CAN1\n    interface: inproc:CAN1\n    databases: [dbc/x.dbc]\n')!
	loaded := load(pf)!
	assert loaded.notes.len == 1 && loaded.notes[0].contains('`dbc/x.dbc` resolves only from')
	os.chdir(proj)!
	assert load(pf)!.notes == []
}
