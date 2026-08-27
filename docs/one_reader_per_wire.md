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

**One receive BROKER per logical wire per process. `transport` owns it. Everything above it
subscribes. Each backend uses whatever physical handle topology it needs underneath.**

The first draft said "one driver handle, always". Codex's review (on #212) is right that this is
too strong, for a concrete reason: **Kvaser handles are thread-oriented**. canlib's own guidance
is one handle per thread, and a single handle shared between a reader parked in `canReadWait` and
arbitrary sender threads would need a lock held across a blocking driver call — the exact thing
#211 exists to remove. So the invariant is about the *reader*, not the handle count:

- `transport.open(iface)` returns a **subscriber**, not a driver handle.
- Exactly one thread per wire reads from the driver — the broker's. Nobody else calls the
  driver's receive.
- The broker hands a **copy** to every subscriber's bounded queue. It never blocks on a
  subscriber (see the chokepoint risk below).
- Sends go through the broker's single transmit path, which is what makes the acknowledgement
  correlation below sound.
- The backend decides the topology: PCAN and CANsub one handle (the driver permits one); SocketCAN
  one socket; Vector one port; **Kvaser one RX handle and one TX handle**, opened by `transport`
  in a known order — so which of the two holds initialisation access is a fact the broker knows,
  not one it has to discover through every handle.

**Consequence for the #219 arithmetic, stated honestly:** the Kvaser registry, apply-through-every-
handle and the open/close serialisation do not vanish. They shrink to "two handles whose order we
chose", which is deterministic where today's is not. Less code, not none.

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

**Delivered to every subscriber EXCEPT the one that sent it.** The first draft broadcast the ack to
all, sender included, and that breaks three things that exist today: `inproc:` and `udp:` suppress
self-delivery by design (`inproc_test.v`, *no self-loopback*), and the simulation is explicit that
its bus must be *"a dedicated instance so it doesn't hear its own sends"* (`sim.v`). The broker
knows which subscriber originated each send, so "everyone but the origin" costs nothing and keeps
the contract every consumer was written against. The monitor still gets its echo — which is what
Vector gives it today — and the simulated ECU still gets its silence.

**Correlation is per origin, in order.** Two subscribers sending identical bytes at once must each
be credited with their own ack. Drivers acknowledge in submission order per transmit handle, and
sends are serialised through the broker's one transmit path, so a per-origin FIFO of outstanding
sends matches acks without guessing. A bare `tx_ack bool` on the frame cannot express that.

**So the flag is not on `CanFrame`.** The first draft widened the wire struct; codex's objection is
right: `CanFrame` is the bytes on the wire, and host metadata on it is what `wiretap`'s identity,
DBC decoding and replay all have to be defended against (`fd`/`brs` in the echo identity was a
#139-class lesson). Subscribers receive an **envelope** — the frame, its direction (`rx`, or
`tx_ack` with the origin), and the ingress timestamp. That envelope is also where #149's hardware
timestamps finally have somewhere to live.

**Emit-time recording stays, as the fallback it already is.** The first draft claimed nothing would
need to record at emit any more. Wrong twice over: a transmit-only subscriber never drains a queue,
and `trace.v` records at emit precisely for the case where no monitor exists yet — the simulation's
first frames go out while the rx loops are still opening. So the rule becomes: **a wire whose broker
has a monitor subscriber records from the ack; a wire without one records at emit**, per wire,
declared by the broker rather than inferred from the backend name. Acks where the driver provides
them, emit-time where it cannot, and the same shape everywhere.

That last clause matters because the ack is **a capability, not a given**. PEAK documents echo
frames from PCAN-Basic **4.6.0**, with driver and hardware restrictions — the first draft said 4.4
from memory, which is exactly the kind of claim the quirks table forbids. The broker asks each
backend whether acks are available on this wire and falls back per wire; it never assumes.

## Lifecycle — the part that was underspecified

The first draft had "first subscriber starts the reader, last one stops it" and nothing else. Codex
named what is missing, and each item is a bug today or a bug tomorrow:

- **A fatal reader error must reach every subscriber.** Today `rx_loop` disables every alias on a
  wire when a non-timeout receive error arrives (`workers.v`). With one reader, a driver failure
  that only the broker sees leaves every subscriber blocked on an empty queue — and the GUI times
  out forever, silently. The broker wakes every blocked subscriber with the error, and the error
  is sticky until the wire is reopened.
- **Explicit states**: `opening`, `running`, `failed`, `closing`. Not a refcount and a bool.
- **A closing reservation.** The last close stops a reader that may be parked in the driver
  (#214's lesson); a new `open` arriving during that window must wait for the old broker to be
  gone, not race it for the handle. `shared.v`'s close today has exactly this gap.
- **Lazy receive.** A subscriber's queue is created on its first `recv`, not at open — otherwise
  every transmit-only tap becomes a permanently overflowing subscriber with a drop count nobody
  wants to read.
- **A statistics API on the broker** — subscriber drops and the wire's own overrun — because
  `Bus` has none and the design's visibility argument is worth nothing without one.

## Where the wrappers go

The stack is **per-subscriber `SilentBus` → subscriber queue → one shared `PinnedBus`/raw backend
per wire**, and the boundary is not arbitrary. `verbatim` is a property of the *opener* (replay
owns its frames' format; the GUI's tap frames before it records), so `silenced()` must wrap the
subscriber; share it any higher and `verbatim` becomes global. `pinned_open` records what the
*driver* is configured to, once per wire, so it sits below the queue; share it any lower and the
fake per-subscriber Vector pins that #165 is about survive. The registry is keyed by `wire_key`,
with a separate backend-normalised configuration signature for bitrate, mode and protocol.

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
- **An instrumented fake backend that asserts exactly one physical reader.** The `inproc:`
  two-subscriber test above proves the *contract*, not the broker: `inproc:` already fans out,
  so it would pass today with no broker at all. The fake counts driver receives.
- Fatal-reader broadcast, then reopen: every blocked subscriber wakes with the error; a
  subsequent open on the same wire succeeds.
- Concurrent final-close and open on one wire: no race for the handle, no leaked reader.
- Sender self-suppression: the origin does not receive its own ack; every other subscriber does.
- Identical concurrent sends from two subscribers: each is credited its own ack.
- Pre-monitor recording: frames sent before any monitor subscribes are still recorded, at emit.
- Payload isolation: a subscriber mutating the frame it received does not alter another's copy.
- Unsupported-ack fallback: a wire whose backend reports no ack capability records at emit and
  never waits for one.
