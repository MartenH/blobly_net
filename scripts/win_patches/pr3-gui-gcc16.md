Two small fixes that let the Win32 C bridge compile under **mingw-w64 / gcc 16**. Both are implicit-declaration errors that gcc 16 treats as hard errors (C99+ default hardening); MSVC's CI is green without them, so they only surface on the gcc/MSYS2 toolchain.

### 1. Define `COBJMACROS` before `<d3d11.h>` in the readback bridge
`readback_windows.c` uses the C-style COM macros (`ID3D11Texture2D_*`, `IDXGI*`, …) on the D3D11 interfaces. Those macros only exist when `COBJMACROS` is defined before `<d3d11.h>` is included. gcc/mingw doesn't define it implicitly, so the bridge failed to compile with implicit-declaration errors. Define it (guarded) ahead of the include.

### 2. Include `<stdio.h>`/`<wchar.h>` in the dialog bridge
`dialog_windows.c` calls `_snwprintf` without including its declaration. gcc 16 errors on the implicit declaration. Add `<stdio.h>` and `<wchar.h>`.

These are C-only changes behind `#ifdef _WIN32` and don't affect MSVC or other platforms. Verified by building gui natively with mingw-w64 gcc 16.
