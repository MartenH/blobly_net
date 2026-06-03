#!/usr/bin/env bash
# One-shot bootstrap for a FRESH machine — tested target: Ubuntu 24.04 LTS on WSL2.
# Installs the V toolchain, vlang/gui native deps, can-utils, builds CANTester,
# brings up vcan0, and runs the tests. Idempotent-ish; safe to re-run.
# Needs sudo (will prompt unless you've set up passwordless sudo).
#
# WHY 24.04: Ubuntu 22.04's Mesa 23.2 crashes the GPU on our sokol (GL core
# profile) hardware-GL path; 24.04 ships Mesa 24.x which should fix it. See
# docs/known_issues.md. After setup, test hardware GL with:
#     CANTESTER_SOFTWARE_GL=0 ./scripts/run.sh
# If that renders without a GPU reset, flip run.sh's default to hardware.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> 1/6 System + native GUI/build deps (vglyph text-shaping + sokol GL/X11)"
sudo apt-get update
sudo apt-get install -y \
	build-essential git pkg-config python3 \
	libfreetype-dev libharfbuzz-dev libfribidi-dev libfontconfig1-dev \
	libpango1.0-dev libglib2.0-dev libdbus-1-dev libatk1.0-dev \
	libatk-bridge2.0-dev libatspi2.0-dev libgl1-mesa-dev libx11-dev \
	libxcursor-dev libxrandr-dev libxinerama-dev libasound2-dev \
	can-utils \
	mesa-utils xdotool imagemagick x11-utils   # diagnostics + screenshot verification

echo "==> 2/6 V compiler (built from source)"
if [ ! -x "$HOME/v/v" ]; then
	git clone --depth=1 https://github.com/vlang/v "$HOME/v"
	make -C "$HOME/v"
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$HOME/v/v" "$HOME/.local/bin/v"
export PATH="$HOME/.local/bin:$PATH"
"$HOME/v/v" version
# Last known-good: V 0.5.1 (commit 4dbcba6). If newer V breaks the build, pin it:
#   ( cd ~/v && git fetch --tags && git checkout 0.5.1 && make )

echo "==> 3/6 vlang/gui module (pulls vglyph automatically)"
"$HOME/v/v" install gui
# Last known-good gui commit: 68b9302 (2026-05-11). If newer gui breaks, pin it:
#   ( cd ~/.vmodules/gui && git fetch && git checkout 68b9302 )

echo "==> 4/6 Build + test"
"$HOME/v/v" -path "@vlib|@vmodules|modules" -o build/cantester src/main.v
"$HOME/v/v" test modules/candb/

echo "==> 5/6 Virtual CAN bus (vcan0)"
# CAN is built into the WSL2 kernel (CONFIG_CAN_VCAN=y) — no modprobe needed.
./scripts/setup_vcan.sh || echo "  (vcan0 setup needs sudo; the kernel must have CONFIG_CAN_VCAN)"

cat <<'EOF'
==> 6/6 Done. Run it:
  software GL : ./scripts/run.sh
  HARDWARE GL : CANTESTER_SOFTWARE_GL=0 ./scripts/run.sh   <-- try this first on 24.04!
  with SUT    : python3 sut/can_sut.py vcan0   (in another terminal)
  VS Code     : Tasks -> "CAN: SUT + Tester", or F5 to debug

If hardware GL renders cleanly (no black screen / GPU reset), edit scripts/run.sh
to default CANTESTER_SOFTWARE_GL=0. If it still crashes, keep software GL and note
it in docs/known_issues.md.
EOF
