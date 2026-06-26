# Simulation architecture — networks, nodes, and the verification gate

Status: **design agreed 2026-06-07** (not yet implemented). This is the plan for
turning the tester into a CANoe-style simulation host: simulated ECUs and the
tester's own functions all attach to shared virtual networks, **inside one
process**, driver-free by default, with the existing Python SUT as the oracle
that proves the native stack before we trust it.

## Mental model — Networks own the database, Nodes attach

CANoe's model, which we already half-have (`project.Channel.databases`):

- **Network** = a shared medium of one *type* (CAN / CAN-FD / LIN / Eth) + its
  *database* (DBC / LDF / ARXML) + a *backend* (how frames actually move). It is
  `project.Channel` grown up. **The database lives on the network, not the ECU.**
- **Node** = a participant attached to one or more networks. Two kinds, but
  *architecturally identical* — both just send/receive on the medium:
  - **Simulated ECU** — sends/receives per the network's database and runs
    behaviour (cyclic TX, on-event, request/response, an optional UDS server).
    This is "the SUT, but native V and in-process."
  - **Tester** — the existing app functions (trace/monitor, send, replay,
    diagnostics). Just another node.

```
        ┌──────────────────── Tester process (one app) ────────────────────┐
 ECUs   │   Networks (medium + database)              Tester functions      │
 ┌────────┐    ┌────────────────────────┐            ┌────────────────┐     │
 │EngineE.│─TX─┼─▶ CAN1 (can) ⟵ .dbc ────┼──RX───────▶│ Trace / Monitor│     │
 │ 0x100… │◀RX─┤   backend: inproc|vcan|udp           │ Send / Replay  │     │
 └────────┘    └────────────────────────┘            │ Diag (UDS)     │     │
 ┌────────┐    ┌────────────────────────┐            └────────────────┘     │
 │BodyECU │────┼─▶ LIN1 (lin) ⟵ .ldf     │                                   │
 │ +UDS   │    └────────────────────────┘    ▲ optional bridge (verify only) │
 └────────┘    ┌────────────────────────┐    │                              │
               │ ETH1 (eth) ⟵ .arxml     │    │                              │
               └────────────────────────┘────┘                              │
        └──────────────────────────────────────│──────────────────────────-─┘
                                   external: Python SUT / candump (over vcan|udp)
```

## Locked decisions (2026-06-07)

1. **Behaviour = declarative-from-DBC** to start. An ECU auto-sends every message
   whose DBC **transmitter node** is that ECU, with simple per-signal generators
   (const / ramp / sine / counter) and a **config-based UDS server**. No scripting
   engine yet — a CAPL-like layer can come later on top of the same engine.
2. **Bus wiring = in-process by default, bridge optional.** A driver-free
   in-memory medium connects sim↔tester; bridging to `vcan0`/`udpbus` is opt-in,
   used when an external participant (Python SUT, candump) must join — e.g. during
   the verification gate. Keeps the driver-free Windows story intact.

## What we have vs. what's needed

| Concern | Have | Need |
|---|---|---|
| CAN medium | `transport.Bus` (+SocketCAN/udpbus), `transport.open()` | an **`inproc:` backend** (in-memory broadcast) |
| Network config | `project.Channel` (type/iface/databases/mode) | add `nodes[]`; `type` ⊇ can/canfd/lin/eth; `backend` |
| CAN database | `candb` (DBC parse, encode/decode, mux) | expose **transmitter node** (`BO_` sender + `BU_`) → message↔ECU ownership |
| Diagnostics | `uds.Client` + `isotp.Channel` (client side) | a **UDS *server*** node (responder half of `uds_server.py`) |
| Verification | candb↔oracle, uds↔uds_server.py, transport↔candump, mf4↔asammdf | a **conformance gate** + native-sim==Python assertions |
| LIN / Eth | — | `linframe`/`lindb`, then `ethframe`/`someip`/`doip` (later) |

## New modules (GUI-free, the usual `modules/` convention)

- **in-process bus backend** — in `transport` (or a sibling): a named in-memory
  medium where a frame TX'd by any attached participant is delivered to all
  others, in-process, no kernel vcan. Same `Bus` contract, so the tester's RX
  threads and ECUs attach identically. `transport.open('inproc:CAN1')` joins the
  named bus; `udp:`/`vcan0` remain as bridges. (Model after `udpbus.v`'s
  src-filter + broadcast, minus the sockets.)
