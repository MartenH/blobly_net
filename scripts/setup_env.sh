#!/usr/bin/env bash
# One-shot bootstrap for a FRESH machine — tested target: Ubuntu 24.04 LTS on WSL2.
# Installs the V toolchain, the Dear ImGui GUI's native deps, can-utils, builds the app,
# brings up vcan0, and runs the tests. Idempotent-ish; safe to re-run.
# Needs sudo (will prompt unless you've set up passwordless sudo).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> 1/5 System + native GUI/build deps (imgui: g++ + GLFW + FreeType + GL)"
sudo apt-get update
sudo apt-get install -y \
	build-essential g++ git pkg-config python3 \
	libglfw3-dev libfreetype-dev libgl1-mesa-dev libx11-dev \
	can-utils \
	mesa-utils xdotool imagemagick x11-utils   # diagnostics + screenshot verification

echo "==> 2/5 V compiler (built from source, at the commits .v-version + .vc-version pin)"
# The SAME commit CI builds with (.v-version), not master: V master is V3-only since 2026-09-05
# and this repo does not build under V3, so a fresh machine that cloned master got a compiler
# that fails on the first `-old-compiler`. GitHub serves a fetch by full SHA, so one commit
# comes down and nothing else (codex on #282).
#
# And the BOOTSTRAP is pinned too (.vc-version), because pinning only the source is not a pin:
# `make` clones vlang/vc with no ref, and `latest_vc` then does `git clean -xf && git pull` on
# it. That floated to V3 master on 2026-09-07 and broke every build with `./v2: No such file or
# directory` -- a V3 bootstrap cannot build pre-V3 source under -old-compiler. `local=1` is what
# holds the pin: it turns latest_vc/latest_tcc/latest_legacy into no-ops (`ifndef local` in V's
# GNUmakefile), so nothing is pulled out from under us mid-build.
V_PIN=$(tr -d '[:space:]' < .v-version)
VC_PIN=$(tr -d '[:space:]' < .vc-version)

# vc, at the commit generated FROM $V_PIN, placed where make expects it before make runs
pin_vc() {
	if [ ! -d "$HOME/v/vc/.git" ]; then
		git init -q "$HOME/v/vc"
		git -C "$HOME/v/vc" remote add origin https://github.com/vlang/vc 2>/dev/null 			|| git -C "$HOME/v/vc" remote set-url origin https://github.com/vlang/vc
	fi
	git -C "$HOME/v/vc" fetch -q --depth=1 origin "$VC_PIN"
	git -C "$HOME/v/vc" checkout -q FETCH_HEAD
}
if [ ! -x "$HOME/v/v" ]; then
	# re-runnable: a fetch that failed once leaves the init behind, and `remote add` on it fails
	git init -q "$HOME/v"
	git -C "$HOME/v" remote add origin https://github.com/vlang/v 2>/dev/null \
		|| git -C "$HOME/v" remote set-url origin https://github.com/vlang/v
	git -C "$HOME/v" fetch -q --depth=1 origin "$V_PIN"
	git -C "$HOME/v" checkout -q FETCH_HEAD
	pin_vc
	make -C "$HOME/v" latest_tcc
	make -C "$HOME/v" local=1
elif ! git -C "$HOME/v" rev-parse --git-dir >/dev/null 2>&1; then
	echo "  $HOME/v is not a git checkout of vlang/v, so it cannot be moved to the pinned commit ${V_PIN:0:12}; remove it (or move it aside) and re-run" >&2
	exit 1
elif [ "$(git -C "$HOME/v" rev-parse HEAD)" != "$V_PIN" ]; then
	# an existing checkout at another commit is MOVED to the pin, not reported (codex on #282
	# round 3): left where it was, a bench that had built V3-only master went straight on to
	# fail the app build with it, and a pin bump never reached anyone who had run this before.
	# Local edits in ~/v stop the checkout, and this script with it, rather than being lost
	echo "  $HOME/v is at $(git -C "$HOME/v" rev-parse --short HEAD), not the pinned ${V_PIN:0:12} (.v-version); moving it there"
	git -C "$HOME/v" fetch -q --depth=1 origin "$V_PIN"
	git -C "$HOME/v" checkout -q "$V_PIN"
	pin_vc
	make -C "$HOME/v" latest_tcc
	make -C "$HOME/v" local=1
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$HOME/v/v" "$HOME/.local/bin/v"
export PATH="$HOME/.local/bin:$PATH"
"$HOME/v/v" version

echo "==> 3/5 Build the GUI (imgui C deps -> libvgui_c.a, then cmd/blobly_net)"
# run_gui.sh (RUN=0 = build only) builds libs/vgui/libvgui_c.a from the pinned cimgui/
# cimplot (via libs/vgui/build_deps.sh) and compiles cmd/blobly_net. Nothing to fetch into
# @vmodules: vlang/gui and vglyph went away with the migration, and vlang/markdown (the Help
# panel's 'Open in browser') is vendored in libs/markdown, which is already on -path.
RUN=0 ./scripts/run_gui.sh

echo "==> 4/5 Tests"
"$HOME/v/v" -enable-globals test modules/

echo "==> 5/5 Virtual CAN bus (vcan0)"
# NOT built into a stock WSL2 kernel: CONFIG_CAN_VCAN is unset there and no vcan.ko ships, so
# this step fails with "Unknown device type" until the module is built (docs/can_hardware.md).
# The in-process and UDP buses need none of this, so the tests above still pass without it.
./scripts/setup_vcan.sh || echo "  (no vcan0 — build the module once with ./scripts/build_vcan_module.sh, then
   ./scripts/setup_vcan.sh after each wsl restart; docs/can_hardware.md has the why)"

cat <<'EOF'
==> Done. Run it:
  GUI       : ./scripts/run_gui.sh
  with SUT  : python3 sut/can_sut.py vcan0        (in another terminal)
  headless  : scripts/runtests.sh tests/diag_basic.lua tests/bus_signals.lua
EOF
