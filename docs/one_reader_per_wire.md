# One reader per wire — design for #212

**Status: proposal.** Nothing here is built. It exists to be argued with before code is written,
because the change touches every emitter and every consumer of CAN frames in the app.

## The problem, stated as behaviour

A wire is opened several times per Start. Today each of those opens is a separate reader, and on
the two backends that physically cannot give you a second reader, the second open **competes for
frames instead of seeing a copy** (#212):

- the monitor consumes a diagnostic **response** before the ISO-TP channel sees it → intermittent
  UDS timeouts that look like a slow ECU;
- the ISO-TP consumer takes ordinary traffic → holes in the trace, with nothing recorded as missing.

Both are intermittent and neither leaves evidence of itself.

## What "shared" means today — per backend, and it is not one thing

This is the fact the design turns on. Open one wire twice and ask whether **both** instances see an
inbound frame:

| backend | second open sees inbound frames? | why |
|---|---|---|
| SocketCAN (`can0`, `vcan0`) | **yes** | the kernel delivers to every socket bound to the interface |
| `inproc:` | **yes** | broadcast to attached subscribers |
| `udp:` | **yes** | multicast; every participant receives |
| **Vector** | **yes** | separate XL ports on one channel; the driver hands a frame from one port to the others (#139) |
| **Kvaser** | **yes** | each `canOpenChannel` handle has its own receive queue |
| **PCAN** | **no** | one `CAN_Initialize` per channel per process → `shared_open` returns the *same* bus, and `recv` **removes** the frame |
| **CANsub** | **no** | one client per channel WebSocket → same |

So `shared_open` is doing two unrelated jobs under one name:

1. **A hardware necessity** for PCAN and CANsub — the driver permits one handle, full stop.
2. **A frame-stealing bug** for every consumer above it, because `SharedHandle.recv` takes the
   frame rather than copying it.

And the five backends that *do* fan out natively pay for it: on Kvaser, several handles on one
channel is exactly what made listen-only hard (see the quirks table in
[`windows_can_hardware.md`](windows_can_hardware.md) — `canSetBusOutputControl` is obeyed only
through the handle holding initialisation access, and returns success through the rest).

**The behaviour therefore differs by backend today.** A test that passes on `inproc:` does not
predict PCAN, which is the property this repo tries hardest to avoid everywhere else.

## Why is there a second `recv` at all?

Not by design — by accretion. Every consumer that needs frames opens its own bus, because there has
never been anything else to do:

| consumer | where |
|---|---|
| the monitor / trace | `rx_loop`, `workers.v` — and its own comment already calls it *"the destination's one reader"* |
| a simulated ECU | `sim_loop` → `sim.v`; it must hear the request it answers |
| ISO-TP / UDS diagnostics | `isotp.open_software` opens its own bus |
| a hosted UDS server | `uds/server.v` |
| a Lua script | `bus.recv` in the prelude |
| CLI tools | `can_smoke`, `crosscheck`, `cansub_smoke` |

The intent was always one reader. The mechanism for sharing it was never built.

## The proposal

**One driver handle per wire, always, on every backend. `transport` owns the reader. Everything
above it subscribes.**

- `transport.open(iface)` returns a **subscriber**, not a driver handle.
- The first subscriber on a wire starts one reader; the last to close stops it.
- The reader loop does one `recv` from the driver and hands a **copy** to every subscriber's queue.
- Sending is unchanged in meaning: subscribers share the one handle, as PCAN already does.

### Why in `transport` and not in the GUI

This is the one place I would push back on the framing. Putting the queues in the GUI leaves every
non-GUI consumer on the old behaviour — `modules/isotp`, `modules/uds`, `modules/sim`,
`modules/script` and four CLI tools all call `recv` on a bus they opened, and `modules/` is
GUI-free by the repo's one architectural rule. A fanout that the headless Lua runner does not get
is a fanout that CI cannot test.

So the seam is `transport.open`, and the GUI becomes just another subscriber.

## The hard part: a slow subscriber

One reader means one queue per subscriber and a policy for what happens when one stops draining.
Three options, and the repo already has a precedent:

| policy | consequence |
|---|---|
| block the reader | one stalled consumer stops the trace for everyone. Unacceptable |
| drop silently | exactly the failure mode #212 is about, relabelled |
| **drop and count, per subscriber** | what `cansub` already does for its decoder overruns — *"COUNTED, not silent: a receiver that fell behind has holes in its trace and must be able to say so"* |

**Proposal: bounded queue per subscriber, oldest dropped, count exposed per subscriber and surfaced
the way `last RX` and `NOT SILENT` already are on the Buses row.** A consumer that falls behind is a
fact about the run, not an error, and it must be visible without being fatal.

Open question worth deciding before coding: does a *diagnostic* subscriber get a deeper queue than
the trace? A dropped UDS response is a failed test; a dropped trace row is a gap in a log.

## What this dissolves

Not a side benefit — a large part of the justification:

- **the Kvaser multi-handle machinery** (~130 lines from #219): the registry, apply-through-every-
  handle, the open/close serialisation. With one handle it is by definition canlib's first opener,
  so it holds initialisation access and the mode call is simply obeyed.
- **`echoes_own_sends`** becomes near-trivial. Today it is a per-driver fact because the monitor's
  port is not the port that transmitted (#139). With one handle the app knows exactly what it sent.
- **Vector pin clashes shrink** (`pinned.v`, #165): a disabled row's transmit taps stop holding
  their own ports, so the case where a port nobody mentions pins a channel largely goes away.
- **`shared_open` stops being a special case** for two backends and becomes the universal path.

## Risks, honestly

- **Ordering and timestamps.** One reader is strictly better here, but only if the queue preserves
  arrival order per wire.
- **`recv(-1)`.** The blocking contract is used by Lua and `can_smoke`; a subscriber queue must
  honour it without pinning a thread per subscriber.
- **Self-echo.** `wiretap` matches our own frames to separate `TX` from `RX`. Changing which handle
  sees a transmitted frame is exactly the class of change that produced #139 — it needs the same
  bench proof.
- **Lifetime.** A Lua script may outlive Stop holding its bus (`listen.v`). Subscriber lifetime and
  reader lifetime are then not the same thing, and the last-subscriber-closes rule has to survive
  that.
- **It is a big change.** Every emitter and consumer. That is the argument for doing it as its own
  PR with its own bench, not as part of a feature.

## Acceptance

- `cmd/silentcheck` — all five phases, all four pairings, **unchanged**, with less code behind them.
  If listen-only still holds after the reader collapses to one handle, the dissolution above is
  real rather than hoped for.
- A new headless test for the actual bug: two subscribers on one wire, both must see every frame.
  This runs on `inproc:` in CI — and the point of the design is that it now predicts PCAN too.
- A slow-subscriber test: one consumer stops draining; the others keep receiving and the drop count
  is non-zero and readable.
