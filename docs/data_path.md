# Data path — from the wire to the panels, the scripts and the files

> Status: overview, 2026-09-19. This is the map; the deeper records are linked from each section.
> Short on purpose — elaborate in the linked documents, not here.

## The shape

```
wire / medium            backend (modules/transport, doip, someip)     what comes out       who reads it
──────────────────────   ─────────────────────────────────────────    ─────────────────    ─────────────────────────────
CAN  vcan/socketcan      open()  →  a Bus per OPENER: the RX loop,       CanFrame             rx_loop → TraceRow (RX)
     pcan/kvaser/vector   each transmit tap, the sim, diagnostics                              sim_loop → tap (TX-S)
     cansub               hold their own. pcan/cansub share one                               diagnostics → isotp.on_bus(tap)
     inproc / udp:        handle behind per-Bus cursors                                       Lua opener → Bus
                          (one_reader_per_wire.md); the rest fan out
──────────────────────   ─────────────────────────────────────────    ─────────────────    ─────────────────────────────
Eth  doip:<host:port>    TCP: DoipClient / DoipServer                  UDS bytes            uds.Client over isotp.Channel
                          — NOT a Bus: it carries diagnostics,          (no frames)          Diagnostics panel, Lua uds.open
                          so it plugs in one level up, at isotp.Channel                      a hosted entity (sim.doip_entity)
                          UDP: discovery — doip.discover asks,          announcements        DoIP Discovery dialog,
                          collect_announcements listens                 (VIN, address, from) Lua doip.discover / doip.listen
──────────────────────   ─────────────────────────────────────────    ─────────────────    ─────────────────────────────
Eth  someip:<host:port>  udp_bind + udp_read (transport/udpwindow)      someip.Message       someip_rx_loop → TraceRow (RX, kind=someip)
     [+ group]            Capture.ingest splits datagrams                                   Lua someip.listen → Capture
──────────────────────   ─────────────────────────────────────────    ─────────────────    ─────────────────────────────
LIN                      planned (ROADMAP) — its own LinFrame + bus,   —                    —
                          per the seam rule below; nothing exists yet
```

Two things enter the same trace from somewhere other than a wire:

- **A recording, two ways** (`cmd/blobly_net/replay.v`, `modules/player`). *Opening* one for inspection
  makes `REP` rows on the file's own clock and transmits nothing. *Replaying* one sends its frames
  through a tap: the SUT sees ordinary CAN frames, and the trace shows them as `TX-S` rows. Two paths,
  not two steps of one.
- **Telemetry from a blobly_emb target** (`modules/telem`) mostly does NOT go through rows. The Trace
  Chart's `trace_dump_worker` and the Shell's `shell_worker` each open their own ISO-TP channel and
  decode into their own state (`app.trecs`, `shell_lines`); the eth Shell talks `someip.RpcClient`
  directly. The frames may also appear in the trace, and `rx_loop` decodes one thing inline — the
  trace status response the manifest names. Over SOME/IP the node's events arrive as rows shown
  raw; decoding them from its config is the next rung (ethernet_architecture.md).

## The rules that hold across all of it

- **Frame types are per protocol.** `CanFrame` is CAN; a SOME/IP message is a `someip.Message`; LIN
  will be a `LinFrame`. No generic envelope (simulation_architecture.md, *Multi-protocol seam*).
  Where they meet is the **trace row**, which carries its `kind` so no CAN consumer — the filter, the
  Signals and Graphics decode, the DBC menu, the Send panel — reads a SOME/IP id as an arbitration id.
- **Decode is per database, at the consumer.** A backend hands over bytes and an id; the DBC (CAN) or
  the config-derived layout (SOME/IP, next rung) is applied by whoever displays or checks the value.
