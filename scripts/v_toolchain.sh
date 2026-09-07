# Shared answers for installing the PINNED V toolchain — sourced by scripts/setup_env.sh,
# tested by scripts/v_toolchain_test.sh.
#
# WHY THIS FILE EXISTS. #285 found the same shape four rounds running: a check that stands in
# for "this is the toolchain the pins name, and it was actually built".
#
#   1. `.v-version` pinned V's source, and that was read as "the toolchain is pinned" — while
#      `make` cloned the vlang/vc bootstrap with no ref. It behaved like a pin only while vc's
#      default branch happened to hold our bootstrap, and the morning that stopped, every
#      branch broke with nothing in the repo changed.
#   2. `-x $HOME/v/v` plus "the checkout is at V_PIN" was read as "already built" — but a run
#      whose `make` failed leaves exactly that state with the PREVIOUS binary in place.
#   3. Adding the vc HEAD to that predicate did not fix it either, because the pins are moved
#      BEFORE `make` runs: a failed build leaves both pins satisfied and the stale binary.
#   4. Replacing the HEAD checks with a build stamp fixed 2 and 3 and broke 1 again — the stamp
#      is untracked, so an ordinary `git checkout` in $HOME/v moves the source out from under it
#      and leaves the claim behind.
#
# So it takes BOTH kinds of evidence, and neither is sufficient alone:
#   * the HEADs say the trees are the ones the pins name — which a manual checkout can change;
#   * the STAMP says a build over exactly those pins SUCCEEDED — which a failed `make` cannot
#     fake, because it is written last.

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
#   stale    either tree is not at its pin, or no stamp names exactly these two pins
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
	# The trees, because a stamp is untracked and survives an ordinary checkout.
	if [ "$(git -C "$vdir" rev-parse HEAD 2>/dev/null || true)" != "$v_pin" ]; then
		printf 'stale\n'
		return 0
	fi
	if [ "$(git -C "$vdir/vc" rev-parse HEAD 2>/dev/null || true)" != "$vc_pin" ]; then
		printf 'stale\n'
		return 0
	fi
	# And the stamp, because both trees sit at their pins from the moment they are fetched —
	# well before `make` has had a chance to fail.
	want=$(v_toolchain_want_stamp "$v_pin" "$vc_pin")
	have=$(cat "$(v_toolchain_stamp_path "$vdir")" 2>/dev/null || true)
	if [ "$have" != "$want" ]; then
		printf 'stale\n'
		return 0
	fi
	printf '\n'
}

# v_toolchain_fetch_pin <dir> <url> <sha> — put <dir> at <sha> from <url>.
#
# Fetched BY URL, with no remote configured and none touched. `git remote set-url origin` would
# permanently rewrite the remote of anyone using a fork or a corporate mirror — and this runs
# against a pre-existing checkout whenever the stamp is missing, so it is not a rare path.
v_toolchain_fetch_pin() {
	dir=$1
	url=$2
	sha=$3
	if [ ! -e "$dir/.git" ]; then
		git init -q "$dir"
	fi
	git -C "$dir" fetch -q --depth=1 "$url" "$sha"
	git -C "$dir" checkout -q FETCH_HEAD
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

	v_toolchain_fetch_pin "$vdir" https://github.com/vlang/v "$v_pin"
	# The bootstrap, at the vc commit GENERATED FROM $v_pin. Pinning the source without this
	# is not a pin: `make` would clone vc's default branch, and `latest_vc` would then
	# `git clean -xf && git pull --rebase` whatever we put there.
	v_toolchain_fetch_pin "$vdir/vc" https://github.com/vlang/vc "$vc_pin"

	# tcc FIRST and WITHOUT local=1: that flag turns off latest_tcc too, and V keeps its
	# bundled libgc.a in thirdparty/tcc/lib — without it the build completes and then fails
	# linking libgc in `v run cmd/tools/detect_tcc.v`. tcc stays floating, as it always was.
	make -C "$vdir" latest_tcc
	# local=1 makes latest_vc/latest_tcc/latest_legacy no-ops (`ifndef local`), so nothing is
	# pulled out from under the pinned bootstrap mid-build.
	make -C "$vdir" local=1

	v_toolchain_want_stamp "$v_pin" "$vc_pin" > "$(v_toolchain_stamp_path "$vdir")"
}
