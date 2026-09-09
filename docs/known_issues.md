# Known issues & gotchas

Things that cost real time, kept so they cost it once. Read this first when something breaks.

Status key: 🔴 open · 🟡 worked around · 🟢 fixed, kept for the reason · ⚪ benign/expected

> **Scope note.** This file used to be ~80% vlang/gui, sokol and vglyph material. That toolkit was
> retired for Dear ImGui + ImPlot (2026-07-06) and is not coming back, so that content was removed
> rather than left to send someone down a dead path. The old detail is in
> [`history.md`](history.md).

---

## V language / compiler / tooling

- 🟡 **`-prod` makes a hot loop O(len) per call when the frame holds a pointerful array BY
  VALUE.** **Fixed upstream, and we cannot have it yet** — see the end of this entry: the fix is
  on V3 master and this repo pins a pre-V3 `v` with `-old-compiler` on purpose. Everything below
  still describes the compiler we build with today.

  With `-prod` **and** a Boehm GC mode, V emits a "deep GC scope pin" around **every
  call** in a function whose scope holds a by-value aggregate containing pointers
  (`cgen.v: scope_gc_pin_pregen`, guarded by `if !g.pref.is_prod`). The pin walks **every
  element** of that aggregate to snapshot its interior pointers, and past 32 of them it also
  `calloc`s, `GC_add_roots`, `GC_remove_roots` and `free`s per call. So a replay loop sitting in
  a frame that holds a million-frame `[]canlog.LogEntry` pays a million-element walk **per
  frame sent**. Measured here on a 1.23 M-frame `.mf4`: `cmd/restbus` sent **562 frames in ten
  minutes** instead of 1.07 M in sixty seconds — a ~9 ms cost on every call out of that frame,
  where the same call costs 1 ns. The discriminator is the ELEMENT TYPE and the by-value-ness,
  nothing else: `&[]LogEntry` is free, `[]u64` (pointer-free elements) is free, and removing the
  call removes the cost.

  **We are not affected today, and this is the reason to keep it that way.** Nothing in this
  repo builds `-prod` — `release.yml` ships "the same non-optimized build every test and CI run
  exercises" — and the unmodified `cmd/restbus` replays all 1,069,214 frames of that recording
  in 67 s. So this is filed against the "Revisit when CI itself builds `-prod`" note in
  `release.yml`: **turning `-prod` on without fixing this first would have taken that replay
  from real time to roughly thirteen days** — 0.94 frames/s against 16,200, about 17,000×, the
  ~9 ms landing on each of the ~100 calls a frame makes out of the pinned frame — silently, on
  exactly the large real recordings nobody replays in CI. The
  fix when that day comes is per-frame, not global: pass big recordings/plans by reference
  (`&mf4.Recording`) and keep the transmit loop in a frame that holds nothing big by value —
  verified to restore full speed. `-gc none` also removes it, but leaks.

  Standalone repro (80 lines, no modules, no data): a `[]Item{name string, data []u8}` of 1 M
  elements held by value while calling an empty function — `v -prod` 4.75 ms/call, plain `v`
  2 ns/call, `v -prod -gc none` 1 ns/call, and linear in between (1 k → 921 ns, 10 k → 8.3 µs,
  100 k → 223 µs). Upstream, with that repro and the generated C:
  [vlang/v#28418](https://github.com/vlang/v/issues/28418) (V 0.5.1).

  **Measured on a V that is NOT the pinned one, and here is how far that carries.** Every number
  above came from a local `v` reporting 0.5.1, not from `.v-version`'s `5d34e477` — so the tie to
  our own toolchain is a SOURCE comparison, not a second measurement. It holds where it matters:
  at `5d34e477` `scope_gc_pin_pregen` (which decides when a pin is emitted, and carries the
  `!g.pref.is_prod` guard) is byte-identical to the one measured, and so is the `.array` branch
  of `boehm_collect_keep_alive_helper_name` — the `for … _v_keep_i < it->len` walk that makes the
  cost O(len). The two compilers do differ (688 lines of `cgen.v`, and the helper's naming and
  caching), so if this ever needs to be exact rather than sound, build the pin and re-run the
  repro. Nobody has.

  **Upstream fixed it in a day** — [vlang/v#28426](https://github.com/vlang/v/pull/28426),
  merged to master as `f174e71` on 2026-09-07 — by rooting a pointerful array through its
  Boehm-scanned backing allocation instead of walking every element around every call
  (recursive rooting stays for pointerful *structs*). Their measurement on the repro: about
  2,000,000 ns → about 1 ns per call at a million elements.
  **It is on V3 master, so it is not ours to take.** `.v-version` pins a pre-V3 `v` and both
  Linux jobs set `VFLAGS=-old-compiler`, because a V3-only `v` refuses that flag — and the fix's
  own author notes V3 master still fails unrelated fixtures (`assign_fn_addr.vv`, parser
  diagnostics). So this entry stays until the toolchain moves, which is a project of its own and
  not a `.v-version` bump. When it does move: re-run the repro first, and if it is clean, the
  `pump()` split in `cmd/restbus` stops being load-bearing — keep it anyway, it removed a
  duplicated transmit loop on its own merits.

  It hides well, which is the other reason it is written down: nothing profiles as hot, the
  cost is attributed to whichever tiny function the loop happens to call, `GC_get_gc_no()` never
  advances and `GC_disable()` changes nothing — so it does not look like the GC even though it
  is emitted by the GC path.

  **How to find them without guessing.** The pins are visible in the generated C, so the metric
  is objective: `v -enable-globals -prod -path "@vlib|@vmodules|modules" -o out.c cmd/<tool>`,
  then count `collect_keepalive` per function. `cmd/restbus` before this was written down:
  `main__run_multi` 591, `main__main` 531, `player__build_multi` **0** — and build_multi holds
  a million-entry array by value too, so the count, not the shape, is what to trust.
  `cmd/restbus`'s transmit loop now lives in `pump()`, which measures **3**, and under `-prod`
  it replays 1,069,214 frames in 66 s where the inline version managed 562 in ten minutes.
  The rest of the app is measured but NOT changed, because none of it is a per-frame loop and
  none of it is exercised by a test: `main__draw_dbc_editor` 1959, `main__replay_group` 1014,
  `main__draw_buses` 636, `main__draw_replay_config` 549. `replay_group` is the one that would
  matter on the day `-prod` is switched on — it is the GUI's per-frame transmit loop, holding
  the recording, the plan and the `player.Player` by value in the frame that sends.
- 🟡 **The GUI does not build with `-prod` without one edit.** `unused variable` is a warning in
  a normal build and an **error** under `-prod`, so `cmd/blobly_net/panel_gen.v`'s dead `pw` was
  enough to stop the whole `-prod` build — nothing catches it because nothing builds `-prod`.
  Removed here. Expect the same class again the next time `-prod` is tried: fix them before
  concluding anything about `-prod`, since the build fails before any measurement is possible.
  (Unrelated: on a bare Windows bench `v ... -o gui.exe cmd/blobly_net` fails at LINK time
  — `ld returned 1` — for want of the native GL/FreeType libraries; that reproduces on an
  untouched `main` and is an environment matter, not a code one. `-check` and `-o out.c` both
  work, which is enough to verify a change compiles.)
- 🟡 **`v test` needs `-cc gcc` on Windows, or it looks like it cannot run at all.**
  `v -enable-globals test modules/` on native Windows (MSYS2/mingw) fails before running a
  single test with
  `C function 'C.GetFinalPathNameByHandleW' was declared in V, but the C compiler did not see a
  matching C declaration`. It comes from **vlib**, not from this repo, and it reproduces on
  untouched files on `main` — so it reads exactly like "the module suite does not run on this
  machine", which cost most of a session on that assumption. It is V's default **tcc**:
  `v -enable-globals -cc gcc test modules/` runs the whole suite (72 test programs today). The Linux CI job uses
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
- 🟡 **A UDP read deadline is not honoured.** `net.UdpConn.set_read_deadline` followed by
  `read` returned after ~100 ms every time, deadline or not (V 0.5.1, #235's first cut). What
  works is `set_read_timeout` re-armed before each read with what is left of the window, which
  is what `transport.cansub_browse` does. And a 0-byte datagram comes back from `read` as an
  ERROR (`none`), not as `n == 0`, so a collector must break only on `net.err_timed_out_code`.
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

- 🟢 **Pinning `.v-version` alone was never a pin — the BOOTSTRAP floated, and one morning it
  took every branch down.** V is built from source, and `make` bootstraps it by cloning
  **vlang/vc** (the generated C) with **no ref**, then `latest_vc` runs `git clean -xf && git
  pull --rebase` on it. So the compiler that builds our pinned source was whatever that repo's
  default branch happened to hold. It looked like a pin only by coincidence: vc sat on
  `718daf02` — the C generated from our exact `.v-version` — from 2026-09-05 20:06 until
  2026-09-07 05:31. When vc regenerated from V3 master, `make` began dying with
  `./v2: No such file or directory` (`GNUmakefile:217`), because a V3 bootstrap will not build
  pre-V3 source under `-old-compiler`, so `v2` was never produced.
  **The symptom is maximally misleading**: nothing in the repo changed, the failure is in
  *Install V* before a line of our code is touched, and the error names a file rather than a
  version. What settled it was re-running the LAST GREEN RUN ON `main` unchanged — commit
  `5b61858`, success at 2026-09-06 14:15Z, failure at 2026-09-07 06:33Z, same everything. If a
  build ever fails in a way the diff cannot explain, re-run a known-green run before believing
  anything else.
  Fixed by pinning the bootstrap too (`.vc-version`) and building with **`make local=1`**, V's
  own flag: `latest_vc`, `latest_tcc` and `latest_legacy` are all under `ifndef local`, so
  nothing is pulled out from under the build. Pre-cloning at a pin WITHOUT `local=1` does not
  work — the pull undoes it. The install step is hand-rolled rather than `vlang/setup-v`
  because that action runs `make` itself, leaving nowhere to place the pinned clone.
  **`make latest_tcc` runs FIRST, without `local=1`**, because that same flag also disables the
  tcc fetch and V keeps its bundled **`libgc.a` inside `thirdparty/tcc/lib`** — with `local=1`
  alone the bootstrap completes, `v` is built, and then the very next step (`v run
  cmd/tools/detect_tcc.v`) fails to link libgc. tcc is left FLOATING on purpose: that is
  exactly what it was before any of this, it is a prebuilt C compiler bundle rather than our
  own source compiled to C, and it is not what broke us. If it ever does, pin it the same way
  from `vlang/tccbin`, branch `thirdparty-<os>-<arch>`.
  **`.vc-version` must be the vc commit generated from `.v-version`** — its message is
  `[v:master] <the .v-version sha> - …`. Bump the two together or not at all.
- 🟡 **V 0.5.2 tries its experimental V3 compiler first, and CI paid for it twice.** Every
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
  reaching `v`. `windows.yml` sets neither: it runs the pinned `v-toolchain` build
  (`v-ddc9c99`, a 2026-06 master), and whether that build attempts V3 has not been checked.
- 🔴 **V master is V3-only since 2026-09-05, and a V3-only `v` REFUSES `-old-compiler`.**
  `vlang/v` edf824295b ("make macOS and Linux self-builds V3-only") made `make` produce a V
  with no established compiler in it, so with the env above every Linux job on every branch
  died at toolchain setup: `` `-old-compiler` is not available: this V executable contains
  only the V3 compiler ``. This repo does not build under V3 yet, so `ci.yml` no longer takes
  master: it builds V from source at `.v-version`, which names the last master commit a green
  run built (`5d34e477`, 2026-09-05 06:06 UTC) — and so do `release.yml`'s Linux job and
  `scripts/setup_env.sh`, or a tagged release and a fresh bench would each build the master this
  pin exists to avoid. Bump that file to move; drop `VFLAGS=-old-compiler` in the same change,
  and expect the V3 fallback behaviour described above to be what you meet.
  **`vlang/setup-v` is no longer how any of them install it**, and `.v-version` is no longer the
  only pin: the bootstrap needs `.vc-version` beside it, which is what the entry above this one
  is about. Read that one before touching either file.
- 🟡 **V will NOT self-compile on the Windows runner — CI must DOWNLOAD a prebuilt V.**
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

- 🟢 **Replay stuttered once a second and fell behind — the wiretap ring rebuilt itself on every
  emitted frame.** Seen first on a 2-bus project as "memory sits at 1 GB, stutter every second,
  then `Fatal error in GC: Too many heap sections`". Measured from inside the real GUI on Windows
  (`cmd/blobly_net/probe.v`: `BLOBLY_PROBE_LOG=<file> BLOBLY_PROBE_SECONDS=70 blobly_net
  <project>` writes a one-page summary and exits; inert without the variable), 13 buses replaying
  one 1.07 M-frame `.mf4`: **1,140 MB/s allocated**, 194 stop-the-world pauses ≥50 ms in 70 s
  (max 726 ms), 96% of frames more than a second late, the replay 11.6 s behind by the end.
  Boehm plateaus the heap near 1 GB by collecting whenever it fills; at that allocation rate it
  fills about once a second, and a collection over ~1 GB is a 100–700 ms freeze of every thread.
  That is the stutter, and the plateau is why memory looked stable.
  **The source was `wiretap.Ring.note()`**: once the ring was at its 1024 cap, every note found
  itself one over, allocated a `map[int]bool`, ran three passes and a fresh 1024-entry `keep`
  array, and replaced the ring — a full rebuild per frame to evict one record, ~150 KB each. The
  render loop's per-frame clone of the trace ring was the other suspect and turned out secondary
  (switching it off changed little once the ring was fixed); `app.mu` is not a contention problem
  (every acquisition a send makes, four per frame: avg 1.5 µs, 4% of the replay thread's time;
  the maximum, 179 ms, coincides with a collection, which stops the lock holder like everyone
  else). Eviction is in place now — same priority, same verdicts, 356 bytes per
  note against 180,996 — and `test_note_cost_when_the_ring_is_full` pins the class. The
  self-review of that fix found the SIBLING: below ~500 frames/s the ring never fills, records
  age out instead, and `expire` (every emitted frame) and `drop_expired` (every received one)
  copied the whole remaining ring to drop a prefix — ~400 KB a step, on the RX thread, under
  `app.mu`, at exactly the rates the first probe run could not show. In place too now, and
  `test_cost_when_records_age_out` pins it (256 bytes a step against 422,160).
  After the fix, same probe: ~140 MB/s, **0 frames over a second late**, worst 182 ms, 70% within
  1 ms, the replay completes.
  **What remains is 🔴 and is the next piece of work**: one pause every 1–2 s, most of them
  50–300 ms (the probe's `hic_with_gc` counter says which gaps a collection spans — 35 of the 97
  over 20 ms in a 70 s run, and every long one), visible as a stutter every second or two,
  because the LIVE heap is still ~900 MB — a replay materialises the entire recording (878 k
  frames to replay 87 k on a 2-bus project; all of it on 13) and holds it for the run, and a
  collection over that many objects is that long. Frequency fell 7×; length did not move. That
  wants the recording in an arena (pointer-free rows, one payload pool) so a collection has
  almost nothing to trace, plus an allocation-free hot loop. Separately, `timeBeginPeriod` is
  called nowhere, so every sleep on Windows rounds to 15.6 ms — a floor under cadence, visible as
  a 16 ms worst case headless.
  **How it was found is the part to keep**: three earlier diagnoses were wrong (the collector
  itself, the `-prod` scope pin, "confine the recording to a helper"), each plausible from
  reading. The probe's allocation-rate counter and a knob to switch a suspect off settled it in
  two runs. Measure the real app before believing a theory about it.

- 🟢 **`candb.encode` rounding.** `i64(x + 0.5)` truncated negatives toward zero (`-4.5 → -4`), so
  `encode(-5.0)` produced `-4`. Fixed with `math.round` (half away from zero) and pinned by
  `candb_test.v::test_signed_negative`. The lesson stands: test module logic in isolation.
- ⚪ **GUI launches from an agent shell are flaky** — the harness can kill the windowed process.
  Verify GUI changes from an interactive shell; headless runs (`scripts/runtests.sh`) are reliable.
