# Blobly Net

An automotive bus tester written in [V](https://vlang.io). It tests a System Under Test
(SUT) over automotive buses — **CAN / Ethernet / LIN** — starting with **CAN**, **virtual first**
(Linux `vcan0`), with real hardware as a later drop-in.

> Early WIP. See [CLAUDE.md](CLAUDE.md) for architecture, decisions, and roadmap.

## Build & run

```sh
scripts/run.sh                 # build + run the GUI
python3 sut/can_sut.py vcan0   # a virtual ECU on vcan0, in another terminal
```

Requires the V compiler and the `gui` module (+ native deps). Full setup, the
hardware/software-GL notes, and the roadmap are in [CLAUDE.md](CLAUDE.md).

## Scripting & testing

Blobly Net runs **Lua** test scripts (diagnostics, raw frames, DBC signals) against a
CAN setup — headless for CI, or live in the GUI's **Script** panel. No hardware
needed: the runner spins up a simulated bus + ECU for you.

```sh
scripts/runtests.sh tests/diag_basic.lua tests/bus_signals.lua
```

See the **[scripting & test guide](docs/scripting.md)** for the command-line runner
and the full Lua API.

## Docs

- [scripting.md](docs/scripting.md) — Lua scripting + the headless test runner
- [windows_handoff.md](docs/windows_handoff.md) — **start here on the Windows box** (verify PCAN/Kvaser)
- [windows_can_hardware.md](docs/windows_can_hardware.md) — real CAN hardware on Windows (design)
- [windows_build.md](docs/windows_build.md) — native Windows build recipe
- [known_issues.md](docs/known_issues.md) — gotchas (V / gui / rendering / env)
- [CLAUDE.md](CLAUDE.md) — architecture, decisions, full roadmap & status log

## License

MIT — see [LICENSE](LICENSE).
