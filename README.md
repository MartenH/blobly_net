# CANTester

A CANoe-like automotive bus tester written in [V](https://vlang.io). It tests a System Under Test
(SUT) over automotive buses — **CAN / Ethernet / LIN** — starting with **CAN**, **virtual first**
(Linux `vcan0`), with real hardware as a later drop-in.

> Early WIP. See [CLAUDE.md](CLAUDE.md) for architecture, decisions, and roadmap.

## Status

- Phase 0/1: bringing up the GUI (vlang/gui). CAN transport comes next.

## Build & run

```sh
v run src/main.v
```

Requires the V compiler and the `gui` module. See [CLAUDE.md](CLAUDE.md).

## License

MIT — see [LICENSE](LICENSE).
