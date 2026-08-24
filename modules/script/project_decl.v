// Which project does this test need?
//
// A Lua test runs against a project's simulation, and most of them work against any of the demo
// projects because they address channels every one of them has. Some do not: a test written for
// `doip-announce-demo` addresses channels named `Talker` and `Silent`, and against the default
// project those names exist nowhere.
//
// Run that way it does not report a configuration mistake — it reports THREE TEST FAILURES, one
// of them "unknown channel", which reads as a broken feature. Both DoIP tests looked exactly that
// broken on `main` (#115), and were not: CI passed them, because CI named each file WITH its
// project. Anyone running them any other way got three failures and no hint that the project was
// the reason, since the requirement lived in CI's argument list and in whoever's shell history
// had it right — everywhere except the test that has it.
//
// So the test states it, in its own head:
//
//     -- @project ../projects/doip-announce-demo.blobnet
//
// Relative to the SCRIPT, not the working directory — the path is written in the script, so it
// resolves from the script, and the declaration keeps working wherever the runner is invoked from.
//
// The runner then REFUSES a mismatch rather than running one: an explicit `--project` that
// contradicts the declaration, or two scripts in one invocation that need different projects.
// One environment is brought up per run, so the second case cannot be honoured — and a refusal
// that names both scripts is worth more than a pass whose meaning nobody can reconstruct.
module script

import os

// Decl is one script's stated requirement.
pub struct Decl {
pub:
	script string // the script that declared it
	raw    string // exactly as written, for messages — the reader has to find it in the file
	path   string // resolved against the script's own directory
}

// declaration_in reads the directive out of a script's text. Separate from the file so the rule
// is testable without one.
//
// Only the LEADING comment block is scanned. A directive is a statement about the whole script
// and belongs at the top; allowing one anywhere would mean a line buried in the middle of a test
// could silently redirect the entire run, and scanning to the end of every file to find that out.
pub fn declaration_in(text string, script_path string) ?Decl {
	for line in text.split_into_lines() {
		t := line.trim_space()
		if t == '' {
			continue // blank lines inside the header block are fine
		}
		if !t.starts_with('--') {
			break // code has started; the header is over
		}
		body := t.trim_left('-').trim_space()
		if !body.starts_with('@project') {
			continue
		}
		raw := body.all_after('@project').trim_space()
		if raw == '' {
			continue // `-- @project` with nothing after it declares nothing
		}
		return Decl{
			script: script_path
			raw:    raw
			path:   os.norm_path(os.join_path(os.dir(script_path), raw))
		}
	}
	return none
}

// declaration_of reads the script and returns what it declares, if anything. An unreadable file
// declares nothing — the runner is about to fail on it for a better reason.
pub fn declaration_of(script_path string) ?Decl {
	text := os.read_file(script_path) or { return none }
	return declaration_in(text, script_path)
}

// agree resolves the project to load from what the scripts declare and what the caller asked for.
// It returns '' when nothing is declared and the caller should keep its default.
//
// `explicit` is the `--project` argument, or '' if none was given. It does NOT win a
// disagreement: a script that declares a project is stating what it needs to mean anything, and
// silently running it against another is the failure this exists to prevent. Overriding is a
// matter of editing the declaration, which is the honest way to say the requirement changed.
pub fn agree(decls []Decl, explicit string) !string {
	mut want := Decl{}
	for d in decls {
		if want.path == '' {
			want = d
			continue
		}
		if !same_path(d.path, want.path) {
			return error(
				'these scripts need different projects, and one run brings up one project:\n' +
				'  ${want.script} needs ${want.raw}\n' + '  ${d.script} needs ${d.raw}\n' +
				'run them separately')
		}
	}
	if want.path == '' {
		return explicit // nothing declared: the caller's choice, or its default
	}
	if explicit != '' {
		if !same_path(explicit, want.path) {
			return error(
				'--project ${explicit} contradicts ${want.script}, which needs ${want.raw}\n' +
				'omit --project to use the declared one, or change the declaration')
		}
		return explicit // the same file, in the spelling the caller typed
	}
	return want.path
}

// same_path compares two paths as paths. Windows separators and `a/../b` both make two spellings
// of one file, and a comparison that misses that refuses a run that was perfectly consistent.
fn same_path(a string, b string) bool {
	return os.norm_path(os.abs_path(a)) == os.norm_path(os.abs_path(b))
}
