# vgui — V binding for Dear ImGui + ImPlot (evaluation spike)

A small, reusable V module wrapping **Dear ImGui** (docking / multi-viewport) + **ImPlot**,
on a **GLFW + OpenGL3** backend. Built to evaluate migrating blobly_net's GUI off `vlang/gui`
(which is structurally single-window). See **`docs/gui_toolkit_evaluation.md`** for the full
findings and the migrate/stay recommendation.

**Status: evaluation, not adopted.** Nothing in the main app depends on this yet.

## Design

- **Clean V API over a curated *scalar* C ABI** (`vgui_glue.cpp`) sitting on **cimgui + cimplot**.
  The complex composites (the ImPlot swimlane) live in C++ where the ImGui/ImPlot API is
  ergonomic; V calls flat `vgui_*` functions. This is the same wrap-C-in-a-facade pattern the
  app already uses for Lua (`ct_lua_shim`) and SocketCAN — the V↔C surface stays small and
  stable, unlike a raw ~800-function cimgui binding (cf. `nsauzede/vig`, which hand-mirrors
  `ImGuiIO` field-by-field and breaks on every imgui bump).
- **Event-driven loop** (`glfwWaitEventsTimeout`) for gui-like low idle CPU. `VGUI_POLL=1`
  switches to a 60fps poll loop (high CPU — stress/screenshots only).

## Files

| file | what |
|------|------|
| `vgui.v`        | the V module (bindings + clean API) |
| `vgui.h`        | C-ABI header (glue decls + `VBar`) |
| `vgui_glue.cpp` | lifecycle (GLFW + multi-viewport) + the ImPlot swimlane, in C++ |
| `build_deps.sh` | fetch pinned cimgui/cimplot + build `libvgui_c.a` (Linux/WSL **and** Windows) |
| `build_win.sh`  | build the example on Windows/mingw (2-step, works around a V-on-Windows bug) |
| `examples/trace_chart/` | the Trace Chart swimlane ported to this module |
| `shots/`        | screenshots (Linux spike + `windows_multiviewport.png`) |

## Build & run (Linux / WSL)

```sh
sudo apt install libglfw3-dev            # GLFW (X11 build; multi-viewport needs window positioning)
eval/vgui/build_deps.sh                  # clones cimgui/cimplot (pinned) + builds libvgui_c.a
v -path "@vlib|@vmodules|eval" run eval/vgui/examples/trace_chart/trace_chart.v
```

Drag a panel's title bar out → it becomes its own OS window (drag to another monitor). In the
swimlane: **drag = pan, scroll = zoom, double-click = fit** (ImPlot native).

## Windows (mingw / MSYS2) — VERIFIED (2026-07-03)

Built + ran on native Windows 11 (dedicated MSYS2 `C:\dev\msys64-ct`, mingw-w64 gcc 16.1.0, OpenGL
4.6). Multi-viewport spawns **real native Win32 windows** across monitors; event-driven idle CPU
**0.5 % of one core** (~0.03 % of a 16-core box); the exe is **self-contained** (only system DLLs).
Full findings in `docs/gui_toolkit_evaluation.md` → "Windows build check — RESULTS".

```sh
# dedicated MSYS2 MINGW64 shell — don't pollute the user's personal MSYS2
pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-glfw git
sh eval/vgui/build_deps.sh      # clones cimgui/cimplot (pinned) + builds libvgui_c.a
sh eval/vgui/build_win.sh       # builds examples/trace_chart/trace_chart.exe (self-contained)
eval/vgui/examples/trace_chart/trace_chart.exe   # drag the Trace Chart window to a 2nd monitor
```

**Why `build_win.sh` and not `v … run`:** V 0.5.1 (`c0624b2`) **panics on Windows** while driving the
C compiler for this target (`array.push_many: new len exceeds max_int` in
`os__windows_execute_command_line`) — reproducible from MSYS bash *and* PowerShell. The C
compile/link themselves are correct, so `build_win.sh` drives them in 2 steps (V emits C via `-o …c`,
then `gcc` compile + `g++` link). Use `-cc gcc` (V's generated C isn't g++-clean — `char**`/named-
struct casts). Revisit the one-liner on a newer V; it's a V bug, not a vgui one.

The `#flag windows` line in `vgui.v` links static GLFW (`-l:libglfw3.a`) + `-lstdc++`
+ `-static/-static-libstdc++/-static-libgcc` so the exe ships no MinGW runtime DLLs. **MSVC (`cl`)
not yet exercised** (mingw is the primary Windows toolchain; a `cl` pass is a nice-to-have).

## Pinned deps

- cimgui `053280d` (imgui submodule `b61e563` = **1.92.8**, docking)
- cimplot `999ce3e` (implot submodule `1351ab2`)
- GLFW 3.3.10

## Gotchas learned (Linux spike)

- **All TUs must share the same imgui config.** `IMGUI_DISABLE_OBSOLETE_FUNCTIONS` changes
  `sizeof(ImGuiIO)`; mixing it across objects aborts at startup (`Mismatched struct layout!`).
  `build_deps.sh` applies one `$CFG` to every file — keep it that way.
- **imgui 1.92.8 swapped `ImDrawList::AddRect` args** (`…, thickness, flags` now; old
  `…, flags, thickness` is `= delete`).
- **Backends compiled as plain C++** (not `extern "C"`), since only the C++ glue calls them.
- **WSLg capture:** `import -window` returns black for the *main* GL window but captures
  secondary viewport windows fine; the robust path is `vgui_dump_ppm` (glReadPixels `GL_BACK`
  pre-swap) — exposed as `VGUI_SHOT=<path.ppm>`.
