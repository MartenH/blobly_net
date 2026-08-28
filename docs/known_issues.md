# Known issues & gotchas

Things that cost real time, kept so they cost it once. Read this first when something breaks.

Status key: 🔴 open · 🟡 worked around · 🟢 fixed, kept for the reason · ⚪ benign/expected

> **Scope note.** This file used to be ~80% vlang/gui, sokol and vglyph material. That toolkit was
> retired for Dear ImGui + ImPlot (2026-07-06) and is not coming back, so that content was removed
> rather than left to send someone down a dead path. The old detail is in
> [`history.md`](history.md).

---

## V language / compiler / tooling

- 🟡 **`v test` needs `-cc gcc` on Windows, or it looks like it cannot run at all.**
  `v -enable-globals test modules/` on native Windows (MSYS2/mingw) fails before running a
  single test with
  `C function 'C.GetFinalPathNameByHandleW' was declared in V, but the C compiler did not see a
  matching C declaration`. It comes from **vlib**, not from this repo, and it reproduces on
  untouched files on `main` — so it reads exactly like "the module suite does not run on this
  machine", which cost most of a session on that assumption. It is V's default **tcc**:
  `v -enable-globals -cc gcc test modules/` runs the whole suite (57/57). The Linux CI job uses
  the default compiler and never sees it.
- 🔴 **A timed `select` can panic `Invalid argument` under starvation.** V 0.5.1's
  `channel_select` computes `remaining := timeout - stopwatch.elapsed()` only after its
  non-blocking try loop, so a thread descheduled for longer than its timeout hands
  `sem_timedwait` a NEGATIVE duration; `Duration.timespec()` adds a negative `tv_nsec` to the
  clock, and when that underflows the current nanoseconds the kernel answers EINVAL and V's
  `cpanic` kills the process with `V panic: Invalid argument`. Probabilistic (it needs the
  current `tv_nsec` to be smaller than the overshoot) and load-dependent: seen once in twenty
  runs of `shared_test` pinned to two cores behind three busy loops, from a 50 ms wait in a
  spawned thread, never at 16 cores. Every `select { … N * time.millisecond {} }` in this repo
  carries it; a wait that has a sender guaranteed to close or post the channel is better
  written unbounded (`transport.SharedEntry.settled` is). Not ours to fix — vlib — and pinned
  here so the next `V panic: Invalid argument` in a CI log is read as this, not as a bug in
  the test it landed in.
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
- 🔴 **A stock WSL2 kernel cannot make a `vcan` interface at all.** `ip link add type vcan` fails
  with `Error: Unknown device type.` because **`CONFIG_CAN_VCAN` is not set** and no `vcan.ko`
  ships — verify with `zcat /proc/config.gz | grep CAN_VCAN`. `CONFIG_CAN` and `CONFIG_CAN_RAW`
  are `=m` (so they DO need `modprobe`), and `CONFIG_CAN_ISOTP` is absent too, as are the USB CAN
  drivers. The module has to be built:
  [`can_hardware.md`](can_hardware.md#can-on-wsl2--the-kernel-does-not-ship-vcan) has the recipe,
  and the kernel itself does not need replacing.

  This entry previously said the opposite — that all three were built in and `ip link add` "just
  works" — describing one machine's custom kernel as though it were the platform. It cost a fresh
  setup an evening in 2026-08. The in-process (`inproc:`) and UDP buses need none of this, which
  is why the unit tests and the headless runner pass on a machine where SocketCAN cannot work.

## Environment (native Windows)

- 🟢 **Build with `-cc gcc` and MSYS2's mingw, not V's bundled tcc.** tcc cannot resolve Win32
  symbols — it stops on `undefined symbol 'InitOnceExecuteOnce'` / `GetTickCount64`. That is a tcc
  limitation and not a "Windows V does not work" one, which is worth stating because believing the
  latter sends you to WSL for everything:

  ```powershell
  $env:PATH = "C:\dev\msys64-ct\mingw64\bin;$env:PATH"
  C:\dev\v\v.exe -cc gcc -enable-globals -path "@vlib|@vmodules|modules" -o thing.exe cmd\thing\main.v
  ```

  It is what `.github/workflows/windows.yml` uses too. Bench work has to be native anyway — the
  vendor DLLs only exist on Windows.

- 🟡 **The network suites make Windows Firewall prompt on every run.** `udpbus_test.v` binds
  `0.0.0.0:<port>` and joins multicast, and the DoIP and SOME/IP suites listen on TCP — Windows
  prompts for any listen on a non-loopback address. A per-program allow rule never sticks, because
  V builds each test binary to a **fresh temp path** every run, so the prompt returns forever.

  Allow the port bands instead — they are declared once in `modules/testports` and are narrow:

  ```powershell
  New-NetFirewallRule -DisplayName "blobly_net tests (UDP)" -Direction Inbound `
    -Protocol UDP -LocalPort 20000-29999 -Action Allow -Profile Any
  New-NetFirewallRule -DisplayName "blobly_net tests (TCP)" -Direction Inbound `
    -Protocol TCP -LocalPort 20000-25999 -Action Allow -Profile Any
  ```

  Not merely cosmetic: dismissing a prompt can fail the multicast bind, and `udpbus_test` then
  flakes in a way that reads as a code defect. Undo with
  `Remove-NetFirewallRule -DisplayName "blobly_net tests*"`.

- 🟡 **Do not mix Windows-side and WSL-side writes on one working tree.** Each caches the other's
  writes to `/mnt/c`. On 2026-08-27 the two views diverged by nine minutes: an edit was silently
  reverted by a stale copy and two tests were reported as passing while never being compiled at
  all — which makes verification untrustworthy rather than merely wrong. Do a whole task on one
  side; `wsl --terminate Ubuntu-24.04` clears a stale view. The bash-only pieces
  (`scripts/runtests.sh`, the codex review scripts) still need WSL, so flush before running them.

## CI (GitHub Actions)

- 🔴 **V 0.5.2 tries its experimental V3 compiler first, and CI paid for it twice.** Every
  build attempts V3 and falls back to the established compiler when V3 cannot build the
  program — 65 of the 72 test programs on the Linux runner, each compiled twice: the test
  step summed 1,807 s of compile time where the same files take 100 s on a 0.5.1 bench, and
  the job took eleven minutes for twenty seconds of tests. The fallback also posts an
  automatic bug report to `bugs.vlang.io` with a bounded excerpt of the failing source
  (V's docs, "Automatic bug reports"). `ci.yml` sets `VFLAGS=-old-compiler` for both jobs,
  which skips V3 entirely; it is an env var and not a flag in the scripts because a V that
  predates V3 rejects `-old-compiler` as an unknown argument. The flag ends only the
  fallback's report — the established compiler uploads an excerpt of its own on any C
  compilation error — so `V_C_ERROR_BUG_REPORT_DISABLED=1` sits beside it, which is V's
  opt-out for every reporting path (and is harmless on a bench, where the flag is not). If a
  CI log ever shows `note: V3 could not build this program` again, the env has stopped
  reaching `v`.
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
