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
| `build_deps.sh` | fetch pinned cimgui/cimplot + build `libvgui_c.a` (Linux/WSL) |
| `examples/trace_chart/` | the Trace Chart swimlane ported to this module |
| `shots/`        | screenshots from the Linux spike |

## Build & run (Linux / WSL)

```sh
sudo apt install libglfw3-dev            # GLFW (X11 build; multi-viewport needs window positioning)
eval/vgui/build_deps.sh                  # clones cimgui/cimplot (pinned) + builds libvgui_c.a
v -path "@vlib|@vmodules|eval" run eval/vgui/examples/trace_chart/trace_chart.v
```

Drag a panel's title bar out → it becomes its own OS window (drag to another monitor). In the
swimlane: **drag = pan, scroll = zoom, double-click = fit** (ImPlot native).

## Windows (mingw / MSYS2) — the recipe to verify

Not yet built on Windows; this is the plan (mirrors `docs/windows_build.md` for the gui app):

1. In the **dedicated** MSYS2 MINGW64 shell (don't pollute the user's personal one):
   `pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-glfw mingw-w64-x86_64-cmake git`
2. `build_deps.sh` should work under MSYS2 as-is (it's plain `git` + `g++`), producing
   `libvgui_c.a`. If `sh` differs, run the same `g++ … -c … && ar rcs …` by hand.
3. V link flags differ on Windows — GLFW/GL libs are `-lglfw3 -lopengl3`/`-lgdi32` etc. The
   `#flag` block in `vgui.v` is currently Linux-only (`-lglfw -lGL -lstdc++ -ldl -lm`); add a
   `#flag windows …` line (see `docs/windows_build.md` for the pattern used by the gui app).
4. Build the example the same way with `v -cc gcc` (mingw) — or MSVC (`-cc cl`); imgui+glfw
   builds under both. Multi-viewport uses the Win32 platform backend (native, no X11).

**Open questions the Windows build must answer:** does cimgui/cimplot + GLFW compile clean under
mingw/msvc; do the V `#flag` link lines resolve; does multi-viewport spawn native Win32 windows;
idle CPU on native Windows (expected far below WSLg — the gui app idles ~0.3% there).

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
