# Ethernet architecture — DoIP first, SOME-IP later

Agreed 2026-06-29. The plan for bringing **automotive Ethernet protocols** into blobly_net, starting with
**DoIP** (diagnostics over IP, ISO 13400) and deferring **SOME-IP** (service-oriented middleware).
This mirrors `docs/simulation_architecture.md` — design captured before building, oracle-first.

> **Looking for how to use DoIP?** This is the design record — why DoIP came before SOME/IP,
> how the modules are laid out, and how they are verified. For ports, the message flow, what
> is and is not broadcast, and how to point the app at an ECU, see
> [`doip.md`](doip.md).

## Why DoIP first

DoIP is just **UDS-over-IP**: it carries the same UDS (ISO 14229) diagnostic payloads our
`modules/uds` stack already speaks, only over TCP/IP instead of ISO-TP/CAN. That makes it the
cheapest possible Ethernet beachhead:

- **The whole UDS stack is reused unchanged.** `uds.Client` and `uds.Server` are written against the
  `isotp.Channel` interface (`send`/`recv`/`close`/`diagnostics` + `iface`/`tx_id`/`rx_id`;
  `diagnostics()` is what the carrier counted that no PDU carried, and a TCP connection has
  nothing to say). A DoIP connection
  **implements that same interface** — exactly the trick `isotp.SoftChannel` uses for the in-proc CAN
  bus. So `uds.new_client(doip_channel)` and `uds.Server.serve(mut doip_channel, stop)` work with no
  changes. The "carrier swap" seam we built for CAN pays off again.
- **No virtual device, no driver, every platform.** Unlike CAN (which needs vcan0 / a vendor driver),
  DoIP runs on plain **localhost TCP/UDP** — real, native, driver-free on Linux *and* Windows. The
  virtual-first flow needs nothing installed.
- **Independent oracle exists.** scapy's `automotive.doip` is a third-party DoIP implementation, the
  same role `dbc_oracle.py` / `uds_server.py` play for their modules.

SOME-IP is a different animal — event/RPC middleware with its own service discovery; it does *not*
ride the UDS stack. It gets its own module after DoIP lands (see bottom).

## DoIP on the wire (ISO 13400-2), the subset we implement

Default port **13400** (TCP for diagnostics, UDP for discovery). Every message is an **8-byte generic
header** + payload:

```
offset  size  field
0       1     protocol version        (0x02 = 2012, 0x03 = 2019; we send 0x02)
1       1     inverse protocol version (~version, 0xFD)
2       2     payload type            (big-endian u16)
4       4     payload length          (big-endian u32, = payload bytes that follow)
8       N     payload
```

Payload types we handle:

| Type   | Name                                   | Transport | Direction      |
|--------|----------------------------------------|-----------|----------------|
| 0x0001 | Vehicle identification request         | UDP       | tester → ECU   |
| 0x0004 | Vehicle announcement / ident. response | UDP       | ECU → tester   |
| 0x0005 | Routing activation request             | TCP       | tester → ECU   |
| 0x0006 | Routing activation response            | TCP       | ECU → tester   |
| 0x8001 | Diagnostic message (carries UDS)       | TCP       | both           |
| 0x8002 | Diagnostic message positive ack        | TCP       | ECU → tester   |
| 0x8003 | Diagnostic message negative ack        | TCP       | ECU → tester   |

Payload layouts:

- **Routing activation request (0x0005):** source addr(2) · activation type(1, 0x00=default) ·
  reserved-ISO(4, zero). (Optional OEM 4 bytes omitted.)
- **Routing activation response (0x0006):** tester logical addr(2) · entity logical addr(2) ·
  response code(1, **0x10 = success**) · reserved-ISO(4). (Optional OEM 4 bytes omitted.)
- **Diagnostic message (0x8001):** source addr(2) · target addr(2) · UDS user data(N).
- **Diagnostic message positive ack (0x8002):** source addr(2) · target addr(2) · ack code(1, 0x00).
- **Vehicle announcement (0x0004):** VIN(17) · logical addr(2) · EID(6) · GID(6) ·
  further-action(1). (We omit the optional sync-status byte.)

