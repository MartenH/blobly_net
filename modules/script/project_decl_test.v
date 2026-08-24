module script

import os

fn test_a_script_declares_the_project_it_needs() {
	d := declaration_in('-- DoIP announcement behaviour\n-- @project ../projects/doip-announce-demo.blobnet\n\nlocal t = require("test")\n',
		'tests/doip_announce.lua') or {
		assert false, 'the declaration was not found'
		return
	}
	assert d.raw == '../projects/doip-announce-demo.blobnet'
	assert d.script == 'tests/doip_announce.lua'
	// resolved against the SCRIPT's directory, so it works from any working directory
	assert os.norm_path(d.path) == os.norm_path('projects/doip-announce-demo.blobnet')
}

fn test_a_script_that_declares_nothing_declares_nothing() {
	if _ := declaration_in('-- just an ordinary test\nlocal t = require("test")\n', 'tests/x.lua') {
		assert false, 'invented a declaration'
	}
}

// Only the leading comment block. A directive further down would let a line buried in the middle
// of a test silently redirect the whole run, and every file would have to be read to the end to
// rule that out.
fn test_a_directive_below_the_header_is_not_a_declaration() {
	text := '-- header\nlocal t = require("test")\n-- @project ../projects/other.blobnet\n'
	if _ := declaration_in(text, 'tests/x.lua') {
		assert false, 'took a directive from below the header'
	}
}

fn test_blank_lines_inside_the_header_do_not_end_it() {
	d := declaration_in('-- title\n\n-- @project ../projects/p.blobnet\n', 'tests/x.lua') or {
		assert false, 'a blank line ended the header'
		return
	}
	assert d.raw == '../projects/p.blobnet'
}

fn test_a_directive_with_no_path_declares_nothing() {
	if _ := declaration_in('-- @project\nlocal t = 1\n', 'tests/x.lua') {
		assert false, 'accepted an empty declaration'
	}
}

fn test_nothing_declared_leaves_the_caller_its_default() {
	assert agree([], '')! == ''
	assert agree([], 'projects/sim-demo.blobnet')! == 'projects/sim-demo.blobnet'
}

fn test_one_declaration_chooses_the_project() {
	d := Decl{
		script: 'tests/a.lua'
		raw:    '../projects/p.blobnet'
		path:   'projects/p.blobnet'
	}
	assert agree([d], '')! == 'projects/p.blobnet'
}

fn test_scripts_that_agree_are_not_a_conflict() {
	a := Decl{
		script: 'tests/a.lua'
		raw:    '../projects/p.blobnet'
		path:   'projects/p.blobnet'
	}
	// the same file by another spelling — two spellings of one path are not a disagreement
	b := Decl{
		script: 'tests/b.lua'
		raw:    '../projects/./p.blobnet'
		path:   'projects/./p.blobnet'
	}
	assert agree([a, b], '')! == 'projects/p.blobnet'
}

// One run brings up one project, so this cannot be honoured — and the refusal has to name both
// scripts, or the reader has to go and find which two of the eight disagreed.
fn test_scripts_needing_different_projects_are_refused() {
	a := Decl{
		script: 'tests/a.lua'
		raw:    '../projects/p.blobnet'
		path:   'projects/p.blobnet'
	}
	b := Decl{
		script: 'tests/b.lua'
		raw:    '../projects/q.blobnet'
		path:   'projects/q.blobnet'
	}
	agree([a, b], '') or {
		assert err.msg().contains('tests/a.lua')
		assert err.msg().contains('tests/b.lua')
		assert err.msg().contains('run them separately')
		return
	}
	assert false, 'ran two scripts that need different projects'
}

// The whole point of #115: a --project that contradicts the test produces failures that read as
// broken features. It is refused rather than obeyed.
fn test_an_explicit_project_contradicting_the_declaration_is_refused() {
	d := Decl{
		script: 'tests/doip_announce.lua'
		raw:    '../projects/doip-announce-demo.blobnet'
		path:   'projects/doip-announce-demo.blobnet'
	}
	agree([d], 'projects/sim-demo.blobnet') or {
		assert err.msg().contains('tests/doip_announce.lua')
		assert err.msg().contains('doip-announce-demo.blobnet')
		return
	}
	assert false, 'ran a test against a project it says it cannot use'
}

fn test_an_explicit_project_matching_the_declaration_is_fine() {
	d := Decl{
		script: 'tests/a.lua'
		raw:    '../projects/p.blobnet'
		path:   'projects/p.blobnet'
	}
	assert agree([d], './projects/p.blobnet')! == './projects/p.blobnet'
}
