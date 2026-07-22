# Known issues & gotchas

Things that cost real time, kept so they cost it once. Read this first when something breaks.

Status key: 🔴 open · 🟡 worked around · 🟢 fixed, kept for the reason · ⚪ benign/expected

> **Scope note.** This file used to be ~80% vlang/gui, sokol and vglyph material. That toolkit was
> retired for Dear ImGui + ImPlot (2026-07-06) and is not coming back, so that content was removed
> rather than left to send someone down a dead path. The old detail is in
> [`history.md`](history.md).

---

## V language / compiler / tooling

- 🟡 **Local module not found.** `import candb` (a module under `./modules/`) fails with
  `cannot import module "candb" (not found)` when compiling a file in `cmd/…`. V's `-path`
  *replaces* the default lookup order, so the working incantation re-lists the defaults:
  `v -path "@vlib|@vmodules|modules" run <file>`. Baked into `scripts/run_gui.sh`. Plain `v run`
  on a file that imports a local module will fail without it. (Tooling ergonomics, not a bug.)
- 🟡 **`v test` mangles a `-path` with `|`.** `v -path "@vlib|@vmodules|modules" test modules/`
  fails (`/bin/sh: @vmodules: not found`) because the test runner re-invokes `v` per file and the
  `|`-separated path leaks into a shell unquoted. Run `v -enable-globals test modules/` **without**
  `-path` — it resolves, and that is what CI does. When a module's test DOES need the local path,
  use a `:`-separated path, which survives the unquoted shell because `:` isn't a metachar:
  `v -path '@vlib:@vmodules:modules' test modules/mf4/mf4_test.v`.
- 🟡 **`-enable-globals` is not optional.** `modules/transport/inproc.v` uses `__global`, so every
  build, test and run that touches `transport` needs the flag.
- ⚪ **`cannot copy map: call move or clone`.** Assigning a `map` value into a struct field (e.g.
  `sig.values = vals`) errors — V won't implicitly copy a map. Use `vals.move()` (transfers
  ownership, cheap) or `vals.clone()` (deep copy) explicitly.
- 🟡 **C interop parse friction.** `&char(s.str)` casts and no-arg C funcs used inside an expression
  (`(x & C.mask()) | …`) both give `unexpected token )`. Fixes: pass `s.str` to a `&u8` C param;
  define stable C constants (e.g. CAN flag masks) as V `const`s instead of calling C accessors.
  For larger C surfaces prefer **c2v** over hand-writing; keep hand shims tiny (as in
  `modules/transport`, ~40 lines).

## GUI (Dear ImGui + ImPlot)

- 🟡 **The C++ glue links as a prebuilt archive, and V won't notice when it changes.** After
  editing `libs/vgui/{vgui.h,vgui_glue.cpp}` you MUST rebuild `libvgui_c.a`
  (`DEPS=1 scripts/run_gui.sh`), or you link a stale archive against a changed call signature — an
  instant segfault, not a link error. `run_gui.sh` auto-rebuilds when those sources are newer; a
  hand-written `v` invocation does not.
- ⚪ **All translation units must share one imgui config.** `IMGUI_DISABLE_OBSOLETE_FUNCTIONS`
  changes `sizeof(ImGuiIO)`; mixing it across objects aborts at startup with
  `Mismatched struct layout!`. `libs/vgui/build_deps.sh` applies one `$CFG` to every file — keep it
  that way.

## Environment (WSL2 / kernel)

- 🟢 **WSLg hardware GL works on Ubuntu 24.04 + Mesa 25.x.** Older Mesa (23.2 on 22.04) crashed the
  D3D12 driver and reset the GPU. If the window is black or the display resets, check the Mesa
  version first; `LIBGL_ALWAYS_SOFTWARE=1` (llvmpipe) is the stable fallback and is fine for this
  app.
- 🟢 **`vcan` "won't load" is a non-issue.** `modprobe vcan` → ENOEXEC because the stale `.ko` in
  `/lib/modules` predates the running kernel (custom WSL2 build). The running kernel has
  `CONFIG_CAN_VCAN=y`, `CONFIG_CAN_RAW=y`, `CONFIG_CAN_ISOTP=y` **built in** (verify via
  `/proc/config.gz`), so no modprobe is needed:
  `sudo ip link add dev vcan0 type vcan && sudo ip link set up vcan0` just works.

## CI (GitHub Actions)

- 🔴 **V will NOT self-compile on the Windows runner — CI must DOWNLOAD a prebuilt V.**
  `makev.bat` hangs at `Compiling v_stage.exe`, independent of bootstrap compiler, final compiler,
  disk and Defender (every combination timed out at up to 90 min; the same build is ~100 s
  locally). And there's no fallback: V's newest *release* (0.5.1) predates the `vlib/yaml` that
  `modules/project` imports. So `windows.yml` downloads a zipped V from this repo's
  **`v-toolchain`** release. **If that release or its asset disappears, the Windows job breaks** —
  re-mint the asset if the V pin ever moves.
- ⚪ **A colon-space inside a step `name:` invalidates the whole workflow.** YAML reads
  `name: … D: disk` as a nested mapping → "workflow file issue" / HTTP 422 on dispatch. Quote any
  step name containing `: `. (Bitten twice.)

## Our code (blobly_net)

- 🟢 **`candb.encode` rounding.** `i64(x + 0.5)` truncated negatives toward zero (`-4.5 → -4`), so
  `encode(-5.0)` produced `-4`. Fixed with `math.round` (half away from zero) and pinned by
  `candb_test.v::test_signed_negative`. The lesson stands: test module logic in isolation.
- ⚪ **GUI launches from an agent shell are flaky** — the harness can kill the windowed process.
  Verify GUI changes from an interactive shell; headless runs (`scripts/runtests.sh`) are reliable.
