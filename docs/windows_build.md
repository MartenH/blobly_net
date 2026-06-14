# Native Windows build (W1) — recipe, gotchas & vendored patches

**Status (2026-06-05): DONE.** The CANTester GUI builds and renders natively on
Windows (mingw-w64 gcc, sokol **GL** backend), and the driver-free virtual-first
flow works (Python SUT over the UDP software bus). Idle render cost ≈ **0.3% CPU**
(16-core box) — the WSLg GL-translation tax is gone.

This is the first time vlang/gui has run on native Windows, so several real
upstream bugs had to be fixed (see the patch manifest below).

---

## Toolchain layout — everything isolated under `C:\dev`

Nothing outside `C:\dev` is installed or modified (no user-profile `.vmodules`, no
shared MSYS2, no global PATH changes — the build sets env per-invocation).

| Path                          | What                                                              |
|-------------------------------|------------------------------------------------------------------|
| `C:\dev\msys64-ct`            | **Dedicated** MSYS2 root (separate from any personal MSYS2)       |
| `C:\dev\msys64-ct\mingw64`    | mingw-w64 gcc 16, pkgconf, freetype/harfbuzz/fribidi/fontconfig/pango/glib, mingw python 3.14 |
| `C:\dev\v`                    | V 0.5.1 @ commit `de365a1` (matches the Linux pin), built with tcc via `makev.bat` |
| `C:\dev\vmodules-ct`          | V modules dir (via `VMODULES` env): `gui` @ `68b9302`, `vglyph`   |
| `C:\dev\cantester_v`          | this repo                                                         |

## One-time setup

**Automated:** `.\scripts\setup_win.ps1` does everything below — installs the
dedicated MSYS2, the mingw-w64 deps, builds V at the pin via `makev.bat`, clones
`gui`/`vglyph` at their pins, and applies the four W1 patches (from
`scripts\win_patches\*.patch`). It's idempotent (re-run safely; existing pieces
are skipped) and touches nothing outside `C:\dev`. It must be PowerShell, not a
`.sh`, because it *installs* MSYS2 — there's no bash to run until it's done. The
manual steps it automates, for reference:

```powershell
# 1. Dedicated MSYS2 (self-extracting installer -> rename to the dedicated root)
Invoke-WebRequest https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-base-x86_64-latest.sfx.exe -OutFile C:\dev\msys2-base.sfx.exe
& C:\dev\msys2-base.sfx.exe -y -oC:\dev ; Rename-Item C:\dev\msys64 C:\dev\msys64-ct
& C:\dev\msys64-ct\usr\bin\bash.exe -lc "pacman -Syuu --noconfirm"   # may need a second run

# 2. mingw-w64 deps (gui/vglyph native libs) + python for the SUT
& C:\dev\msys64-ct\usr\bin\bash.exe -lc "pacman -S --needed --noconfirm \
  mingw-w64-x86_64-gcc mingw-w64-x86_64-pkgconf mingw-w64-x86_64-freetype \
  mingw-w64-x86_64-harfbuzz mingw-w64-x86_64-fribidi mingw-w64-x86_64-fontconfig \
  mingw-w64-x86_64-pango mingw-w64-x86_64-glib2 mingw-w64-x86_64-python"
# (mingw-w64-x86_64-gdb is handy for debugging.)

# 3. V at the pinned commit (builds itself with tcc; no MSVC)
git clone https://github.com/vlang/v.git C:\dev\v ; git -C C:\dev\v checkout de365a1
cmd /c C:\dev\v\makev.bat

# 4. gui + vglyph at the pin, into the isolated modules dir
git clone https://github.com/vlang/gui.git    C:\dev\vmodules-ct\gui    ; git -C C:\dev\vmodules-ct\gui checkout 68b9302
git clone https://github.com/vlang/vglyph.git C:\dev\vmodules-ct\vglyph
# then apply the patches in the manifest below
```

## Build & run

```powershell
.\scripts\build_win.ps1                      # -> build\cantester.exe   (GL backend)
$env:CANTESTER_PROJECT='projects\demo-udp.yml'
.\scripts\build_win.ps1 -Run                 # build + run on the UDP project
# virtual ECU, driver-free (separate shell):
C:\dev\msys64-ct\mingw64\bin\python.exe sut\can_sut.py udp
# then press ▶ Start in the GUI.
```