Logical addresses are 16-bit. We map the `isotp.Channel` fields `tx_id`→tester source address,
`rx_id`→ECU target address (they're `u32`, a 16-bit address fits).

A tester's exchange: TCP connect → routing activation (0x0005) → await 0x0006 code 0x10 → send a
diagnostic message (0x8001 wrapping a UDS request) → receive the positive ack (0x8002, skipped) then
the response diagnostic message (0x8001 wrapping the UDS response). Discovery is orthogonal: UDP
identification request (0x0001) → vehicle announcement (0x0004).

## Module layout

```
modules/doip/
  doip.v      pure framing: header encode/parse, payload-type consts, builders+parsers for the
              messages above. GUI-free, protocol-only, hermetic tests. NO imports of uds/isotp.
  client.v    DoipClient — TCP tester. Implements isotp.Channel (structural): send() wraps UDS in a
              0x8001 diag message, recv() reads frames and returns the UDS user-data (skips 0x8002
              acks). open_doip() does connect + routing activation. So uds.Client rides it unchanged.
  server.v    DoipServer — TCP/UDP ECU sim. Accepts a connection, answers routing activation, acks +
              forwards each diag message's UDS bytes to a `handler fn([]u8) []u8` callback, sends the
              reply as a 0x8001. UDP: answers 0x0001 with a 0x0004 announcement. uds-AGNOSTIC (the
              caller wires uds.Server.handle as the handler) so doip stays a transport, not a protocol.
```

`doip` imports neither `uds` nor `isotp` (only `transport`, for the `BusDiagnostics` type the
channel interface returns): the client satisfies `isotp.Channel` *structurally* (V interfaces are
structural), and the server takes a plain callback. This keeps the dependency arrow one-way
(`uds → isotp`; `cmd/* → doip + uds`) — same hygiene as `transport`/`isotp`.

## Verification (oracle-first, same discipline as every module)

1. **V client ↔ V server** over real localhost TCP (`cmd/doip_smoke`): drive `uds.Client` over the
   DoIP channel — session (0x10), RDBI VIN (0x22/0xF190), a negative response — plus a UDP discovery
   round-trip. This is the primary hermetic end-to-end.
2. **scapy oracle** (`sut/doip_server.py`, scapy `automotive.doip`, in a venv): an independent DoIP
   entity. Cross-checks our framing on the wire both ways (our client vs scapy server, and scapy
   client vs our server), the role `uds_server.py` plays for `modules/uds`.
3. Hermetic framing tests in `modules/doip/doip_test.v` (round-trip every builder/parser).

## App wiring (phase E2) — ✅ DONE 2026-06-29

- **Project config** gained a DoIP channel form: `type: doip` with `interface: doip:<host>[:<port>]`
  plus `tester_address` / `ecu_address` (logical addresses, default 0x0E80 / 0x1000). Bitrate/timing
  are meaningless for Ethernet and ignored. `project.Channel.is_doip()` + `doip_endpoint()` parse it;
  the addresses round-trip through Save. `projects/doip-demo.blobnet` runs the entity driver-free.
- **NOT wired into `transport.open()`** (a deliberate deviation from the original sketch): that returns
  a `transport.Bus` — a CAN-*frame* pipe — but DoIP is a diagnostics carrier with no frames to monitor.
  The real carrier-swap seam is one level up at `isotp.Channel`, which is where the Diagnostics panel
  already operates and where `DoipClient` plugs in. So DoIP is wired at the diagnostics layer instead.
- **Start/Stop:** a DoIP channel opens no `Bus` and no RX thread. `start_doip_hosts()` walks the
  project's DoIP channels — enabled or not, so a channel enabled later still has a supervisor —
  and spawns a `doip_watch` per channel that simulates an ECU. What it serves comes from
  `sim.doip_entity()`, shared with the headless runner so the GUI cannot announce differently:
  the first configured `uds:` node's server, or `uds.default_server()` when none is configured.
  A channel with no simulated node is tester-only and nothing is bound.
- **GUI Diagnostics panel:** `diag_targets()` (`diag.v`) enumerates every addressable ECU —
  per-node CAN servers, the DoIP channels this run is hosting, and enabled tester-only DoIP
  channels (a channel that simulates an ECU but whose host failed to bind is deliberately
  left out: the endpoint belongs to whoever else holds it) — and
  `diag_worker()` opens the carrier the *selected* target names: `doip.open_doip(...)` for DoIP,
  software ISO-TP otherwise, so `uds.Client` rides either unchanged. Each entry's label carries
  its carrier and address (`SUT on DoIP1 (DoIP 0x1000)`). **Verified** end-to-end: the GUI
  (autostart + `doip-demo.blobnet`) serves the entity on 127.0.0.1:13400 and an external UDS
  client reads VIN `BLOBLYNETV0SUT001` over Ethernet.

## Known limitations (virtual-first scope)

- **Single connection at a time.** `DoipServer` serves one accepted TCP connection
  to completion (`accept_and_serve` → `serve_connection`) before accepting the next,
  with a 60 s per-read timeout. A stale/idle peer can therefore delay other testers'
  routing activation. This is intentional for now: the entity is driven by a single
  tester at a time, and a thread-per-connection model would run multiple testers'
  UDS requests concurrently against a **shared, non-thread-safe `uds.Server`**
  (session / security-unlock / DID-map state), so it needs handler locking or
  per-connection handler state on top of the threading change. Deferred until
  multi-tester concurrency is actually required (Codex PR #1 finding, by design).

## SOME/IP — what this tester does, and what it leaves alone

Agreed 2026-09-17, after the codec, the RPC client and the passive listener had landed. The
two repos split one protocol: **blobly_emb is the SOME/IP server half** (a wire format, not a
middleware — static endpoints, no SD, no SOME/IP-TP, layouts fixed at build time; its
`docs/someip.md` has the NOT list), and **this repo is the tester half**. Everything below is
tester-side, and none of it is mirrored into emb.

**What it does**

| | Status |
|---|---|
| Header codec + envelope validation, golden vectors shared with emb | ✅ `modules/someip` |
| RPC **client** — one request in flight, deadline, session liveness, drain | ✅ `rpc_client.v`, the GUI's Shell over Ethernet |
| **Listen** — sit on a port (and a multicast group), report every message decoded to its header, payload raw; malformed datagrams counted, several messages per datagram split; the window itself is `transport.udp_window`, shared with DoIP's announcement collector | ✅ `listen.v`, Lua `someip.listen` |
| **A `someip` channel** — `adapter: someip`, `address: <bind-host>:<port>`, optional `group:`; ▶ Start binds it and every message heard is a trace row, carrying its kind so no CAN consumer reads a service:method as an arbitration id. Nothing is sent; nothing is recorded (a recording holds CAN frames, and the Log says so). Lua `someip.listen({ from = name })` takes its endpoint; two listeners in one process cannot hold one endpoint, whichever starts first, because a second UDP socket on one port splits the stream rather than sharing it. `projects/someip-listen.blobnet` beside emb's `examples/host_someip` | ✅ `cmd/blobly_net` `someip_rx_loop` |
| **Decode SD passively** — read the offer/subscribe entries a discovering SUT multicasts, so a foreign service's ids and endpoints can be listed without asking | 🧭 next: a small extension of Listen, still bounded |
| **Decode and produce events for an emb node from its config** — the derived layouts `system.toml` implies, so the tester node a system declares (emb's `system_full/nodes/tester`) is real on its SOME/IP bus, not only on CAN | 🧭 |

**What it does not do, and why**

- **No SD client.** Sending find/subscribe so a vsomeip-style service delivers its events to
  us is the first real step into middleware: eventgroup state, TTLs, a reboot flag, a
  multicast/unicast negotiation. Listen hears what the network already carries — an emb node's
  events to its peer, events a service publishes to a group, SD offers (each of the last two by
  joining the group) — and that is where the
  line sits until a concrete SUT needs the other side. If that comes, it is tester-only.
- **No generic payload serializer.** No ARXML-driven types, no strings, arrays, TLV or dynamic
  lengths. A payload is a static layout: derived from config for an emb node, hand-written in
  the project file for a foreign SUT at most. `sut/arxml_oracle.py` is an oracle for reading a
  customer artifact, not a runtime type system.
- **No SOME/IP-TP, no simulated SOME/IP service.** emb is the server oracle; a second server
  here would be a second implementation of a design that has one. The "sim service" stays
  deferred.
- **Nothing tester-shaped goes into emb.** An application-initiated request on the ECU is an
  application feature and lives in emb's roadmap; it is not this tester.

**Status:** the codec/validation core — `modules/someip/` (16-byte header encode/decode +
envelope validation, hermetic golden-vector tests), the host-side oracle for blobly_emb's
eth-bus design (its `docs/someip.md`) — plus the RPC **client** (`rpc_client.v`: one request in
flight, a deadline, session-id liveness, stale-datagram drain; hermetic and networked tests),
used by the GUI's Shell over Ethernet, plus the passive **listener** (`listen.v`: verified live
against emb's `examples/host_someip` on loopback) and the **`someip` channel** that puts the same
stream in the GUI trace. SOME/IP-SD and the sim service remain deferred, as above.
