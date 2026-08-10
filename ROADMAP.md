# Blobly Net — Roadmap

The host-side automotive bus tester (CAN + Ethernet protocols), written in V. This file is the
forward-looking "what's coming"; shipped detail lives in git and [`docs/`](docs/), and the
archived development log is [`docs/history.md`](docs/history.md).

Status keys: ✅ shipped · 🔨 in progress · ⏭️ next · 🧭 planned · ⛔ out of scope

---

## Next

- ⏭️ **`fill_rect` / drawlist binding in `vgui`** — the blocker for two shipped-adjacent features:
  **trace-manifest rows** and a **drawn topology graph** in the System panel both wait on it.
- ⏭️ **System wizards** ([`docs/dbc_editor.md`](docs/dbc_editor.md)) — "add a signal/frame"
  generators that emit correctly-shaped TOML blocks to **append**. Deliberately *not* a TOML
  editor: mutations must never rewrite the file, so comments survive and diffs stay clean.
- ⏭️ **UDS server — finish it.** `modules/uds/server.v` already exists and is load-bearing: it
  backs the Lua test runner, the GUI's simulated diagnostics and `doip_smoke`, and it serves
  **0x10** session control, **0x22**/**0x2E** RDBI/WDBI, **0x27** security access, **0x19**
  ReadDTCInformation (sub `0x02` only) and **0x3E** tester present. What is missing:
  - **Config-driven per node** — the biggest gap. `default_server()` is a hardcoded fixture: one
    fixed DID table, one fixed seed/key. A node's DIDs, sessions and security ought to come from
    the project / `system.toml`, so a simulated ECU answers like *that* ECU
    ([`docs/simulation_architecture.md`](docs/simulation_architecture.md)).
  - **0x31 RoutineControl** — start/stop/requestResults; nothing today.
  - **0x11 ECUReset**, **0x14 ClearDiagnosticInformation**, and the remaining **0x19**
    subfunctions beyond `reportDTCByStatusMask`.
  - **Session and security state actually gating access** — a session change is acknowledged but
    does not restrict which services or DIDs are reachable, and `unlocked` is never required.
  - **Per-connection state** for DoIP (shared with the threading item below).

## Planned

- 🧭 **SOME/IP-SD** (service discovery) + the SOME/IP **sim service** — explicitly deferred in
  [`docs/ethernet_architecture.md`](docs/ethernet_architecture.md).
- 🧭 **DoIP per-connection handler state** — deferred pending the threading change.
- 🧭 **Vector (XL family) CAN backend** — the notable gap in vendor coverage; PCAN and Kvaser
  are done, and `transport` is designed for drop-in backends, so it is a shim + bitrate map.
- 🧭 **LIN** — `modules/lindb` (LDF) + a `LinFrame` type. Kept type-safe alongside `CanFrame` /
  `EthFrame` rather than faked behind a generic frame.
- 🧭 **Split `cmd/blobly_net/main.v`** — it is **7,200 lines / 217 KB**, and essentially every
  GUI change touches it. The cost is not aesthetic, it is measurable in four places: GitHub
  renders its diffs slowly enough to be painful on every PR; review findings arrive as line
  numbers into one enormous file; two GUI branches almost always collide there; and the editor
  and language server carry it on every keystroke. The split is per-panel (Trace, Graphics,
  System, DBC editor, Diagnostics, Shell, Generators) plus the app state, which is roughly how
  the file is already organised internally — so it is a mechanical move rather than a redesign.
  Deliberately **not** urgent: it touches the one file every in-flight branch also touches, so
  it wants a quiet moment with nothing else open, not a slot between features. It is also the
  **lever for the tiering below** — panels cannot be separated while they all live in one file.
- 🧭 **Tier the UI: standard tester vs. blobly_emb integration.** Most people who pick this up
  want the ordinary thing — trace, DBC decode, send, generators, simulation, diagnostics,
  scripting, logging. A large part of the GUI is not that: the **Shell** (93 references in
  `main.v`), **flash** (81), the **trace manifest** and swimlane (84), the **System** panel and
  `system.toml` (17), and the SOME/IP module bindings (13), plus the `sysview`, `telem` and
  `flash` modules and the `flash` / `trace_dump` CLI tools. All of it speaks protocols and
  config formats that only **blobly_emb** produces, so for anyone without that stack it is
  surface area that cannot do anything — the README already has to explain that several panels
  "have nothing to talk to".
  The fix is not a build flag (that fragments testing) but two cheaper moves: **discovery** —
  a panel appears when its artifact is present (a `system.toml` beside the project, a manifest
  on a channel, a bootloader-capable target) rather than always; and a **module boundary** —
  the core must not import `sysview`/`telem`/`flash`, so "works without emb" is enforced rather
  than asserted. Grouping the optional panels under one menu section makes the tiering visible
  without hiding anything from those who want it.

## Out of scope

- ⛔ **Automotive Ethernet PHYs** (100BASE-T1, 1000BASE-T1) and **TSN/AVB**. Ethernet here is
  ordinary TCP/UDP sockets; what is automotive is the protocols on top (DoIP, SOME/IP).

---

## Cross-repo: blobly_emb

blobly_net is the **tester**; [blobly_emb](docs/blobly_emb_synergies.md) is the **SUT** (the
embedded ECU stack). Wire formats — trace records, SOME/IP datagrams, telemetry, the flashing
protocol — are pinned by **golden vectors on both sides**, so they change together. When emb adds
a wire-visible feature, the matching host support usually lands here in the same period.

---

## Already shipped

Kept last: this is where the roadmap ends, not where it starts.

**Buses & transport**
- ✅ **SocketCAN** (Linux) — `vcan0` virtual and real adapters
- ✅ **PEAK PCAN** and ✅ **Kvaser** (Windows) — vendor DLLs at runtime, both hardware-verified
- ✅ UDP software bus (`inproc:`) — driver-free tests and demos

**CAN & databases**
- ✅ Live trace, send panel, signal decode
- ✅ **DBC** parse/decode/encode (`candb`), incl. multiplexing and value tables
- ✅ **DBC editor** — forms, bit-matrix grid, live-loop save, read-only while running, and a
  **canonical writer** so a save/load cycle never drifts a file (git diffs show real changes only)

**Diagnostics**
- ✅ **ISO-TP** (ISO 15765-2) · ✅ **UDS client** · ✅ **DoIP** (ISO 13400 — UDS over TCP)
- ✅ **Flashing** — `cmd/flash` + the GUI Flash panel; UDS firmware download against a
  blobly_emb bootloader, with **0x29 challenge/response** auth (retired 0x27 seed/key)

**Ethernet services**
- ✅ **SOME/IP** — 16-byte header codec, envelope validation, golden vectors, and an **RPC client**
  (with the eth shell in the GUI) cross-checked against blobly_emb by an oracle

**Simulation, logs & replay**
- ✅ Simulated ECUs (`sim`) — tests need no hardware
- ✅ `candump -l` logs · ✅ native **ASAM MDF4** (`.mf4`) reader
- ✅ **Replay** at the recording's original cadence

**Observability**
- ✅ **Trace chart** — handler/thread swimlanes, derived idle lane, execution-vs-response bars,
  preemption cut-links, per-core lanes, RTOS priority labels, multi-block dump
- ✅ **Cross-core time correlation** — a satellite core's block carries its measured clock offset
  and the error bound, so a multi-core swimlane is one timeline instead of several
- ✅ **System panel** (`sysview`) — read-only view of a blobly_emb `system.toml` + node
  `ecu.toml`s: communication matrix, node identities, per-bus id allocation with collisions
- ✅ **Shell panel** — interactive console to the target over CAN

**Platform**
- ✅ **Dear ImGui + ImPlot** GUI · ✅ Windows build + CI
- ✅ **Lua scripting** — test framework, headless runner for CI, Script panel in the GUI
- ✅ `.blobnet` project files
