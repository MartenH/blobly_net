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

echo "==> 2b/5 vlang/markdown (md4c) — Help panel 'Open in browser' renders docs to HTML"
if [ ! -d "$HOME/.vmodules/markdown" ]; then
	git clone --quiet https://github.com/vlang/markdown.git "$HOME/.vmodules/markdown"
	git -C "$HOME/.vmodules/markdown" checkout --quiet ef2f101
fi

echo "==> 3/5 Build the GUI (imgui C deps -> libvgui_c.a, then cmd/blobly_net)"
# run_gui.sh (RUN=0 = build only) builds libs/vgui/libvgui_c.a from the pinned cimgui/
# cimplot (via libs/vgui/build_deps.sh) and compiles cmd/blobly_net. No vlang/gui / vglyph
# / markdown — the imgui app doesn't use them (that GUI stack was retired at the migration).
RUN=0 ./scripts/run_gui.sh

echo "==> 4/5 Tests"
"$HOME/v/v" -enable-globals test modules/

echo "==> 5/5 Virtual CAN bus (vcan0)"
# CAN is built into the WSL2 kernel (CONFIG_CAN_VCAN=y) — no modprobe needed.
./scripts/setup_vcan.sh || echo "  (vcan0 setup needs sudo; the kernel must have CONFIG_CAN_VCAN)"

cat <<'EOF'
==> Done. Run it:
  GUI       : ./scripts/run_gui.sh
  with SUT  : python3 sut/can_sut.py vcan0        (in another terminal)
  headless  : scripts/runtests.sh tests/diag_basic.lua tests/bus_signals.lua
EOF
