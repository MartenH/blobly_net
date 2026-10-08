// mutrefs: refuse the two V spellings that COPY a `mut` receiver (docs/known_issues.md, #406) —
// `x := &recv` and a closure `fn [recv]` inside a `fn (mut recv T)` method. The compiler accepts
// both, and the copy's own mutex over the caller's maps crashed the Diagnostics panel after #402.
//
//   mutrefs [dir-or-file ...]   default: cmd modules; *_test.v files are skipped
//
// Exit 1 with `file:line: ...` per finding, 2 when the check itself cannot be made (a path that
// is not a .v file or directory, a file the parser refuses, a spelling the walk did not reach).
module main

import os
import mutscan

fn main() {
	roots := if os.args.len > 1 { os.args[1..] } else { ['cmd', 'modules'] }
	mut files := []string{}
	for r in roots {
		if os.is_dir(r) {
			files << os.walk_ext(r, '.v').filter(!it.ends_with('_test.v'))
		} else if os.is_file(r) && r.ends_with('.v') {
			files << r
		} else {
			eprintln('mutrefs: ${r}: not a .v file or a directory')
			exit(2)
		}
	}
	files.sort()
	mut n := 0
	mut broken := false
	for f in files {
		found := mutscan.scan_file(f) or {
			eprintln(err.msg())
			broken = true
			continue
		}
		for x in found {
			println(x.str())
		}
		n += found.len
	}
	if broken {
		exit(2)
	}
	if n > 0 {
		exit(1)
	}
	println('check_mut_refs: no copied mut receivers')
}
