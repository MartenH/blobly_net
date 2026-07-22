# vgui — V binding for Dear ImGui + ImPlot

A small, reusable V module wrapping **Dear ImGui** (docking / multi-viewport) + **ImPlot**,
on a **GLFW + OpenGL3** backend.

**Status: this is the GUI layer of blobly_net.** `cmd/blobly_net` is built on it — every
panel, plot and widget in the app is a `vgui.*` call, and CI compile-links it on Linux and
Windows on every push. It started life as a spike to evaluate migrating off `vlang/gui`
(structurally single-window); that migration landed 2026-07-06 and the rationale is preserved
in **`docs/gui_toolkit_evaluation.md`**.

It stays a **standalone module** rather than app code: the API is generic ImGui/ImPlot, the
`examples/` build without the app, and keeping the C ABI small is what makes imgui version
bumps survivable.

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
| `build_win.sh`  | 2-step Windows build of the example — a fallback; see the note below |
| `examples/trace_chart/` | swimlane demo importing only `os` + `vgui`. **CI builds this with `modules/` OFF the path**, which is what proves this module has no app dependency |
| `shots/`        | screenshots from the toolkit evaluation, referenced by `docs/gui_toolkit_evaluation.md` |

## Build & run (Linux / WSL)

Dependencies match what CI installs (`.github/workflows/ci.yml` is the source of truth):

```sh
sudo apt install g++ pkg-config libglfw3-dev libfreetype-dev libgl1-mesa-dev
libs/vgui/build_deps.sh                  # clones cimgui/cimplot (pinned) + builds libvgui_c.a
v -path "@vlib|@vmodules|libs" run libs/vgui/examples/trace_chart/trace_chart.v
```

Drag a panel's title bar out → it becomes its own OS window (drag to another monitor). In the
swimlane: **drag = pan, scroll = zoom, double-click = fit** (ImPlot native).

## Windows (mingw / MSYS2)

Built by CI on every push — `.github/workflows/windows.yml` is the reproducible recipe, and it
produces the prebuilt `blobly_net.exe` bundle the top-level README points users at. Multi-viewport
spawns **real native Win32 windows** across monitors; event-driven idle CPU **0.5 % of one core**
(~0.03 % of a 16-core box); the exe is **self-contained** (only system DLLs). Original findings in
`docs/gui_toolkit_evaluation.md` → "Windows build check — RESULTS".

```sh
# dedicated MSYS2 MINGW64 shell — don't pollute the user's personal MSYS2
pacman -S --needed git mingw-w64-x86_64-{gcc,pkgconf,glfw,freetype,harfbuzz,glib2,fribidi,fontconfig}
sh libs/vgui/build_deps.sh      # clones cimgui/cimplot (pinned) + builds libvgui_c.a
v -cc gcc -path "@vlib|@vmodules|libs" -o trace_chart.exe \
  libs/vgui/examples/trace_chart/trace_chart.v
```

**On `build_win.sh`:** V 0.5.1 (`c0624b2`) panicked on Windows while driving the C compiler
(`array.push_many: new len exceeds max_int` in `os__windows_execute_command_line`), so that script
splits the build in two (V emits C, then `gcc` compile + `g++` link). **CI no longer needs it** —
it builds the app with the plain one-liner against the pinned master V, so the bug is gone on
current V. `build_win.sh` is kept as a fallback if it ever returns. Use `-cc gcc` either way:
V's generated C isn't g++-clean (`char**`/named-struct casts).

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
