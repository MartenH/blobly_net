# GUI toolkit evaluation — vlang/gui vs Dear ImGui + ImPlot

**Status (2026-07-03):** spike complete on Linux/WSL; **Windows build check pending**. No decision
committed. The app still runs on `vlang/gui`. The spike code lives in `eval/vgui/` (a reusable
`vgui` V module + a Trace Chart example); nothing in the main app depends on it.

## Why we're looking

`vlang/gui` is built on **sokol_app, which owns exactly one OS window** — this is structural, not
a missing feature. A CANoe-class multi-monitor tool eventually needs to tear panels into separate
OS windows (Trace on one monitor, Graphics/Diagnostics on another). Three forces push off gui:

1. **Multi-window** — impossible in sokol_app.
2. **Maintenance risk** — the gui author left V (rebuilding as go-gui); we carry local patches to
   gui **and** vglyph **and** V, and every bump risks breaking us.
3. **Immaturity tax** — real time spent this project on gui bugs (blank centered text, glyph-outline
   crashes, the closure-context leak, dock-tab separator, vertex-overflow blanking, …).

Counterweight — **sunk cost is smaller than it looks:** the engine (`transport`, `candb`, `isotp`,
`uds`, `doip`, `telem`, `sim`, `player`, `canlog`, `mf4`, `script`) is deliberately **GUI-free**, so
a swap is a `src/main.v` rewrite against a new toolkit, not a rearchitecture. That layering held.

## What the spike proved (Linux/WSL)

| Question | Result |
|---|---|
| **Multi-window under WSLg** | ✅ Dear ImGui **docking-branch multi-viewport** creates real, independent OS windows. Verified **3 simultaneous X11 windows** (main + Trace table + Graphics/swimlane); the swimlane window landed on the **second monitor** — the exact thing gui can't do. |
| **V can drive it** | ✅ A clean V module (`eval/vgui`) over a curated scalar C ABI on **cimgui + cimplot** + GLFW. V owns the loop, timing, and UI (table built from V structs; swimlane fed V `Bar` data). `v -cc gcc` links it. |
| **ImPlot for the swimlane** | ✅ Big win — the swimlane is an ImPlot plot with **native drag-to-pan, scroll-to-zoom, double-click-fit, and a time axis**, replacing the entire hand-rolled zoom-buttons + scrollbar. Overrun bars, preemption hatch, lane bands all draw via the plot draw list. |
| **CPU (the crux)** | ⚠️→✅ Naive poll loop (60fps) = **~340 % of a core** idle — the trap. **Event-driven** (`glfwWaitEvents`, wake on input or a posted event, like gui's `queue_command`) = **~4 % @1-2fps under WSLg → ~0 % pure-wait**. Matchable to gui, but only with deliberate discipline. RX/sim threads would `glfwPostEmptyEvent()` to wake a repaint. |

Screenshots in `eval/vgui/shots/`:
- `trace_chart_second_monitor.png` — the ImPlot swimlane in its own OS window (Arm/Dump/Fit, time axis, 3 lanes, overrun bar).
- `trace_chart_and_table.png`, `v_driven_table_window.png`, `v_driven_plot_window.png` — V-driven windows.

## Costs / caveats

- **Typography downgrade** — imgui's bitmap font vs gui/vglyph's Pango/HarfBuzz shaping. Fine for a
  tool; less polished text.
- **CPU discipline is ongoing** — the event-driven loop must be maintained; easy to regress to the
  340 % poll loop.
- **Build complexity** — C++ libs (cimgui/cimplot) + GLFW on **both** Linux and Windows (mingw/msvc).
  Linux done; **Windows unverified** (next step).
- **Screenshot workflow** — `import -window` returns black for the main GL window under WSLg (captures
  secondary viewports fine); use the `VGUI_SHOT` glReadPixels(GL_BACK) dump for headless capture.
- **The binding is real but mechanical** — a curated facade (our choice) is far less fragile than a
  raw ~800-fn cimgui binding (cf. `nsauzede/vig`, which hand-mirrors `ImGuiIO` and rots on imgui bumps).

## Prior art considered

- **`nsauzede/vig`** — a V/cimgui/SDL2 wrapper (last touched 2024, pre-docking, no ImPlot). Confirmed
  cimgui is the right C layer, but its hand-mirrored structs are a maintenance trap; `vgui` uses a
  small glue instead. Not reused directly.

## Recommendation

Both scary unknowns cleared (multi-window works; CPU is matchable). Given multi-window is **impossible**
in gui, plus the maintenance/stagnation risk and ImPlot's fit for our plot-heavy roadmap, **lean toward
migrating**, executed as a **phased port** (engine untouched; panel by panel: Trace → Buses → Signals →
Graphics → Trace Chart → Diagnostics → …). The Trace Chart slice already looks *better* on imgui+ImPlot
than the hand-rolled gui version.

**Gate the decision on the Windows build check** (below). If cimgui/cimplot + GLFW build clean on
mingw/msvc, the `#flag windows` link line resolves, and multi-viewport spawns native Win32 windows at
acceptable idle CPU, then migrate. If Windows fights it, reassess.

## Next: Windows build check (the remaining Task-A step)

Build `eval/vgui` on the Windows machine (dedicated MSYS2, per `docs/windows_build.md`):

1. `pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-glfw mingw-w64-x86_64-cmake git`
2. Run `eval/vgui/build_deps.sh` (plain git+g++; should work under MSYS2) → `libvgui_c.a`.
3. Add a `#flag windows …` link line to `eval/vgui/vgui.v` (GLFW/GL/win32 libs — see the gui app's
   `docs/windows_build.md` pattern), then `v -cc gcc -path "@vlib|@vmodules|eval" run
   eval/vgui/examples/trace_chart/trace_chart.v`.
4. Confirm: clean build (mingw + ideally msvc), multi-viewport spawns native Win32 windows across
   monitors, and idle CPU (event-driven) — expected well below WSLg (gui idles ~0.3 % on native Win).

Record results back in this doc + `eval/vgui/README.md`, then make the migrate/stay call.
