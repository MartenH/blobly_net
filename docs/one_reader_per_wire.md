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

## Slow subscribers: not a new hazard, and the real one is elsewhere

The instinct is to treat per-subscriber queues as a risk this design introduces. They are not.
**Five of the seven backends already work exactly this way**: each SocketCAN socket has its own
buffer, each Kvaser handle its own receive queue, each Vector port its own. A consumer that falls
behind today already overflows its own queue and drops its own frames without touching anyone
else. Reproducing that above the driver is parity, not novelty — and PCAN and CANsub, which have
no per-consumer queue at all because they have competition instead, get it for the first time.

What changes for the better is **visibility**. Today the drop happens inside the driver and is
reported differently by each one — Kvaser in its status flags, SocketCAN in dropped counters, PCAN
and CANsub not at all. One implementation means one count, in one place, for every backend.

**Depth is a parameter, not a policy.** The only way app-level queues are worse than what we have
is if they are shallower than the driver queues they stand in front of, so a consumer that copes
today starts dropping tomorrow. That is measurable, and it should be measured per backend rather
than guessed at — the number to beat is whatever the driver gives that consumer now.

For the same reason the earlier question here — whether a diagnostic subscriber deserves a deeper
queue than the trace — is probably the wrong question. No such asymmetry exists today and nothing
has asked for one. One generous depth for everybody, matching or exceeding the drivers', and revisit
only if a real consumer is measured to need more.

### The risk that IS new

Today a slow consumer hurts only itself. With one reader, if the **reader thread** becomes slow —
contended on a subscriber's lock, or doing unbounded work per frame — it stops draining the single
driver queue and drops for *everyone*. That coupling does not exist today and it is the thing this
design must be built against:

- the fanout **never blocks**: a full subscriber queue drops that subscriber's frame and the reader
  moves on. There is no path where one consumer can stall the loop;
- per-frame work in the reader is bounded and does no I/O, no allocation per subscriber where it
  can be avoided, and no lock held across a copy;
- the shared driver queue's own overrun is counted too, and reported for the WIRE rather than for a
  subscriber — because that one means the reader itself fell behind, which is a different fault with
  a different cause.

## The echo — the part the first draft got backwards

The first draft said `echoes_own_sends` "becomes near-trivial: with one handle the app knows exactly
what it sent." That inverts the problem, and it is the one error in this design that would have
shipped a regression.

**Today the echo exists BECAUSE there are two handles.** The monitor's socket or port sees what the
transmit tap sent, and that arrival is the only evidence the app has that a frame reached the wire.
`wiretap` matches it by content to separate `TX` from `RX`, to record in observation order, and to
surface a second transmitter on one id (the frame that finds no record left to claim). Collapse to
one handle and, per backend:

| backend | why the echo exists today | one handle, unchanged |
|---|---|---|
| SocketCAN | the other socket sees it; `CAN_RAW_RECV_OWN_MSGS` is **not** set | echo gone |
| `inproc:` | broadcast to the others, *"NOT its own (no self-loopback)"* | echo gone |
| `udp:` | multicast loopback, then our own echo **dropped** by `src` id | echo gone |
| Vector | the monitor port sees the tap's frame; the port's own `TX_COMPLETED` is **discarded** (`vector_shim.h`) | echo gone |
| Kvaser, PCAN | never had one; the trace records at emit time | unchanged |
| CANsub | the device acknowledges every send, delivered as a frame | unchanged |

Four of seven backends lose the evidence, and every consumer of `origin` in the trace loses with
them. So the design **requires** the echo to be re-created, and there is a better way to do it than
the one being lost.

**Every driver can hand back a flagged transmit acknowledgement on the same handle**:

| backend | mechanism |
|---|---|
| SocketCAN | `CAN_RAW_RECV_OWN_MSGS` on, and `MSG_CONFIRM` in the `recvmsg` flags marks the frame as ours |
| Vector | `TX_COMPLETED` — we already receive it and throw it away |
| Kvaser | `canIOCTL_SET_TXACK`; the ack arrives with `canMSG_TXACK` |
| PCAN | the echo-frames parameter (`PCAN_ALLOW_ECHO_FRAMES`, PCANBasic 4.4+), flagged `PCAN_MESSAGE_ECHO` |
| CANsub | already — `CansubRecord.tx`, with a start-of-frame hardware timestamp |
| `inproc:`, `udp:` | synthesised by the reader from its own send, flagged the same way |

