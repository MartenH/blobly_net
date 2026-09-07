# Shared answers for installing the PINNED V toolchain — sourced by scripts/setup_env.sh,
# tested by scripts/v_toolchain_test.sh.
#
# WHY THIS FILE EXISTS. Three review rounds on #285 found the same shape three times: a check
# on the STATE OF THE INPUTS standing in for "this was successfully built".
#
#   1. `.v-version` pinned V's source, and that was read as "the toolchain is pinned" — while
#      `make` cloned the vlang/vc bootstrap with no ref. It behaved like a pin only while vc's
#      default branch happened to hold our bootstrap, and the morning that stopped, every
#      branch broke with nothing in the repo changed.
#   2. `-x $HOME/v/v` plus "the checkout is at V_PIN" was read as "already built" — but a run
#      whose `make` failed leaves exactly that state with the PREVIOUS binary in place.
#   3. Adding the vc HEAD to that predicate did not fix it, because `pin_vc` moves vc BEFORE
#      `make` runs: a failed build leaves BOTH pins satisfied and the stale binary in place.
#
# Each fix moved the goalposts and kept the shape. So the predicate is no longer about the
# inputs at all: a build writes a STAMP naming the exact pins it built from, and it writes it
# only after `make` has succeeded. Nothing else is evidence that a build happened.
#
# CLAUDE.md's rule for findings that repeat in one path is to cover the path rather than keep
# patching cases, which is what v_toolchain_test.sh is for.

# v_toolchain_stamp_path <vdir> — where the success stamp lives.
# Inside the V checkout on purpose: delete the checkout and the claim goes with it.
v_toolchain_stamp_path() {
	printf '%s\n' "$1/.blobly_built_from"
}

# v_toolchain_want_stamp <v_pin> <vc_pin> — the stamp content these pins ask for.
v_toolchain_want_stamp() {
	printf '%s %s\n' "$1" "$2"
}

# v_toolchain_build_reason <vdir> <v_pin> <vc_pin> — why a build is needed, or empty if not.
#
#   missing  no v executable there at all
#   notgit   something is there, but it is not a checkout we can move to the pin
#   stale    no stamp, or a stamp naming different pins — INCLUDING the case where both repos
#            already sit at the pins because a previous run got that far and then failed
#
# Pure function of the filesystem, which is what makes it testable.
v_toolchain_build_reason() {
	vdir=$1
	v_pin=$2
	vc_pin=$3
	if [ ! -x "$vdir/v" ]; then
		printf 'missing\n'
		return 0
	fi
	if ! git -C "$vdir" rev-parse --git-dir >/dev/null 2>&1; then
		printf 'notgit\n'
		return 0
	fi
	want=$(v_toolchain_want_stamp "$v_pin" "$vc_pin")
	have=$(cat "$(v_toolchain_stamp_path "$vdir")" 2>/dev/null || true)
	if [ "$have" != "$want" ]; then
		printf 'stale\n'
		return 0
	fi
	printf '\n'
}

# v_toolchain_install <vdir> <v_pin> <vc_pin> — fetch both pins and build.
#
# The stamp is written LAST, after both `make` invocations have succeeded. Under the callers'
# `set -e` a failing make ends the script with no stamp written, so the next run rebuilds
# rather than proceeding on a compiler nobody verified.
v_toolchain_install() {
	vdir=$1
	v_pin=$2
	vc_pin=$3

	# A stamp from a previous build is not evidence about this one.
	rm -f "$(v_toolchain_stamp_path "$vdir")"

	# re-runnable: a fetch that failed once leaves the init behind, and `remote add` on it fails
	if [ ! -e "$vdir/.git" ]; then
		git init -q "$vdir"
	fi
	git -C "$vdir" remote add origin https://github.com/vlang/v 2>/dev/null \
		|| git -C "$vdir" remote set-url origin https://github.com/vlang/v
	git -C "$vdir" fetch -q --depth=1 origin "$v_pin"
	git -C "$vdir" checkout -q FETCH_HEAD

	# The bootstrap, at the vc commit GENERATED FROM $v_pin. Pinning the source without this
	# is not a pin: `make` would clone vc's default branch, and `latest_vc` would then
	# `git clean -xf && git pull --rebase` whatever we put there.
	if [ ! -e "$vdir/vc/.git" ]; then
		git init -q "$vdir/vc"
	fi
	git -C "$vdir/vc" remote add origin https://github.com/vlang/vc 2>/dev/null \
		|| git -C "$vdir/vc" remote set-url origin https://github.com/vlang/vc
	git -C "$vdir/vc" fetch -q --depth=1 origin "$vc_pin"
	git -C "$vdir/vc" checkout -q FETCH_HEAD

	# tcc FIRST and WITHOUT local=1: that flag turns off latest_tcc too, and V keeps its
	# bundled libgc.a in thirdparty/tcc/lib — without it the build completes and then fails
	# linking libgc in `v run cmd/tools/detect_tcc.v`. tcc stays floating, as it always was.
	make -C "$vdir" latest_tcc
	# local=1 makes latest_vc/latest_tcc/latest_legacy no-ops (`ifndef local`), so nothing is
	# pulled out from under the pinned bootstrap mid-build.
	make -C "$vdir" local=1

	v_toolchain_want_stamp "$v_pin" "$vc_pin" > "$(v_toolchain_stamp_path "$vdir")"
}
