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

- 🧭 **Rest bus from a real recording** ([#98](https://github.com/MartenH/blobly_net/issues/98)) —
  drive the surrounding ECUs from a capture of the actual vehicle instead of hand-written signal
  generators, so the SUT hears its real environment. `modules/player` already decodes `.log` and
  `.mf4` with play/seek/loop, and `replay:` is already in the project schema; what is missing is
  a worker and `monitorable()` accepting those channels. The design question is the
  **subtraction** — a capture contains the ECU under test, so replaying it verbatim puts two
  transmitters on every one of its ids (exactly the collision the trace's `origin` column now
  makes visible). The DBC names each message's sender, which is what makes that solvable.

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
  The **passive listener has shipped**: `doip.collect_announcements()` (Lua
  `doip.listen(window_ms)`) hears unsolicited announcements and returns each sender's endpoint,
  and a simulated entity announces itself at Start — so the ECU-booting-while-you-watch case is
  covered in both directions. What remains is a request that collects **many** responses instead
  of returning at the first, and a **Scan** action turning results into channels rather than
  hand-typed `doip:` strings — for the ECU that neither announced while you were listening nor
  sits at an address you know.
  (a) *Keep the source address.* `discover()` throws it away (`n, _ := u.read`) and
  `VehicleInfo` carries only VIN, logical address, EID and GID — none of which is an endpoint.
  A channel needs `doip:<host>[:<port>]`, so without retaining each responder's source (with
  the IPv6 scope id where there is one) a Scan can list identities it cannot connect to.
  (b) *Answer on the entity side.* `DoipServer.listen()` binds UDP to its own unicast
  `host:port` and joins no multicast group, so the simulated entities receive neither an IPv4
  subnet broadcast nor an IPv6 multicast — change only the requester and the repo's own
  virtual ECUs stay silent, leaving nothing to test against. The entity-side socket and
  hermetic tests belong in this item.
  (c) *Send per interface.* Link-scoped multicast needs an outbound interface, and one send
  covers one link; a multi-homed host must enumerate eligible interfaces and transmit on each,
  keeping the scope that replied.
  **Both address families, and they are not the same mechanism:** IPv4 gets subnet broadcast,
  but IPv6 has no broadcast at all, so it needs link-local multicast. That is not a detail to
  discover during implementation — this repo already supports IPv6 DoIP endpoints
  (`modules/doip/server.v`) and round-trips them in `modules/doip/net_test.v`, so a
  broadcast-only scan would ship "finds any ISO 13400 entity" while leaving a class of entity
  we deliberately support permanently invisible. Core
  tester behaviour, not blobly_emb integration — any ISO 13400 entity answers, and it is
  recorded as a known limitation in [`docs/doip.md`](docs/doip.md).
- 🧭 **LIN** — `modules/lindb` (LDF) + a `LinFrame` type. Kept type-safe alongside `CanFrame` /
  `EthFrame` rather than faked behind a generic frame.
- 🧭 **Split `cmd/blobly_net/main.v`** — it is **7,475 lines / 231 KB** (measured 2026-08-10; it only grows), and essentially every
  GUI change touches it. The cost is not aesthetic, it is measurable in four places: GitHub
  renders its diffs slowly enough to be painful on every PR; review findings arrive as line
  numbers into one enormous file; two GUI branches almost always collide there; and the editor
  and language server carry it on every keystroke. The split is per-panel (Trace, Graphics,
  System, DBC editor, Diagnostics, Shell, Generators, and **Flash** — `draw_flash`, its worker
  and their state, without which the core keeps importing `flash` and the module boundary below
  cannot hold) plus the app state, which is roughly how
  the file is already organised internally — so the panel bodies are a mechanical move rather
  than a redesign. **Two things around them are not.**
  First, **the build entry point has to move with them.** Every build names the single file:
  `scripts/run_gui.sh` (lines 36 and 89-92) and `.github/workflows/windows.yml` (line 107) all
  pass `cmd/blobly_net/main.v` — and so does line 45, which *re-assigns* the target after a
  `.blobnet` argument has been moved into `BLOBLY_PROJECT`, so fixing only the default leaves
  `run_gui.sh project.blobnet` broken. V compiling one file does not pull in its siblings, so the
  moment a panel leaves `main.v` those builds fail on undefined symbols — locally, in CI and on
  the Windows bundle at once. Switch them to compile the directory, or make the panels imported
  modules; either way it lands in the same commit as the first move, with all three builds
  verified, not afterwards.
  Second, **the app state — and the core paths that speak telemetry.** `App` embeds the optional modules' types directly
  (`telem.Manifest`, `sysview.System`), so moving panel functions into new files leaves the core
  importing exactly what the tiering item below says it must not. Extracting or abstracting that
  state — an interface, or a side table the optional panels own — is part of this work, not a
  free consequence of it, and it is the part to schedule time for.
  It reaches past the state, too: `telem` appears **43 times** in `main.v`, and not only in
  panels. `TRec` — the core trace row — embeds a `telem.Record` (~55-60); the CAN RX path
  decodes trace responses inline (~862); and project rebuilding loads and classifies manifests
  (~1083-1101). Those are core responsibilities that happen to speak an optional module's
  types, so no amount of moving *panels* dislodges them. They go behind a callback the
  optional panel registers, or into the telemetry-owned file — decided as part of this item,
  because it is what determines whether `core must not import telem` is achievable at all.
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
  a panel is *promoted* when its artifact is present (a `system.toml` beside the project, a
  manifest on a channel, a bootloader-capable target) rather than being equally prominent
  always; and a **module boundary** —
  the core must not import `sysview`/`telem`/`flash`, so "works without emb" is enforced rather
  than asserted. The **visible** half of this already exists and is the baseline to build on,
  not remaining work: Trace Chart, Flash, Shell and System are already grouped under a
  `blobly_emb target` separator in both the View menu and the activity bar (`main.v` ~1477 and
  ~1562). One *promotion* also already ships: `load_project` finds a `system.toml` beside the
  project and sets `show_sys = sys_loaded` (`main.v` ~961), opening the System panel by itself.
  So the remaining promotion work is the manifest and bootloader cases, not all three.
  **Discovery must not gate the entry points that create the thing being discovered.** Two in
  particular are circular: the System panel holds the *only* `system.toml` path input
  (`main.v` ~7187), so hiding it until a `system.toml` is found beside the project leaves no
  way to open one from anywhere else; and the Flash panel is where a running application is
  driven into its bootloader, so hiding it until a bootloader is on the bus means it never
  will be. The project schema stores neither a system path nor a target capability, so a user
  cannot configure their way out either. Promotion may reorder, collapse or de-emphasise —
  it may not be the only route to a panel that is itself the precondition.

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
