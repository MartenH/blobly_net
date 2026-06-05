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

| # | File (vendored)                                  | Change                                                                                          | Upstream-worthy? |
|---|--------------------------------------------------|-------------------------------------------------------------------------------------------------|------------------|
| 1 | `gui/nativebridge/readback_windows.c`            | `#define COBJMACROS` before `<d3d11.h>` (C-style COM macros; else won't compile under gcc 16)   | yes (gui)        |
| 2 | `gui/nativebridge/dialog_windows.c`              | add `<stdio.h>`/`<wchar.h>` for `_snwprintf` (gcc treats implicit decls as errors)              | yes (gui)        |
| 3 | `gui/titlebar.c.v`                               | guard `titlebar_dark()` with `sapp.isvalid()` — set_theme() runs before sapp.run() → abort      | yes (gui)        |
| 4 | `vglyph/glyph_atlas.v`                            | don't panic on empty outline (`n_points==0`) — whitespace glyphs (space) are legal              | yes (vglyph)     |

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
