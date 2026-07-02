# Windows build hang / memory leak — debug handoff

> ## ✅ RESOLVED (2026-07-01) — it was V issue [#27472], fixed in master `ddc9c99`
>
> **Root cause of the CI hang:** master V's `find_module_path` (builder.v) anchors the
> importer to the *outermost* enclosing `v.mod` by walking up folders. On the GitHub
> runner's `D:\a\blobly_net\blobly_net` checkout that walk never advanced
> (`os.real_path`→`GetFinalPathNameByHandleW` returned a non-strict-ancestor folder),
> so V **spun at 100% CPU in the front-end, before launching any compiler** — which is
> why *both* the gcc and msvc jobs hung for hours, and why de365a1 (no such loop) was
> green. Proven on the live runner with gdb: one `v.exe` pegged in
> `find_module_path → ModFileCacher.get_by_folder → os.real_path → GetFinalPathNameByHandleW`,
> the parent `v.exe` idle in `ReadFile`. NOT the C compiler, NOT the giant `[32768]u16{}`
> initializers, NOT gui, NOT core count.
>
> **Fix:** PR [#27473] (merged `ddc9c99`, 2026-06-22) adds a progress guard in
> `vmod.traverse` (`next == cfolder`) + an `is_strict_ancestor` check in
> `find_module_path`. The prebuilt CI V was `c0624b2` (2026-06-20) — **2 days too old**.
> Minted `v-ddc9c99-windows.zip` (`v self` at ddc9c99), repointed `windows.yml` `V_ASSET`
> at it, and restored the **master V + gui 7a20a6a** combo. Windows CI is now **green
> (~2–4 min) AND leak-free** (master `closure.Lifetime` API) — no de365a1 + closure-patch
> detour. The de365a1 material below is kept for history.
>
> [#27472]: https://github.com/vlang/v/issues/27472
> [#27473]: https://github.com/vlang/v/pull/27473

Everything the Windows side needs to diagnose the current situation. TL;DR: run
`bash scripts/win_diag.sh` in the MINGW64 shell and paste `win_diag.log`.

## The two separate problems (don't conflate them)

1. **Runtime memory leak** (the original bug): the packaged Windows GUI leaks fast →
   Boehm GC `Too many heap sections`. This is the **V capturing-closure-context leak**
   — vlang/gui rebuilds capturing event handlers every frame and V never reclaims their
   contexts. WSL/Linux is fine because it runs the *fixed* toolchain. The fix is a **small
   RUNTIME patch** (`docs/v_patches/closure-gc-leak-fix.patch` + `gui-closure-reclaim.patch`).
   It does **not** affect build time.

2. **Build hang** (surfaced while fixing #1): switching Windows to *master* V (to get the
   closure fix the modern way) makes the Windows app compile **hang**. That is a
   Windows-specific problem with master V's toolchain, **unrelated to the leak fix itself**.

Key measured facts:
- On **Linux** the whole app builds in **~3.4 s** (master V c0624b2). So it is NOT an
  inherently huge/slow compile.
- Generated C is **7.0 MB / 150,733 lines**. **`-skip-unused` is a no-op** here (already the
  default — the generated C is byte-identical with/without it). Ignore that switch.
- The OLD Windows CI built fine with **de365a1 + gui 68b9302** (green). So **de365a1's
  codegen builds this app on Windows**; master V's may not.

## The leak-free target combo (no master V → no build hang)

Keep the V that already builds on Windows, and add ONLY the small runtime leak fix:

| Component | Pin | Patch |
|-----------|-----|-------|
| V         | `de365a1` | `docs/v_patches/closure-gc-leak-fix.patch` (verified: applies clean + compiles) |
| gui       | `68b9302` | `docs/v_patches/gui-closure-reclaim.patch` + win-patches `01`–`08` |
| vglyph    | `5685a6d` | win-patch `04` (empty-outline) |
| markdown  | `ef2f101` | — (NEW dep: `src/main.v` renders Help to HTML) |

Do NOT use master V (`c0624b2`/`7a20a6a`) on Windows until the build hang is understood —
that is what regressed the build.

## Diagnose: is the hang in V's CODEGEN or in GCC?

```bash
cd /c/dev/blobly_net
bash scripts/win_diag.sh      # -> win_diag.log  (paste it back)
```
It prints all versions, then:
- **Phase 1** = C generation only (no gcc). Fast → codegen fine, hang is gcc. Times out → V
  codegen wedges (⇒ drop to de365a1).
- **Phase 2** = full build with `-showcc` + a 20-min cap. Tells us if it truly hangs or is
  just slow, and whether it reaches the gcc invocation.

Also glance at Task Manager during Phase 2: `v.exe` pegged = codegen; `cc1.exe`/`gcc.exe`
pegged = the C compile; idle = a true deadlock.

## Apply the leak-free combo (once the box is on de365a1)

```bash
# V: de365a1 + the closure leak fix
cd /c/dev/v
git checkout -- . ; git checkout de365a1
git apply /c/dev/blobly_net/docs/v_patches/closure-gc-leak-fix.patch
./v.exe self                          # rebuild patched de365a1 V (uses existing v.exe)
git -C /c/dev/v diff --stat           # should list closure.c.v, cgen.v, fn.v, markused.v

# gui: 68b9302 + reclaim + win patches ; vglyph 5685a6d + 04 ; markdown ef2f101
#   -> easiest: re-run scripts/setup_win.ps1 (see note below), or apply by hand:
cd /c/dev/vmodules-ct/gui
git checkout -- . ; git checkout 68b9302
git apply /c/dev/blobly_net/docs/v_patches/gui-closure-reclaim.patch
for p in 01-gui-readback-cobjmacros 02-gui-dialog-includes 03-gui-titlebar-isvalid \
         06-gui-sample-count; do
  git apply /c/dev/blobly_net/scripts/win_patches/$p.patch
done
git apply /c/dev/blobly_net/docs/v_patches/gui-window-resize.patch
git apply /c/dev/blobly_net/docs/v_patches/gui-dock-tab-separator.patch
[ -d /c/dev/vmodules-ct/markdown ] || git -C /c/dev/vmodules-ct clone https://github.com/vlang/markdown.git
git -C /c/dev/vmodules-ct/markdown checkout ef2f101

# build (de365a1 codegen -> should build like the old CI)
cd /c/dev/blobly_net
bash scripts/build_win.sh -run
```

Then run it and watch RSS: **leak-free = RSS plateaus** (no `Too many heap sections`).

> NOTE: `scripts/setup_win.ps1` on the `fix-windows-leak` branch currently pins master V +
> gui 7a20a6a (the detour that caused the build hang). It will be reverted to this de365a1 +
> closure-patch combo once the diagnostic confirms de365a1 builds + runs leak-free. Until
> then, apply the combo by hand as above.

## What to report back
1. `win_diag.log` (versions + Phase 1/2 timings + exit codes).
2. Which process pegged CPU during Phase 2 (v.exe / cc1.exe / idle).
3. If you applied the de365a1 combo: did it build, and does RSS plateau at runtime?
