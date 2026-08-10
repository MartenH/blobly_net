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
- 🧭 **DoIP discovery — actually discover.** `discover()` sends a **unicast** vehicle
  identification request to a host you already name, reads one reply and returns. It
  confirms an identity; it cannot find an ECU nobody told it about. That is backwards for a
  bus tester: on CAN you attach and observe because the medium is broadcast, and on Ethernet
  the same tool sees nothing without an address typed in by hand. The asymmetry is real
  today — blobly_emb **already** broadcasts its vehicle announcement three times at boot and
  answers identification requests afterwards, precisely so a late tester can find it. Blobly Net
  hears the answer but not the announcement: `discover()` parses the solicited `0x0004`, and
  misses the unsolicited boot broadcast entirely. Needs a request that collects **many**
  responses instead of returning at the first, a passive listener for unsolicited announcements
  (the case that catches an ECU booting while you are already running), and a Scan action
  turning results into channels rather than hand-typed `doip:` strings.
  **Both address families, and they are not the same mechanism:** IPv4 gets subnet broadcast,
  but IPv6 has no broadcast at all, so it needs link-local multicast. That is not a detail to
  discover during implementation — this repo already supports IPv6 DoIP endpoints
  (`modules/doip/server.v`) and round-trips them in `modules/doip/net_test.v`, so a
  broadcast-only scan would ship "finds any ISO 13400 entity" while leaving a class of entity
  we deliberately support permanently invisible. Core
  tester behaviour, not blobly_emb integration — any ISO 13400 entity answers, and it is
  recorded as a known limitation in the DoIP manual.
- 🧭 **LIN** — `modules/lindb` (LDF) + a `LinFrame` type. Kept type-safe alongside `CanFrame` /
  `EthFrame` rather than faked behind a generic frame.
- 🧭 **Split `cmd/blobly_net/main.v`** — it is **7,200 lines / 217 KB**, and essentially every
  GUI change touches it. The cost is not aesthetic, it is measurable in four places: GitHub
  renders its diffs slowly enough to be painful on every PR; review findings arrive as line
  numbers into one enormous file; two GUI branches almost always collide there; and the editor
  and language server carry it on every keystroke. The split is per-panel (Trace, Graphics,
  System, DBC editor, Diagnostics, Shell, Generators) plus the app state, which is roughly how
  the file is already organised internally — so the panel bodies are a mechanical move rather
  than a redesign. **The app state is not.** `App` embeds the optional modules' types directly
  (`telem.Manifest`, `sysview.System`), so moving panel functions into new files leaves the core
  importing exactly what the tiering item below says it must not. Extracting or abstracting that
  state — an interface, or a side table the optional panels own — is part of this work, not a
  free consequence of it, and it is the part to schedule time for.
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
  than asserted. The **visible** half of this already exists and is the baseline to build on,
  not remaining work: Trace Chart, Flash, Shell and System are already grouped under a
  `blobly_emb target` separator in both the View menu and the activity bar (`main.v` ~1477 and
  ~1562). What is missing is everything behind it — the appearing/disappearing and the import
  boundary.

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