That is not merely a replacement — it is **strictly better than what is being lost**. Today the
match is a content-key guess: an ECU that sends the same bytes we just sent is indistinguishable
from our echo, and the ring's "consume oldest first" is the best that can be done about it. A
driver-flagged ack is not a guess. `CanFrame` grows one field — `tx_ack bool`, a received STATUS
like `esi`, never set by a sender — and `wiretap` matches on the flag first and the content second.

The reader therefore does one more thing per frame: an ack is fanned out to subscribers like any
other frame, because a simulated ECU that sent a response still wants to see it confirmed in its
own stream, exactly as it does today on Vector.

**This also changes what "record at emit" means.** Today PCAN and Kvaser record at emit because
nothing will ever observe the frame for them; with a flagged ack on every backend, *nothing* needs
to record at emit — every backend records in observation order, from the ack. One rule instead of
two, and the ordering the trace shows becomes the ordering the wire saw on every adapter.

## What this dissolves

Not a side benefit — a large part of the justification:

- **the Kvaser multi-handle machinery** (~130 lines from #219): the registry, apply-through-every-
  handle, the open/close serialisation. With one handle it is by definition canlib's first opener,
  so it holds initialisation access and the mode call is simply obeyed.
- **`echoes_own_sends` goes away** — but only because the echo is redesigned, not because it becomes
  trivial. See "The echo" below; without that section this bullet would be a regression.
- **Vector pin clashes shrink** (`pinned.v`, #165): a disabled row's transmit taps stop holding
  their own ports, so the case where a port nobody mentions pins a channel largely goes away.
- **`shared_open` stops being a special case** for two backends and becomes the universal path.

## Risks, honestly

- **Ordering and timestamps.** One reader is strictly better here, but only if the queue preserves
  arrival order per wire.
- **`recv(-1)`.** The blocking contract is used by Lua and `can_smoke`; a subscriber queue must
  honour it without pinning a thread per subscriber.
- **Lifetime, and this is a known-painful shape.** "The last subscriber to close stops the reader"
  meets two things at once. A Lua script may outlive Stop holding its bus (`listen.v`), so Stop
  does not release the driver handle — already true on PCAN today via `shared_open`, and fine as
  long as it is *stated*. And a reader thread parked in a driver call cannot be joined by the close
  that is stopping it: CANsub learned this the hard way (#214, "close() no longer waits for this
  thread"), and the reader here inherits exactly that problem on every backend. Tell it to stop,
  bound its driver wait, then join — in that order, the way `cansub.v` already does.
- **It is a big change.** Every emitter and consumer. That is the argument for doing it as its own
  PR with its own bench, not as part of a feature.

## Acceptance

- `cmd/silentcheck` — all five phases, all four pairings, **unchanged**, with less code behind them.
  If listen-only still holds after the reader collapses to one handle, the dissolution above is
  real rather than hoped for.
- **An echo test, first**, because the finding above is the regression this design would otherwise
  ship: on every backend that can acknowledge, a sent frame comes back exactly once, flagged as
  ours, and `wiretap` claims it by the flag. On `inproc:` in CI, and on the bench for the vendors —
  this is the #139 class and gets the #139 proof.
- A new headless test for the actual bug: two subscribers on one wire, both must see every frame.
  This runs on `inproc:` in CI — and the point of the design is that it now predicts PCAN too.
- A slow-subscriber test: one consumer stops draining; the others keep receiving and the drop count
  is non-zero and readable — the property five backends already give us, now uniform.
- A reader-chokepoint test, for the risk this design actually introduces: with one subscriber
  wedged, the WIRE's own overrun count must stay zero. If it does not, the fanout is blocking
  somewhere it promised not to.