- **Every row says where it came from.** `TX` we sent as tester · `TX-S` our simulated rest-of-bus,
  active replay included · `REP` a recording opened for viewing, nothing sent · `RX` anything real on
  the wire (`modules/wiretap`). What keeps our own
  echo out of the SUT's pile is the wiretap's emit/claim matcher: `rx_loop` asks it before it makes an
  `RX` row, and an unmatched frame is external. Origin being part of the group identity is a
  separate fact — it keeps our 0x120 and the ECU's 0x120 as two rows — and does not do that job.
- **One RX reader per destination.** Several CAN rows spelling one wire share its single GUI reader
  and its state (health, load, last RX). A SOME/IP row is one reader per row, shares nothing, and is
  refused a second listener **from this process** on its endpoint rather than silently splitting the
  stream (`transport/udpclaims.v`). Another process — a second blobly_net, any UDP tool — CAN bind
  the same port, because V forces address reuse, and then each sees part of the stream and neither
  is told. That half is documented, not prevented: *A bound UDP port is not an owned one* in
  [bus_config_dialog.md](bus_config_dialog.md). A DoIP row has
  no reader at all: no RX thread, no rows, a client (or a hosted entity) and nothing else.
- **Is this a CAN wire?** is asked of one predicate — `project.Channel.is_eth()` in the model,
  `Chan.eth()` at runtime — by taps, load, replay, the sim loop, staleness and trace ownership. Not
  by adapter name at each site; that is how the second Ethernet kind was missed once.
- **A backend that cannot answer is not asked.** A DoIP channel opens no `Bus` and no RX thread; a
  SOME/IP row contributes no generators, simulation nodes or verifiers to the runtime, because
  nothing there can transmit or be checked as a CAN frame.

## What consumes a row

| consumer | reads | notes |
|---|---|---|
| Trace, Trace (filter), grouped view | `app.trace` rows | groups by row identity — CAN: origin, channel, id, `ext`, `fd`, `brs`, `rtr` (a classic and an FD 0x120 are two rows); SOME/IP: origin, channel, id, message type, both versions, sender, header validity |
| Signals, Graphics | rows, matched by CAN (id, ext) | kind-gated: never a SOME/IP payload |
| Record | received CAN frames, plus our own sends as accepted by the driver (`note_emit` appends at emit; an echo, where the backend gives one, confirms it rather than creating it) → `canlog` (candump `.log`) | **not an independent bus capture**: a host-accepted send is in the file whether or not it was seen on the wire. **CAN only** — a SOME/IP row is shown, not recorded, and the Log says so once |
| Diagnostics | an `isotp.Channel` | over a CAN tap (`isotp.on_bus`) or a `DoipClient` — the same `uds.Client` either way |
| Lua (`cmd/script`, the Script panel) | `bus.recv`/`bus.send` over a Bus from `env.opener`; `uds.open`; `someip.listen` | the runner opens buses directly; the GUI hands the script a tap, so its sends are `TX` rows |
| Simulation | sends `TX-S` through a tap, stamped per each simulated node's `protect:` | `modules/sim`, [simulation_architecture.md](simulation_architecture.md) |
| Verification | checks frames against the channel's **`verify:`** entries — live `RX` in `rx_loop`, and every frame of an opened recording in `load_recording`, whose verdict sits on the `REP` row | a DUT is not a simulated node, so its messages can never sit under a `protect:`; `verify:` exists for exactly that ECU (`sim.verifiers_for`) |

## Where to read next

- **CAN backends and the shared hub:** [one_reader_per_wire.md](one_reader_per_wire.md) · [can_hardware.md](can_hardware.md) · [windows_can_hardware.md](windows_can_hardware.md)
- **Ethernet:** [ethernet_architecture.md](ethernet_architecture.md) (why DoIP first, then SOME/IP; the tester/SUT split with
  blobly_emb) · [doip.md](doip.md) · [bus_config_dialog.md](bus_config_dialog.md) (the `someip` row, and what a UDP bind cannot promise)
- **Simulation and the network model:** [simulation_architecture.md](simulation_architecture.md) · [simulation.md](simulation.md)
- **Replay:** [streaming_replay.md](streaming_replay.md) · **Scripting:** [scripting.md](scripting.md)
