# Data path — from the wire to the panels, the scripts and the files

> Status: overview, 2026-09-19. This is the map; the deeper records are linked from each section.
> Short on purpose — elaborate in the linked documents, not here.

## The shape

```
wire / medium            backend (modules/transport, doip, someip)     what comes out       who reads it
──────────────────────   ─────────────────────────────────────────    ─────────────────    ─────────────────────────────
CAN  vcan/socketcan      open()  →  one Bus per wire                   CanFrame             rx_loop → TraceRow (RX)
     pcan/kvaser/vector   (pcan, cansub: a shared hub, one ingress,                          sim_loop → tap (TX-S)
     cansub               many cursors — one_reader_per_wire.md)                             diagnostics → isotp.on_bus(tap)
     inproc / udp:        (software buses, no driver)                                        Lua opener → Bus
──────────────────────   ─────────────────────────────────────────    ─────────────────    ─────────────────────────────
Eth  doip:<host:port>    DoipClient / DoipServer  (TCP + UDP)          UDS bytes            uds.Client over isotp.Channel
                          — NOT a Bus: it carries diagnostics,          (no frames)          Diagnostics panel, Lua uds.open
                          so it plugs in one level up, at isotp.Channel                      a hosted entity (sim.doip_entity)
──────────────────────   ─────────────────────────────────────────    ─────────────────    ─────────────────────────────
Eth  someip:<host:port>  udp_bind + udp_read (transport/udpwindow)      someip.Message       someip_rx_loop → TraceRow (RX, kind=someip)
     [+ group]            Capture.ingest splits datagrams                                   Lua someip.listen → Capture
──────────────────────   ─────────────────────────────────────────    ─────────────────    ─────────────────────────────
LIN                      planned (ROADMAP) — its own LinFrame + bus,   —                    —
                          per the seam rule below; nothing exists yet
```

Two things enter the same trace from somewhere other than a wire:

- **Replay** (`modules/player`, `cmd/blobly_net/replay.v`): a recording's lines become `REP` rows on the
  file's own clock, and are re-sent through a tap so a SUT on the wire sees them as `TX-S`.
- **Telemetry from a blobly_emb target** (`modules/telem`, the Trace Chart, the Shell): ordinary CAN
  frames whose ids the manifest names; `rx_loop` decodes the trace response id inline, everything
  else is a panel reading rows. Over SOME/IP the same events arrive as rows shown raw — decoding
  them from the node's config is the next rung (ethernet_architecture.md).

## The rules that hold across all of it

- **Frame types are per protocol.** `CanFrame` is CAN; a SOME/IP message is a `someip.Message`; LIN
  will be a `LinFrame`. No generic envelope (simulation_architecture.md, *Multi-protocol seam*).
  Where they meet is the **trace row**, which carries its `kind` so no CAN consumer — the filter, the
  Signals and Graphics decode, the DBC menu, the Send panel — reads a SOME/IP id as an arbitration id.
- **Decode is per database, at the consumer.** A backend hands over bytes and an id; the DBC (CAN) or
  the config-derived layout (SOME/IP, next rung) is applied by whoever displays or checks the value.
- **Every row says where it came from.** `TX` we sent as tester · `TX-S` our simulated rest-of-bus ·
  `REP` a replayed recording · `RX` anything real on the wire (`modules/wiretap`). Origin is part of
  a row's identity, so our own echo never lands in the SUT's pile.
- **One reader per wire.** Several CAN rows spelling one wire share its single reader and its state
  (health, load, last RX). An Ethernet row is one reader per row, shares nothing, and is refused a
  second listener on its endpoint rather than silently splitting the stream — see
  *A bound UDP port is not an owned one* in bus_config_dialog.md and `transport/udpclaims.v`.
- **Is this a CAN wire?** is asked of one predicate — `project.Channel.is_eth()` in the model,
  `Chan.eth()` at runtime — by taps, load, replay, the sim loop, staleness and trace ownership. Not
  by adapter name at each site; that is how the second Ethernet kind was missed once.
- **A backend that cannot answer is not asked.** A DoIP channel opens no `Bus` and no RX thread; a
  SOME/IP row contributes no generators, simulation nodes or verifiers to the runtime, because
  nothing there can transmit or be checked as a CAN frame.

## What consumes a row

| consumer | reads | notes |
|---|---|---|
| Trace, Trace (filter), grouped view | `app.trace` rows | groups by row identity: origin, channel, id, and for SOME/IP the message type, both versions, sender, validity |
| Signals, Graphics | rows, matched by CAN (id, ext) | kind-gated: never a SOME/IP payload |
| Record | every CAN frame seen on the wire, our own echoes included → `canlog` (candump `.log`) | **CAN only** — a SOME/IP row is shown, not recorded, and the Log says so once |
| Diagnostics | an `isotp.Channel` | over a CAN tap (`isotp.on_bus`) or a `DoipClient` — the same `uds.Client` either way |
| Lua (`cmd/script`, the Script panel) | `bus.recv`/`can.send` over a Bus from `env.opener`; `uds.open`; `someip.listen` | the runner opens buses directly; the GUI hands the script a tap, so its sends are `TX` rows |
| Simulation | sends `TX-S` through a tap; the verifiers check RX against `protect:` | `modules/sim`, simulation_architecture.md |

## Where to read next

- **CAN backends and the shared hub:** one_reader_per_wire.md · can_hardware.md · windows_can_hardware.md
- **Ethernet:** ethernet_architecture.md (why DoIP first, then SOME/IP; the tester/SUT split with
  blobly_emb) · doip.md · bus_config_dialog.md (the `someip` row, and what a UDP bind cannot promise)
- **Simulation and the network model:** simulation_architecture.md · simulation.md
- **Replay:** streaming_replay.md · **Scripting:** scripting.md
