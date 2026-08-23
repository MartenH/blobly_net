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

echo "==> 2/5 V compiler (built from source)"
if [ ! -x "$HOME/v/v" ]; then
	git clone --depth=1 https://github.com/vlang/v "$HOME/v"
	make -C "$HOME/v"
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
