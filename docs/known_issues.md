# Known issues & gotchas (by layer)

Categorized so we always know **whose** problem a given symptom is — our code, the V compiler,
vlang/gui, the rendering stack, or the environment. Update as we hit (and fix) things.

Status key: 🔴 open · 🟡 worked around · 🟢 fixed · ⚪ benign/expected

---

## V language / compiler / tooling

- 🟡 **Local module not found.** `import candb` (a module under `./modules/`) fails with
  `cannot import module "candb" (not found)` when compiling a file in `cmd/…`. V's `-path`
  *replaces* the default lookup order, so the working incantation re-lists the defaults:
  `v -path "@vlib|@vmodules|modules" run <file>`. Baked into `scripts/run.sh`. Plain `v run`
  on a file that imports a local module will fail without it. (Tooling ergonomics, not a bug.)
- ⚪ `draw_canvas.version` is `u64` — passing an `int` errors (`cannot assign … expected u64`).
  Just cast: `version: u64(app.ticks)`.

## vlang/gui

- _None confirmed as gui bugs yet._ The data_grid, draw_canvas, animations, theming and live
  updates have all behaved per docs. (Keep this section honest — only real gui defects go here.)

## Rendering stack (sokol / vglyph / GL)

- 🟡 **Blank/black window under WSLg.** Default GPU GL passthrough (d3d12) draws frames but never
  composites — window shows blank despite thousands of frames drawn. Fix: force software GL
  `LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe` (in `scripts/run.sh`). sokol/WSLg interaction.
- ⚪ sokol `LINUX_X11_QUERY_SYSTEM_DPI_FAILED` on launch → falls back to 96 DPI. Harmless.
- 🟢 **vglyph/sokol need many native dev libs** that aren't installed by default (freetype,
  harfbuzz, fribidi, fontconfig, pango, glib, dbus, atk, atk-bridge, atspi, GL, X11). Resolved by
  installing the full set (listed in CLAUDE.md → System dependencies). Packaging friction, not code.

## Environment (WSL2 / kernel)

- 🔴 **`vcan` kernel module won't load** (`modprobe vcan` → `Exec format error`/ENOEXEC). The
  installed modules (built Jun 2 13:52) predate the running kernel (rebuilt Jun 2 20:34); with
  `CONFIG_MODVERSIONS` the symbol CRCs mismatch even though the version string matches. **Fix
  (user, on the kernel source tree):** `make modules && sudo make modules_install && sudo depmod -a`,
  then `sudo modprobe vcan`. Blocks live `vcan0` testing (Phase 2 end-to-end).

## Our code (cantester)

- 🟢 **`candb.encode` rounding bug.** `i64(x + 0.5)` truncated negatives toward zero (`-4.5 → -4`),
  so `encode(-5.0)` produced `-4`. Caught by `candb_test.v::test_signed_negative`. Fixed with
  `math.round` (round half away from zero). Reminder: keep testing module logic in isolation.
