# Ethernet architecture — DoIP first, SOME-IP later

Agreed 2026-06-29. The plan for bringing **automotive Ethernet** into blobly_net, starting with
**DoIP** (diagnostics over IP, ISO 13400) and deferring **SOME-IP** (service-oriented middleware).
This mirrors `docs/simulation_architecture.md` — design captured before building, oracle-first.

## Why DoIP first

DoIP is just **UDS-over-IP**: it carries the same UDS (ISO 14229) diagnostic payloads our
`modules/uds` stack already speaks, only over TCP/IP instead of ISO-TP/CAN. That makes it the
cheapest possible Ethernet beachhead:

- **The whole UDS stack is reused unchanged.** `uds.Client` and `uds.Server` are written against the
  `isotp.Channel` interface (`send`/`recv`/`close` + `iface`/`tx_id`/`rx_id`). A DoIP connection
  **implements that same interface** — exactly the trick `isotp.SoftChannel` uses for the in-proc CAN
  bus. So `uds.new_client(doip_channel)` and `uds.Server.serve_for(mut doip_channel, …)` work with no
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

`doip` imports neither `uds` nor `isotp`: the client satisfies `isotp.Channel` *structurally* (V
interfaces are structural), and the server takes a plain callback. This keeps the dependency arrow
one-way (`uds → isotp`; `cmd/* → doip + uds`) and `doip` a leaf transport module — same hygiene as
`transport`/`isotp`.

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
- **Start/Stop:** `start_measurement` branches on `ch.is_doip()` before the CAN mode-match — it does
  NOT open a `Bus` or RX thread. If the DoIP channel hosts a simulated ECU (`simulate:`/`simulation:`
  non-empty), it spawns `doip_server_loop` (a native `DoipServer` wrapping `uds.default_server()` over
  real localhost TCP/UDP, polling the running flag to exit); otherwise the channel is just a client
  target for an external/real entity.
- **GUI Diagnostics panel:** `diag_request` resolves the first running channel to a `DiagTarget` and
  `open_diag_channel()` returns the right `isotp.Channel` — `doip.open_doip(...)` for DoIP, else
  software ISO-TP — so `uds.Client` rides either carrier unchanged. The panel header
  (`diag_target_label`) shows the active carrier (DoIP host/port + logical addresses, or 0x7E0/0x7E8
  software ISO-TP). **Verified** end-to-end: the GUI (autostart + `doip-demo.blobnet`) serves the entity on
  127.0.0.1:13400 and an external UDS client reads VIN `BLOBLYNETV0SUT001` over Ethernet.

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

## SOME-IP (phase E3, deferred)

A separate `modules/someip/`: 16-byte SOME-IP header (message/request id, length, protocol/interface
version, message type, return code), request/response RPC, and **SOME-IP-SD** service discovery
(offer/find/subscribe) over UDP multicast. It does not reuse the UDS stack; it's new middleware with
its own sim service + oracle. Scoped once DoIP is in the app.
