# GUI toolkit evaluation — vlang/gui vs Dear ImGui + ImPlot

**Status (2026-07-03):** spike complete on Linux/WSL **and Windows** — **both build checks GREEN**.
No decision committed yet (user's call). The app still runs on `vlang/gui`. The spike code lives in
`eval/vgui/` (a reusable `vgui` V module + a Trace Chart example); nothing in the main app depends on
it. See "Windows build check — RESULTS" below.

## Why we're looking

`vlang/gui` is built on **sokol_app, which owns exactly one OS window** — this is structural, not
a missing feature. A professional-class multi-monitor tool eventually needs to tear panels into separate
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

**The Windows build check is now GREEN** (results below) — the gate is cleared. Given multi-window is
**impossible** in gui, plus the maintenance/stagnation risk and ImPlot's fit, the recommendation stands:
**migrate, phased**. The remaining friction is a V-side build bug (a one-command `v run` panic on
Windows, worked around by a 2-step build — see below), not a toolkit problem.

## Windows build check — RESULTS (2026-07-03, mingw-w64)

Ran on native Windows 11 (dedicated MSYS2 `C:\dev\msys64-ct`, **mingw-w64 gcc 16.1.0**, V 0.5.1
`c0624b2`, Intel Arc GPU / **OpenGL 4.6**). All four questions answered — screenshot
`eval/vgui/shots/windows_multiviewport.png`:

| Question | Result |
|---|---|
| **cimgui/cimplot + GLFW compile (mingw)** | ✅ `build_deps.sh` built `libvgui_c.a` clean (imgui 1.92.8 + implot + GLFW 3.x static) — only deprecation warnings. `pacman -S mingw-w64-x86_64-glfw` supplies static `libglfw3.a`. |
| **`#flag windows` link resolves** | ✅ Links a **self-contained** exe — deps are only system DLLs (kernel32/user32/gdi32/shell32/opengl32/msvcrt), no MinGW runtime. Flags: static glfw (`-l:libglfw3.a`) + `-lstdc++ -static-libstdc++ -static-libgcc -static` + win32 libs. Verified with both the `gcc` and `g++` drivers. |
| **Multi-viewport → native Win32 windows** | ✅ The single process owns **2 real top-level Win32 windows** (verified via `EnumWindows`): the main GLFW window + a detached **`Trace Chart`** OS window that renders the ImPlot swimlane and sits outside the main window's screen rect (drag to a 2nd monitor). Both render correctly (table + colored swimlane bars/overrun/preemption). |
| **Idle CPU (event-driven, native)** | ✅ **0.5 % of one core (0.03 % of the 16-core system)** at idle, working set ~84 MB. Beats WSLg's ~4 % and is on par with gui's ~0.3 %. The 340 % naive-poll trap does not apply to the event-driven loop. |

### ⚠️ One caveat — a V (not vgui) build bug on Windows
`v -cc gcc … run eval/vgui/examples/trace_chart/trace_chart.v` **panics inside V** on this Windows V
(0.5.1 `c0624b2`): `array.push_many: new len exceeds max_int` in `os__windows_execute_command_line`
while V drives the C compiler. Reproducible from **both** MSYS bash and PowerShell (not a shell
artifact); blobly_net's own `src/main.v` build is unaffected, so it's target-specific (likely the
C++ static-archive link invocation). The C compile and link themselves are correct — verified by
running them directly. **Workaround:** the 2-step **`eval/vgui/build_win.sh`** (V emits C via `-o …c`,
then gcc compile + g++ link). Revisit the one-liner on a newer V; worth a minimal `v bug` report.
`-cc g++` is *not* a fix — V's generated C uses `char**`/named-struct pointer casts that g++ rejects
as errors (gcc treats them as warnings), so `gcc` is the required driver.

### Reproduce
```sh
# dedicated MSYS2 MINGW64 shell (C:\dev\msys64-ct)
pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-glfw git
sh eval/vgui/build_deps.sh      # -> libvgui_c.a
sh eval/vgui/build_win.sh       # -> examples/trace_chart/trace_chart.exe (self-contained)
eval/vgui/examples/trace_chart/trace_chart.exe            # event-driven
VGUI_POLL=1 VGUI_FRAMES=40 VGUI_SHOT=shot.ppm eval/vgui/examples/trace_chart/trace_chart.exe  # headless
```

### Not done
- **MSVC (`cl`)** build — only mingw was exercised. cimgui/implot/glfw all support MSVC; a `cl` pass is
  a nice-to-have, not a blocker (mingw is blobly_net's primary Windows toolchain anyway).

## Live-data integration check — RESULTS (2026-07-03, WSL/vcan0)

The last integration risk: a background CAN **RX thread** driving the **event-driven** render loop,
the way the migrated app would (gui does this with `queue_command`; imgui with `glfwPostEmptyEvent`).
`eval/vgui/examples/live_trace/live_trace.v` — a real `transport` bus RX thread appends frames under a
mutex and calls `vgui.wake()`; the UI thread blocks in `glfwWaitEvents` and repaints on wake. Verified
live on `vcan0` with `cangen`:

| Check | Result |
|---|---|
| **RX thread → wake → render** | ✅ Live frames flow to the table; CPU responds only when traffic arrives (no traffic → stays at idle). |
| **Coalescing is mandatory** | ⚠️→✅ Waking on **every** frame = the poll trap: a 1000 msg/s bus drove **350 %** of a core. Fix = **coalesce repaint requests** (frames still accumulate every RX; the wake is rate-limited) — the *same* batched-repaint discipline `src/main.v` already uses (`App.fps`). |
| **CPU bounded, scales with cap** | ✅ Under a saturated 1000 msg/s flood (WSLg): 60fps→120 %, 30fps→80 %, **5fps (app default)→20 %** of a core. CPU tracks the repaint cap, ~independent of traffic — matches the gui app's measured property. Native Windows lacks WSLg's GL tax (idle 0.5 % there), so far lower. |
| **Memory** | ✅ **No leak.** RSS reaches a working-set plateau (~128 MB) and holds **dead flat for 2 min** under the worst case (1000 msg/s + 60 fps repaint). Unlike the V-closure leak that plagued gui — imgui is immediate-mode (no per-frame retained allocs) and the example builds no per-frame capturing closures. |

**Conclusion:** the live path is de-risked. The mitigation (coalesced wake + an fps cap) is identical to
what the app already does, just via `glfwPostEmptyEvent`. **Cleared to start the phased migration.**

Reproduce:
```sh
eval/vgui/build_deps.sh
v -enable-globals -cc gcc -path "@vlib|@vmodules|modules|eval" run \
  eval/vgui/examples/live_trace/live_trace.v vcan0        # then: cangen vcan0   (VGUI_WAKE_MS caps repaint)
```
