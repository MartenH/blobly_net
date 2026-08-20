# Shared by setup_vcan.sh and build_vcan_module.sh. Sourced, not executed.
#
# ONE ANSWER PER QUESTION. These four questions — whose home, where the marker is, can we use
# sudo, is vcan available — were each answered independently in the two scripts, and every codex
# round on net#122 found another place where the two answers had drifted apart: a marker written
# under one path and read under another, a capability probe corrected in one script and left
# wrong in the other (which then tried to compile a kernel). "A policy that now lives in two
# places" is the failure this repo's guide names; the fix is for it to live in one.

# WHOSE HOME. Under `sudo`, $HOME is root's, and every per-user path derived from it points
# somewhere the invoking user cannot see and did not mean. Whole-script sudo is tolerated on both
# scripts, so both need this.
vcan_user_home() {
	if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
		_h="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
		[ -n "$_h" ] && { printf '%s\n' "$_h"; return 0; }
	fi
	printf '%s\n' "$HOME"
}

# WHERE THE MARKER IS: the tree build_vcan_module.sh last built a module in, recorded for
# setup_vcan.sh and for the next build. Per-MACHINE under the invoking user's home, never in the
# repo — the path is one machine's fact, and a repo-relative file is per-CHECKOUT, invisible from
# the `.claude/worktrees/*` this project works in by convention.
#
# XDG_CACHE_HOME IS DELIBERATELY NOT HONOURED, and that is the point rather than an oversight.
# Both scripts are run both ways — plainly, and through `sudo` — and sudo's `env_reset` strips
# XDG_CACHE_HOME, so a path that consulted it would resolve to the user's directory in one
# context and to `~/.cache` in the other. A marker whose entire job is to be FOUND AGAIN, by the
# other script, in a later session, possibly across that boundary, has to be one path. An earlier
# version of this function branched on privilege and honoured XDG on only one side; a tree
# recorded by a normal build was then invisible to `sudo ./scripts/setup_vcan.sh` (codex #122 r6)
# — the same divergence this file exists to eliminate, reintroduced inside it.
vcan_marker_path() {
	printf '%s\n' "$(vcan_user_home)/.cache/blobly_net/vcan_module_src"
}

vcan_default_src() { printf '%s\n' "$(vcan_user_home)/repos/WSL2-Linux-Kernel"; }

# CAN WE RUN `ip` UNDER SUDO WITHOUT A PROMPT? Asked with a read-only `ip`, deliberately: the
# sudoers rule this project installs is scoped to four commands, so `sudo -n true` is DENIED on a
# correctly configured machine and would report the opposite of the truth. `sudo -n` alone cannot
# tell an authorisation failure from the probed command failing (its own --help says so), which
# is why the two are asked separately.
vcan_sudo_ip_ok() { sudo -n ip link show >/dev/null 2>&1; }

# IS VCAN AVAILABLE?  0 = yes · 1 = no · 2 = cannot tell (no privilege to ask)
#
# Answered free and without root wherever possible. `lsmod` and `modinfo` answer a NARROWER
# question and get it wrong on a kernel built with CONFIG_CAN_VCAN=y: a built-in vcan is in no
# lsmod listing and such a build often ships no /lib/modules tree for modinfo to search, while
# `ip link add type vcan` works perfectly. Reading that as "vcan is missing" is how these scripts
# talked themselves into compiling an entire kernel on a machine that already had it.
#
# 2 IS NOT 1. A probe we were not allowed to run says nothing about the kernel, and collapsing it
# into "unsupported" turns a missing sudoers rule into a tens-of-minutes build.
#
# Split in two on purpose. The FREE half needs no root and changes nothing, so every mode may ask
# it — including `--build`, whose promise is only that it will not touch the running system, not
# that it will refuse to look. The privileged half creates and removes a device, so `--build`
# never reaches it.
vcan_available_free() {
	[ -n "$(ip -brief link show type vcan 2>/dev/null)" ] && return 0
	# Process substitution, NOT a pipe: under `set -o pipefail` a matching `grep -q` closes the
	# pipe, zcat dies of SIGPIPE, and the pipeline reports failure — the check then answers "no"
	# exactly when the answer is yes.
	grep -q '^CONFIG_CAN_VCAN=y' <(zcat /proc/config.gz 2>/dev/null) && return 0
	grep -qs 'vcan\.ko' "/lib/modules/$(uname -r)/modules.builtin" && return 0
	return 1
}

vcan_available() {
	vcan_available_free && return 0
	vcan_sudo_ip_ok || return 2
	sudo -n ip link add dev vcanprobe type vcan >/dev/null 2>&1 || return 1
	sudo -n ip link del vcanprobe >/dev/null 2>&1 || true
	return 0
}

# The remedy for a 2, said the same way by both scripts.
vcan_say_no_privilege() {
	echo "[vcan] cannot run 'ip' under sudo without a password, so whether this kernel supports"
	echo "[vcan] vcan cannot be determined — and that is NOT the same as it being unavailable."
	echo "[vcan] install the scoped rule:  sudo ./scripts/setup_sudoers.sh"
}
