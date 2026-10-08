#!/bin/sh
# check_mut_refs.sh — refuse the two spellings that COPY a `mut` receiver in V (docs/known_issues.md).
#
# Inside `fn (mut app App) f()`, `ap := &app` binds a COPY of the struct, and so does a closure
# capturing it by value, `fn [app] ...`; `a := app` (a reference) and `fn [mut app]` do not. A copy
# handed to anything that outlives the call carries its own mutex over the caller's maps — the
# Diagnostics panel crash after #402. The compiler accepts both, and the GUI has no tests, so this
# is what stops the next one. Run by check_cmds.sh, so CI runs it on both jobs.
#
# The check is cmd/mutrefs, a walk over V's own parse of every non-test file in cmd/ and modules/
# (#406): a line-based scan read `//` inside a string as a comment, `== &app` as a binding, and
# skipped a one-line method body. Exit 1 lists `file:line: ...`; 2 is the check itself failing
# (the tool did not build, a file the parser refused, a path that is not a .v file or directory).
#
#   V=/path/to/v   the compiler (default: `v` on PATH)
set -u
V="${V:-v}"
cd "$(dirname "$0")/.." || exit 2
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
# gcc, as run_gui.sh builds: the Windows job's prebuilt V drives mingw gcc and nothing else
if ! "$V" -cc gcc -enable-globals -o "$tmp/mutrefs" cmd/mutrefs; then
	echo 'check_mut_refs: cmd/mutrefs did not build' >&2
	exit 2
fi
"$tmp/mutrefs" cmd modules
