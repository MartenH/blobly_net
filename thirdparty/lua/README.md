# Vendored Lua 5.4.7

Unmodified upstream Lua **5.4.7** core + standard library source, from
<https://www.lua.org/ftp/lua-5.4.7.tar.gz> (the `src/` tree), compiled directly
into the blobly_net binary — no system `liblua`, no runtime install — so a fresh
box builds offline from git alone (the repo's single-source-of-truth principle).

Lua is distributed under the **MIT license**; the copyright notice lives in
`lua.h` (and `LICENSE` text in the upstream tarball). It is the embedded
scripting engine for `modules/lua` / `modules/script` (CANoe-CAPL replacement —
see the "custom message sending" tier roadmap).

## What's here vs. upstream
- All upstream `src/*.c` and `src/*.h`, **except** the standalone programs
  `lua.c` (interpreter) and `luac.c` (compiler) — we embed the library, not the
  CLI tools.
- `ct_lua_amalg.c` — **added by us**: a single translation unit that `#include`s
  the core + library `.c` files (what upstream's `onelua.c` does; the 5.4.7
  tarball ships no `onelua.c`). This is the file fed to the C compiler via V's
  `#flag` in `modules/lua/lua.v`.

## Upgrading
Replace `*.c`/`*.h` from a newer tarball's `src/`, delete `lua.c`/`luac.c`, keep
`ct_lua_amalg.c` (re-check its include list against the new `src/` Makefile's
`CORE_O` + `LIB_O`). Build flags (`-DLUA_USE_LINUX`, `-lm`, `-ldl`) are in
`modules/lua/lua.v`.
