# Blobly Net

An automotive bus tester written in [V](https://vlang.io). It exercises a System Under
Test (SUT) over **CAN** and **automotive Ethernet** — send and observe traffic, run
diagnostics, script test cases, simulate ECUs, and read back logs — **virtual first**
(Linux `vcan0`), with real hardware as a drop-in.

> Early WIP, but broadly usable. Architecture, decisions and the full status log live
> in [CLAUDE.md](CLAUDE.md).

## What it does

**Buses**
- **CAN / CAN-FD** — SocketCAN on Linux (`vcan0` or real adapters), PCAN on Windows
- **Ethernet** — **DoIP** (UDS over TCP) and **SOME/IP** (incl. an RPC client)
- LIN is on the roadmap, not implemented yet

**Diagnostics** — **UDS** over **ISO-TP** (ISO 15765-2), plus a **flashing** tool that
drives a UDS firmware-download session against a [blobly_emb](docs/blobly_emb_synergies.md)
bootloader.

**Databases & signals** — a native **DBC** parser (`candb`) with a **DBC editor** in the
GUI: decode/encode signals, value tables, multiplexing, and a canonical writer so a
save/load cycle never drifts a file (git diffs show real changes only).

**Simulation** — simulated ECUs that send and answer frames, so tests need no hardware.

**Logs & replay** — `candump -l` files, native **ASAM MDF4** (`.mf4`) reading with no
Python/asammdf dependency, and **replay** of a recording at its original cadence.

**Observability** — a **trace/telemetry** view of a running SUT (handler and thread
swimlanes, CPU load), and a read-only **System** panel showing the modelled network.

**Scripting** — **Lua** test scripts with a small test framework, runnable headless in
CI or live in the GUI.

The GUI is a native **Dear ImGui + ImPlot** application (`cmd/blobly_vgui`).

## Build & run

```sh
scripts/setup_env.sh           # installs toolchain + deps (V, C/C++, GLFW, FreeType)
scripts/run_vgui.sh            # build + run the GUI
python3 sut/can_sut.py vcan0   # a virtual ECU on vcan0, in another terminal
```

Needs the V compiler, a C/C++ toolchain, and GLFW + FreeType (on Debian/Ubuntu:
`sudo apt install libglfw3-dev libfreetype-dev`). See
[windows_build.md](docs/windows_build.md) for the native Windows recipe.

## Scripting & testing

Lua test scripts (diagnostics, raw frames, DBC signals) run headless for CI or live in
the GUI's **Script** panel. No hardware needed — the runner spins up a simulated bus and
ECU for you.

```sh
scripts/runtests.sh tests/diag_basic.lua tests/bus_signals.lua
```

See the **[scripting & test guide](docs/scripting.md)** for the runner and the full Lua API.

## Docs

**Using it**
- [scripting.md](docs/scripting.md) — Lua scripting + the headless test runner
- [dbc_editor.md](docs/dbc_editor.md) — the DBC editor
- [project_editing.md](docs/project_editing.md) — projects, buses and channels
- [bus_config_dialog.md](docs/bus_config_dialog.md) — bus/hardware configuration

**Design**
- [ethernet_architecture.md](docs/ethernet_architecture.md) — DoIP / SOME/IP
- [simulation_architecture.md](docs/simulation_architecture.md) — simulated ECUs
- [blobly_emb_synergies.md](docs/blobly_emb_synergies.md) — the SUT-side companion project

**Platform & troubleshooting**
- [can_hardware.md](docs/can_hardware.md) — real CAN adapters
- [windows_handoff.md](docs/windows_handoff.md) — start here on Windows (PCAN/Kvaser)
- [windows_build.md](docs/windows_build.md) · [windows_can_hardware.md](docs/windows_can_hardware.md)
- [known_issues.md](docs/known_issues.md) — gotchas (V / GUI / rendering / env)

**Project**
- [CLAUDE.md](CLAUDE.md) — architecture, decisions, full roadmap & status log

## License

MIT — see [LICENSE](LICENSE).