- **`modules/sim`** — the engine. Given the project (networks + databases + node
  defs) it instantiates **`SimEcu`** nodes, attaches each to its network(s), and
  runs a **scheduler**: cyclic TX timers, on-event, request/response, on a
  *controllable* time base (×1 / faster / stepped) so it is deterministic and
  unit-testable. Signal values come from per-signal generators.
- **UDS server** — `modules/uds` server side (or `modules/diagserver`): sessions,
  RDBI/WDBI DIDs, tester-present, security, routines. Native twin of
  `sut/uds_server.py`; config-driven per node.
- Later: **`modules/lindb`** (LDF) + `LinFrame`; **`someip`/`doip`** for Ethernet.

## Multi-protocol seam (CAN / LIN / Eth) — keep it type-safe

Keep **protocol-specific frame types and bus interfaces** (`CanFrame`, future
`LinFrame`, `EthFrame`). CAN and LIN are genuinely different media; a fake-generic
envelope would lose type safety and leak protocol details into shared code. Unify
only at the **Network descriptor** (type + database + backend) and the
**node-attachment** level — *not* the wire. The scheduler orchestrates
protocol-agnostically; encode/decode is per-database. This mirrors the existing
clean `*_linux.v` / interface split.

## Project schema growth (`.yml`)

```yaml
networks:                       # generalised `channels:`
  - name: CAN1
    type: can                   # can | canfd | lin | eth
    backend: inproc             # inproc (default) | vcan0 | udp:group:port
    databases: [dbc/blobly_net.dbc]
nodes:
  - name: EngineECU
    networks: [CAN1]
    simulate: from-dbc          # send every message whose DBC transmitter == EngineECU
    signals:
      EngineSpeed: { gen: ramp, min: 800, max: 6000, period_s: 4 }
    diagnostics:                # optional UDS server hosted on this node
      rx: 0x7E0
      tx: 0x7E8
      dids: { 0xF190: "VIN1234567890" }
```

`channels:` stays supported (alias) so existing projects keep working.

## Verification-first — the gate before trusting the sim

Build/keep this *before and alongside* the sim. Python stays the oracle.

1. **Conformance suite** — formalise the existing cross-validations into one
   regression: the V tester exchanges with `sut/can_sut.py` + `uds_server.py`
   over a **shared bus (vcan0/udpbus)** and asserts frame streams, signal values,
   ISO-TP segmentation, and UDS responses all match.
2. **Native ECU == Python SUT** — the first `SimEcu` replicates `can_sut.py`
   (0x100 powertrain @10 Hz, 0x700 heartbeat, 0x101→0x102). Capture both the
   native sim and the Python SUT over the same bus and assert the frame stream is
   **identical** (same diff method we used for MF4). When native == Python, the
   Python SUT is redundant and the native sim is trusted.
3. Expand only after the gate passes: more ECUs → native UDS server (vs
   `uds_server.py`) → LIN → Ethernet.

## Phasing

1. **`inproc:` bus backend** + tester attaches to it (driver-free monitoring).
   Small; unblocks everything. Verify two in-proc clients exchange frames.
2. **`candb` transmitter node** — parse `BU_` + `BO_` sender; expose
   `Message.sender` and `Database.nodes`. Lets an ECU own its messages.
3. **`modules/sim` + one `SimEcu`** replicating `can_sut.py`; **verify native ==
   Python** (the gate). Wire Start/Stop to run sim + tester together.
4. **Multi-ECU** on one CAN network, shared in-process.
5. **Native UDS server** node, verified vs `uds_server.py`.
6. **LIN**, then **Ethernet** (DoIP/SOME-IP) behind the same Network/Node model.

## Notes / open items

- Operating mode is per *node*, not just per network: a network can simultaneously
  host simulated ECUs **and** be monitored by the tester (they see each other via
  the normal RX path — no special wiring, same as a real bus).
- `Start/Stop` (existing measurement lifecycle) becomes the master switch for both
  the tester's channels and the simulated nodes.
- Bus arbitration/timing is *not* modelled at first (in-proc broadcast is
  zero-latency, unordered-by-priority). Fine for functional simulation; revisit if
  we ever need timing-accurate arbitration.
