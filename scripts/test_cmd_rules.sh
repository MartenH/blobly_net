#!/usr/bin/env bash
# test_cmd_rules.sh — the GUI-local rule packages' tests: GUI policy with a test, pure V, no ImGui.
#
# Run from a COPY outside the repository, because these packages promise to import no blobly
# module (they take what they need from the caller), and that promise is what this run checks:
# in the repository V's upward module search from cmd/ reaches blobly/ beside v.mod, so a stray
# `import blobly.transport` would resolve and pass. Out here nothing but the standard library
# is reachable. Each package imports only vlib (no rule imports another), so
# each copies on its own. Extra arguments are V options, placed before `test` (e.g. -stats);
# V picks the compiler.
set -eu
cd "$(dirname "$0")/.."
rules=(
	cmd/blobly_net/saverule cmd/blobly_net/logfile cmd/blobly_net/taprule cmd/blobly_net/loadrule
	cmd/blobly_net/cyclerule cmd/blobly_net/drainrule cmd/blobly_net/genhome cmd/blobly_net/pickrule
	cmd/blobly_net/watchrule cmd/blobly_net/prefs cmd/blobly_net/panerule cmd/blobly_net/endrule
	cmd/blobly_net/gaterule cmd/blobly_net/txhealth cmd/blobly_net/diaghold cmd/blobly_net/foldrule
	cmd/vectorcheck/restorerule cmd/mutrefs/mutscan
)
repo=$(pwd -P)
iso=$(mktemp -d)
trap 'rm -rf "$iso"' EXIT
# OUTSIDE the repository, whatever TMPDIR says: a copy beneath v.mod reaches the modules again
case "$(cd "$iso" && pwd -P)/" in
"$repo"/*)
	echo "test_cmd_rules: the temporary directory $iso is inside the repository; set TMPDIR elsewhere" >&2
	exit 2
	;;
esac
names=()
for r in "${rules[@]}"; do
	n=$(basename "$r")
	cp -r "$r" "$iso/$n"
	names+=("$n")
done
cd "$iso"
# not exec: the EXIT trap removes the copy, and the status is the tests'
status=0
"${V:-v}" -enable-globals "$@" test "${names[@]}" || status=$?
exit "$status"