`build_win.ps1` encodes the two non-obvious build details: it feeds the *system*
`pkgconf`'s include/lib flags to V (see gotcha #2) and links `-ld3d11 -ldxgi`
(gui's readback bridge references D3D11 even on the GL backend).

**bash alternative — `scripts/build_win.sh`** (same build, run from the MINGW64
shell instead of PowerShell), for an all-`.sh` workflow consistent with
`bundle_dlls.sh` and the Linux scripts:

```bash
bash scripts/build_win.sh                 # -> build/cantester.exe
bash scripts/build_win.sh -run            # build + run
CANTESTER_PROJECT=projects/demo-udp.yml bash scripts/build_win.sh -run
```

It does exactly what the `.ps1` does (same env, same `pkgconf` flags, same
`-ld3d11 -ldxgi`). One nuance: inside MINGW64 the `/mingw64` mount makes V's own
`v.pkgconfig` `-I/mingw64/...` output valid, so gotcha #2 doesn't bite there — the
explicit `pkgconf` feeding is kept only as belt-and-braces so both paths build
identically. Choose by preference: `.ps1` launches from the native PowerShell /
VS Code terminal; `.sh` keeps you in the MSYS2 shell where `pkgconf`/`gcc`/`ldd`
(and `bundle_dlls.sh`) already live.

### Alternative toolchain — MSVC + vcpkg (`scripts/build_win_msvc.ps1`)

A second, independent route that mirrors **vlang/gui's own Windows CI** (`-cc msvc`,
libs from `vcpkg install pango freetype`) instead of mingw/MSYS2. Run it from a
**"x64 Native Tools Command Prompt for VS 2022"** (needs the VS 2022 "Desktop
development with C++" workload, which also bundles vcpkg):

```powershell
.\scripts\build_win_msvc.ps1 -Deps -Run    # vcpkg install + build + run
```

It reuses the same isolated `C:\dev\v` and `C:\dev\vmodules-ct`. Notes:
- **Backend is still GL** (`-cc msvc` uses V's default `SOKOL_GLCORE`; D3D11 stays
  broken in V's sokol glue — see the manifest). MSVC ≠ D3D11 here.
- **Patches:** only **#03** (titlebar `isvalid()`, a *runtime* abort) is needed on
  MSVC. **#01/#02 are gcc-16-only** (that's why gui's MSVC CI is green without
  them); **#04** is debug-only.
- **The fragile bit** is lib discovery off the GitHub runner (which is
  pre-integrated): the script points `PKG_CONFIG_PATH` at vcpkg's `lib\pkgconfig`
  and also passes explicit `/I<include>` + `/LIBPATH:<lib>`, then copies the
  `installed\<triplet>\bin\*.dll` next to the exe. **Status: best-effort / not yet
  verified on a real box** — if V can't find a `pango`/`freetype` header or symbol,
  the first error names the flag to fix.

---

## Gotchas (the non-obvious ones)

1. **Smart App Control (SAC) blocks locally-built unsigned exes.** If SAC is
   *enforced* (`HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState
   == 1`), every freshly compiled `cantester.exe` is blocked ("An Application
   Control policy has blocked this file" / "Part of this app has been blocked").
   SAC has no per-app allowlist and won't trust a self-signed cert, so native dev
   requires turning SAC **Off** (Settings → Privacy & security → Windows Security →
   App & browser control → Smart App Control). **Turning it off is irreversible**
   (re-enabling needs a Windows reset). The V compiler/tcc themselves ran fine;
   only no-reputation app binaries get blocked, and the verdict is per-hash so it
   can kick in a few builds in.

2. **V's `v.pkgconfig` does not relocate a `.pc` `prefix=`.** The mingw `.pc`
   files say `prefix=/mingw64` (literal). System `pkgconf` auto-redefines that to
   the real (relocated) `C:\dev\msys64-ct\mingw64`; V's *built-in* resolver does
   not, so it emits bogus `-I/mingw64/...`/`-L/mingw64/lib` and headers aren't
   found. Fix: pass the system `pkgconf`'s flags via `-cflags`/`-ldflags`
   (build_win.ps1 does this). `PKG_CONFIG_PATH` must point at
   `...\mingw64\lib\pkgconfig` so V finds the `.pc` files at all.

3. **gui requires the sokol GL backend — its shaders are GLSL-only.**
   `gui/shaders_glsl.v` provides GLSL source compiled at runtime; on the D3D11
   backend the HLSL compiler rejects it (`error X1504: invalid preprocessor
   command 'version'`). So the native Windows build uses sokol's default
   `SOKOL_GLCORE`. CLAUDE.md's "native sokol uses D3D11" premise doesn't hold for
   gui without porting all gui shaders to HLSL (a gui project, deferred). The GL
   perf is already excellent natively (≈0.3% idle CPU), so D3D11 isn't needed for
   the W1 win — it'd only matter for gui's screenshot readback (D3D11-only).

4. **D3D11 SDK debug layer absent** (only relevant if you do try D3D11): a debug
   build requests a `D3D11_CREATE_DEVICE_DEBUG` device, which fails without the
   "Graphics Tools" optional feature installed.

---

## Vendored-patch manifest (upstream candidates)

These edits live OUTSIDE this repo (in `C:\dev\v` and `C:\dev\vmodules-ct`), so a
V/gui/vglyph reinstall loses them — re-apply from here. They are written
upstream-style (no project tags) because they are **genuine upstream bugs** in the
never-before-exercised native-Windows path and are intended to be contributed back
to V / vlang-gui / vglyph.

The four gui/vglyph patches are committed as applyable diffs in
`scripts/win_patches/` (`01..04`) and `setup_win.ps1` applies them automatically
(idempotently). They were generated against the pins (`gui` `68b9302`, `vglyph`
`5685a6d` — `setup_win.ps1` now pins vglyph too, since upstream is unpinned and
the patch is context-sensitive). If you change a pin and a patch stops applying,
re-create it from your verified working modules with
`.\scripts\setup_win.ps1 -CapturePatches`. (The sokol/V D3D11 items below are NOT
shipped as patches — they're GL-path-irrelevant and kept as prose only.)

| # | File (vendored)                                  | Change                                                                                          | Upstream-worthy? |
|---|--------------------------------------------------|-------------------------------------------------------------------------------------------------|------------------|
| 1 | `gui/nativebridge/readback_windows.c`            | `#define COBJMACROS` before `<d3d11.h>` — **✅ UPSTREAM (gui main, 2026-06)**; drop local patch     | done             |
| 2 | `gui/nativebridge/dialog_windows.c`              | add `<stdio.h>`/`<wchar.h>` for `_snwprintf` — **✅ UPSTREAM (gui main, 2026-06)**; drop local patch | done             |
| 3 | `gui/titlebar.c.v`                               | guard `titlebar_dark()` with `sapp.isvalid()` — **FILED [gui#60](https://github.com/vlang/gui/pull/60)** (still needed on main) | filed            |
| 4 | `vglyph/glyph_atlas.v`                            | don't panic on empty outline (`n_points==0`) — whitespace glyphs (space) are legal              | yes (vglyph)     |
| 6 | `gui/window.v`                                   | expose `WindowCfg.sample_count` → `gg.new_context` (MSAA) — **FILED [gui#61](https://github.com/vlang/gui/pull/61)**; drop local patch once merged | filed            |

> **⚠️ 2026-06-14 — much of this is now UPSTREAM.** `vlang/gui` merged **native Windows support** to
> `main` (2026-06-11→13) + Windows CI. The gcc-16 compile fixes (#1/#2) are already in `main`, so a fresh
> Windows bring-up should **clone gui `main`** and skip those — the only local gui patches still needed are
> the leak/closure stack (`docs/v_patches/`) and, until they merge, gui#60 (titlebar) + gui#61 (MSAA).
> Pin-bump from `68b9302` → `main` assessed GREEN (see `docs/upstreaming.md`).

**Applied in the live GL build:** all four above.

**NOT applied (kept for the D3D11 path only)** — a separate, larger upstream
contribution discovered while attempting D3D11, captured here so it isn't lost:

- `vlib/sokol/sapp/sapp.c.v` — `glue_environment()`/`glue_swapchain()` only wire
  **metal/gl**; the **D3D11 device/context/views are never copied** into the gfx
  environment, so `sg_setup()` gets a null device and crashes. Wiring them through
  (`env.d3d11.device/device_context`, `swapchain.d3d11.render_view/resolve_view/
  depth_stencil_view`) is required for *any* V sokol D3D11 app on Windows. This is
  the most valuable upstream fix, but it's moot until gui ships HLSL shaders, so
  the live build stays on GL and this patch is reverted.
- `vlib/sokol/c/declaration.c.v` — would flip Windows to `-DSOKOL_D3D11`
  (`-ld3d11 -ldxgi`); reverted (GL).

### Upstreaming plan (decided 2026-06-09)

> **Submission record + reproducible recipe: `docs/upstreaming.md`.** PR 1
> (vglyph) is open: https://github.com/vlang/vglyph/pull/4. The PR-body texts
> live in `scripts/win_patches/pr*.md`; the unsafe-cast fix is `05-vglyph-unsafe-cast.patch`.

We're going to actually submit these upstream as PRs (user rates gui's merge odds as
**good**). `gh` is authed. **PRs target each repo's `master`**, but the patches are vs the
pins gui@68b9302 / vglyph@5685a6d — so first confirm each bug still exists on master and
rebase the fix onto it. Continuing this on the **WSL/Linux** side (simpler dev env).

- **Tier 1 (lead with — real bugs/warnings):** patches #1–#4 above, **plus** a vglyph
  one-liner not yet in the table — `glyph_atlas.v:418` casts `&C.FT_GlyphRec` →
  `&C.FT_BitmapGlyphRec` outside `unsafe` (V warns); fix:
  `bmp_glyph := unsafe { &C.FT_BitmapGlyphRec(ft_glyph) }`. Suggested first PR: one focused
  **vglyph** PR bundling empty-outline (#4) + this unsafe-cast.
- **Tier 2 (optional, high-churn):** the cosmetic V *notices* (`unused parameter` →
  `_`-prefix the name, the V analogue of C's `(void)param;`; `variable shadows a function
  declaration` → rename). No tool does this — `v fmt` is layout-only, `v vet` only reports —
  so it's a manual signature-by-signature sweep. Decide separately; a maintainer may view
  it as noise.
