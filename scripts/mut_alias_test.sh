#!/usr/bin/env bash
# mut_alias_test.sh — fixtures for scripts/mut_alias.awk: what is a copy under V3, and what is not.
set -u
cd "$(dirname "$0")/.." || exit 2
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cat >"$t/fix.v" <<'EOF'
module main

fn (mut app App) receiver_copy() {
	ap := app
	mut bp := app // a trailing comment does not hide it
	cp = app
	ok1 := &app
	mut ok2 := unsafe { app }
	snap := app // copy: a snapshot, on purpose
	spawn fn (app &App) {
		mut fine := app
		fine.n++
	}(app)
}

fn param_copy(mut app App, n int) {
	a := app
	b := n
}

fn (app &App) pointer_receiver() {
	a := app
}

fn (mut s Stats) other_type() {
	c := s
}

fn multiline(path string,
	mut log Log, mut names []string) {
	snapshot := log
}

fn (mut app App) after_a_literal() {
	spawn fn (app &App) {
		inner := app
	}(app)
	later := app
}
EOF
got=$(awk -f scripts/mut_alias.awk "$t/fix.v" | sed "s|^$t/||")
want='fix.v:4: 	ap := app
fix.v:5: 	mut bp := app // a trailing comment does not hide it
fix.v:6: 	cp = app
fix.v:17: 	a := app
fix.v:26: 	c := s
fix.v:31: 	snapshot := log
fix.v:38: 	later := app'
if [ "$got" = "$want" ]; then
	echo "mut_alias_test: ok"
	exit 0
fi
echo "mut_alias_test: FAIL"
echo "--- want"
echo "$want"
echo "--- got"
echo "$got"
exit 1
