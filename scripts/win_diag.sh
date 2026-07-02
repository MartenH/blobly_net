#!/bin/bash
# win_diag.sh — diagnose the native-Windows build hang. RUN IN THE MINGW64 SHELL:
#
#   cd /c/dev/blobly_net && bash scripts/win_diag.sh
#
# Captures everything to win_diag.log. Paste that log back. It answers the one
# question we can't see from Linux: is the hang in V's CODEGEN or in GCC?
#
# Context (what we know): on Linux this whole app builds in ~3.4s. The runtime
# memory leak is the V capturing-closure-context leak, fixed by a small RUNTIME
# patch (closure-gc-leak-fix.patch) — it does NOT affect build time. `-skip-unused`
# is a no-op (already the default; generated C is byte-identical). So the Windows
# build hang is Windows-specific and separate from the leak fix.
set +e
LOG=win_diag.log
: > "$LOG"
log() { echo "$@" | tee -a "$LOG"; }
run() { echo "\$ $*" | tee -a "$LOG"; "$@" 2>&1 | tee -a "$LOG"; }

log "==================== blobly_net Windows build diagnostic ===================="
run date

log ""
log "==== toolchain versions + working-tree patch state ===="
log "-- V (want: de365a1 + closure-gc-leak-fix.patch applied) --"
run git -C /c/dev/v log -1 --oneline
run git -C /c/dev/v diff --stat
run /c/dev/v/v.exe version
log "-- gui (want: 68b9302 + reclaim + win patches) --"
run git -C /c/dev/vmodules-ct/gui log -1 --oneline
run git -C /c/dev/vmodules-ct/gui diff --stat
log "-- vglyph (want: 5685a6d + empty-outline patch) --"
run git -C /c/dev/vmodules-ct/vglyph log -1 --oneline
log "-- markdown (want: ef2f101) --"
run git -C /c/dev/vmodules-ct/markdown log -1 --oneline
log "-- gcc --"
run bash -c 'gcc --version | head -1'

cd /c/dev/blobly_net || { log "ERROR: not in /c/dev/blobly_net"; exit 1; }
mkdir -p build

log ""
log "==== PHASE 1: C GENERATION ONLY (no gcc). Should take seconds. ===="
log "   exit 124 = TIMED OUT = V's codegen is the hang (=> use de365a1)."
log "   fast + a build/gen.c file = codegen is FINE, the hang is gcc (Phase 2)."
run bash -c "time timeout 300 /c/dev/v/v.exe -enable-globals -path '@vlib|@vmodules|modules' -o build/gen.c src/main.v"
log "cgen exit=$?"
run bash -c "ls -la build/gen.c 2>/dev/null | awk '{print \$5, \$9}'"

log ""
log "==== PHASE 2: FULL BUILD (cgen + gcc), 20-min cap, -showcc ===="
log "   -showcc prints the gcc command V runs. If you SEE that line then it stalls,"
log "   the hang is gcc. exit 124 = timed out. exit 0 = it actually builds (just slow)."
mingw=/c/dev/msys64-ct/mingw64
export VMODULES=/c/dev/vmodules-ct
export PKG_CONFIG_PATH="$mingw/lib/pkgconfig"
export PATH="$mingw/bin:$PATH"
libs='freetype2 harfbuzz fribidi fontconfig pango pangoft2 gobject-2.0 glib-2.0'
cflags=$(pkgconf --cflags $libs)
ldflags="$(pkgconf --libs $libs) -ld3d11 -ldxgi"
run bash -c "time timeout 1200 /c/dev/v/v.exe -cc gcc -enable-globals -showcc -path '@vlib|@vmodules|modules' -cflags \"$cflags\" -ldflags \"$ldflags\" -o build/blobly_net.exe src/main.v"
log "full build exit=$?  (124=timeout/hang, 0=OK)"
run bash -c "ls -la build/blobly_net.exe 2>/dev/null | awk '{print \$5, \$9}'"

log ""
log "==================== DONE — paste win_diag.log ===================="
log "While Phase 2 ran, note in Task Manager which process pegged a CPU core:"
log "  v.exe   -> V codegen (Phase 1 should have shown it too)"
log "  cc1.exe / gcc.exe -> the C compile (gcc) is the bottleneck"
log "  nothing / idle    -> a true deadlock (not just slow)"
