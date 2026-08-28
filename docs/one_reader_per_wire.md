# One reader per shared wire - targeted design for #212

**Status: implemented; PCAN hardware acceptance done, CANsub pending.** `cmd/silentcheck` passes all
five phases through the shared hub on a PCAN-USB Pro FD against a Kvaser USBcan Pro 5xHS — PCAN as
listener, as the talker's peer, and at a 500k/2M FD data phase. The CANsub run is still owed. This change is intentionally limited to
`shared_open`, the seam already used by PCAN and CANsub because those backends permit only one
physical receive endpoint per wire in this process. It fixes their competing-consumer bug without
changing the public `Bus` interface or rebuilding the five backends which already fan out correctly.

## Decision

Replace the refcount-only object behind `shared_open` with a small per-wire hub:

```text
                         one raw PCAN channel / CANsub WebSocket
                                         |
                                  one ingress loop
                                         |
                            bounded sequence ring
                              /       |       \
                         cursor A  cursor B  cursor C
                         monitor   ISO-TP    simulation
```

The ingress loop writes each record into the ring once. Every `SharedHandle` has its own sequence
cursor and reads the same record independently. A slow handle can fall behind and lose only its
own history; it never blocks the ingress loop or another handle. A handle used only for sending
has a cursor but no frame queue and causes no payload copies or accumulated queue entries.

This is **not** a universal transport broker. Inproc, UDP, SocketCAN, Vector and Kvaser keep their
existing open and receive paths:

| backend | this change | reason |
|---|---|---|
| PCAN | use the shared hub | PCANBasic permits one initialized channel and currently exposes one competing receive queue |
| CANsub | use the shared hub | the device permits one WebSocket client per channel and currently exposes one competing receive queue |
| SocketCAN | unchanged | each socket already receives its own kernel-delivered copy |
| `inproc:` | unchanged | each participant already has its own queue |
| `udp:` | unchanged | each participant already receives the multicast traffic |
| Vector | unchanged | separate XL ports already provide independent receive queues |
| Kvaser | unchanged | separate CANlib handles already provide independent receive queues and are required by its threading/listen-only rules |

Linux kernel ISO-TP sockets do not pass through `transport.open` and are outside this design.

## Behavioural contract

For a wire routed through `shared_open`:

1. Each open handle observes every external frame accepted after that handle's subscription
   boundary, unless its cursor falls behind the bounded ring.
2. A stalled handle does not delay the physical reader, sends, or another handle.
3. A handle does not receive a CANsub transmit acknowledgement for its own send. Every other
   handle sees that acknowledgement once, preserving the existing no-self-loop contract used by
   simulation and ISO-TP.
4. PCAN sends do not appear in the receive ring. PCAN has no reliable local-transmit record in the
   current backend, so its existing record-at-emit trace path remains authoritative.
5. `send`, `recv`, `health`, `reconcile_silence` and `close` retain the public `Bus` signatures.
   No public `RxEvent`, tracked-send API, writer role or transport-wide statistics API is added.
6. A fatal physical-reader error wakes every blocked receiver and remains visible to every handle;
   it must not degrade into endless `timeout` errors.
7. The final close and a concurrent reopen cannot overlap two physical opens of the same wire.

The subscription boundary is the hub's current tail sequence while the new handle is inserted
under the entry lock. A handle does not receive retained history from before its open. Once open
returns, all later committed ring records belong to it, subject to bounded-ring overrun.

**On a wire nobody is listening to, nothing is committed.** The reader parks while no handle is
*attentive* (#224): a handle is attentive for one second after its open, and for the rest of its
life once it has received. A wire held only by transmit taps therefore costs the driver one
zero-timeout drain a second instead of a thousand reads, and what that drain finds is discarded.
The boundary above holds for every handle that receives within its first second — the
request/response pattern, the monitor — and for every handle on a wire somebody else is reading:
a handle opening onto a parked wire drains the driver's queue before it counts, so what it gets is
what arrived after its open. The one handle that loses anything is a tap that never received for
over a second and then does **on a wire nobody else was reading**: its history begins at that
first receive, because nothing was committed on its behalf in between. On a wire somebody else
kept reading, the ring holds everything since the tap's open (bounded-ring overrun aside) and the
tap gets it — the expiry is a property of the wire's reader, not a penalty on the handle.

## Private raw-record seam

The public `Bus.recv() !CanFrame` boundary is deliberately unchanged. Only the raw object owned by
the shared hub needs a richer, private receive result:

```v
struct SharedIngress {
    frame  CanFrame
    tx_ack bool
}
```

This is an internal `transport` type, not a new application contract. The PCAN adapter leaves
`tx_ack` false. CANsub projects its existing `CansubRecord.tx` flag into it instead of discarding
that bit in `CansubBus.recv`. CANsub's hardware timestamp can join this private record in a future
telemetry change, but this PR does not change the receive timestamp exposed to the GUI.

Only the hub calls the private raw receive operation. Logical callers still receive ordinary
`CanFrame` values from `SharedHandle.recv` and cannot manufacture or observe the private direction
flag. The ring, its sequences and origin ids are all private to `transport`.

## Ring and cursor semantics

Each running entry owns:

- one fixed-capacity circular array of slots;
- a monotonically increasing `next_sequence` assigned at ingress;
- the oldest sequence still resident in the array;
- one cursor and stable handle id per open `SharedHandle`;
- a sticky terminal error and lifecycle state;
- a notification mechanism for handles currently blocked in `recv`.

A slot contains the sequence, an originating handle id (`0` for external ingress) and one owned
frame payload. The reader deep-copies the backend's mutable `frame.data` once when committing the
slot. `SharedHandle.recv` deep-copies it again before returning a public `CanFrame`, because a
consumer is allowed to mutate that slice and must not alter the slot another consumer will read.

The initial capacity is 4096 records, matching CANsub's current bounded receive channel. It is a
named constant and must be exercised by the saturation test before being treated as a tuned
value. Capacity is a memory bound, not a promise that no application can overrun it.

`recv(timeout_ms)` repeatedly performs the following operation under the entry lock:

1. If the handle cursor is older than the oldest resident sequence, advance it to the oldest
   sequence and count the skipped records against that handle.
2. If a record is available, advance the cursor. If it is a local-TX record whose origin is this
   handle, skip it and continue; otherwise clone and return its frame.
3. If no record is available and the entry has failed, return the sticky terminal error.
4. If this handle was closed, return a closed-bus error.
5. Otherwise wait until ingress, failure, close or the caller's deadline wakes it, then recheck
   state under the lock.

`recv(0)` is a non-blocking probe. A negative timeout waits indefinitely but must still wake on
handle close or entry failure. At most one concurrent `recv` is supported per logical handle, as
today. Notifications carry no frames; a capacity-one wake token or equivalent may coalesce any
number of commits because `recv` always rechecks the sequence state.

Overwriting a slot never waits for a reader. Fast cursors continue normally, while only cursors
behind the new oldest sequence observe a gap. The per-handle gap count remains internal in this
change: #213 is the transport-wide diagnostics/telemetry seam. Tests must nevertheless make the
count observable inside `transport` so a later API can expose it without changing the algorithm.

## CANsub transmit acknowledgements and origin exclusion

CANsub is special inside this otherwise receive-only refactor. The device returns a TX record on
the same WebSocket for every frame this process sends. That record must enter the ring so the
monitor and other logical participants can see it, but it must not be returned to the logical
handle which sent it.

The hub serializes raw sends made through shared handles. For CANsub, the same critical section
covers both origin registration and the raw WebSocket write, and the entry keeps a bounded list of
pending sends in actual write order. PCAN uses the serialization but creates no pending local-echo
record. A CANsub pending item contains:

- a monotonically increasing send sequence;
- the originating `SharedHandle` id;
- the exact frame sent after the existing framing policy has been applied.

The pending item is installed before the raw WebSocket write, so a fast acknowledgement cannot
outrun its origin. TX-ack matching does NOT wait for the write to finish (the reader never waits
on a writer — #221), so an item whose write is still in flight is matchable, and an item whose
write FAILED stays too: the device's acknowledgement is the evidence that the frame reached the
wire, whatever the write call went on to return, and deleting the item on failure raced the
reader's match — on a two-core runner the sender's error path won often enough to drop the
acknowledgement as unmatched (#227). The window starts when the write returns: the ordinary
`shared_pending_ttl_ms` after success, a short `shared_failed_send_grace_ms` after failure —
long enough for an acknowledgement the reader already holds or that is one poll away, short
because a failed write that never reached the wire is a ghost for as long as its item stands,
and an identical frame another handle sends meanwhile would be credited to the ghost (wrong
origin, and the real sender receives its own frame as RX). A ghost that expires is counted as a
failed send, not as a missing acknowledgement. Registration plus raw write is serialized;
otherwise two caller threads could install origins in one order while their WebSocket frames
reach the device in another.

When ingress receives a flagged CANsub TX acknowledgement, it selects the **oldest pending item
whose full frame equals the acknowledgement**. Equality includes identifier,
extended/RTR/FD/BRS flags and payload; content alone without those flags is not identity. ESI is
excluded because it is received controller status rather than a sender-controlled part of frame
identity, matching `wiretap`. The TX flag prevents an external frame with identical content from
consuming a pending item.

On a match, ingress removes that pending item and commits a slot carrying its non-zero origin.
Every handle except that origin may return the frame. If the origin has already closed, the id is
still valid attribution for the pending item and all remaining handles receive the record.

A flagged TX acknowledgement which matches no pending local send is **dropped**, increments an
unmatched-TX diagnostic and is never published as an external frame. Guessing would be worse:
publishing it as RX could feed a simulator or ISO-TP client its own request. Stale pending items
expire and increment a missing-TX-ack diagnostic so the list remains bounded. These diagnostics
stay internal until #213 provides the public transport telemetry seam; tests inspect them through
transport-private helpers.

There is one explicit limitation. If two identical sends are pending and an acknowledgement is
lost, a later identical acknowledgement cannot reveal which physical send it belongs to; the
oldest-match rule attributes it to the older origin. Neither serialization nor frame comparison
can manufacture a token the device did not send. The implementation bounds and counts this case,
and tests pin the behaviour, but exact recovery would require a device-provided transaction id or
a policy of reconnecting on every missing acknowledgement. #212 does not justify turning a lost
trace confirmation into a wire outage.

This private origin mechanism is not generalized to PCAN or to native-fanout backends. It exists
only because CANsub supplies an explicit TX bit on the one receive stream shared by all logical
handles.

## Trace recording

This change does not replace `wiretap` and does not promise universal transmit confirmations.

PCAN continues to answer `false` from `echoes_own_sends`. Its successful sends are recorded at
emit time exactly as today, including sends before a monitor is ready and sends aimed at a disabled
channel's transmit tap. No PCAN echo option, synthetic echo or driver-version dependency is
introduced.

CANsub continues to answer `true`. With a ready monitor, its matched TX acknowledgement reaches
that monitor through the ring and `wiretap` claims it, preserving device observation order. With
no ready monitor, the existing emit-time fallback records the send and marks its pending wiretap
claim as already recorded; a later acknowledgement must not create a duplicate. The sender-origin
filter affects only the sending logical handle, not the monitor.

The targeted hub therefore preserves the current trace rules:

- PCAN: record successful sends at emit;
- CANsub with a ready monitor: record the matched device TX acknowledgement;
- CANsub without a ready monitor: record at emit, then suppress duplicate recording if the
  acknowledgement is observed later;
- failed sends: record nothing at emit; a CANsub acknowledgement that arrives for one anyway
  (the bytes reached the wire before the call failed) is recorded like any matched
  acknowledgement, attributed to its origin.

An unmatched or missing CANsub acknowledgement is counted rather than reclassified as RX. With a
ready monitor this can leave that send without an observation-time trace row; that is an honest
loss diagnostic, not permission to invent direction. No ordinary subscriber queue is made
responsible for durable recording.

## Registry and lifecycle

The registry remains keyed by `wire_key`, and `canonical_spec` remains the compatibility check for
configuration. Aliases of one CANsub spelling join one entry; incompatible bitrate, protocol or
mode requests fail rather than silently inheriting the first opener's configuration.

Each entry generation has explicit states:

```text
running -> closing -> closed
   |
   +------> failed -> closed
```

### Open

1. Preserve the existing atomic-open rule: the backend factory runs while the registry lock is
   held, so two simultaneous first opens cannot both reach a one-client driver. This serializes
   slow first opens of PCAN/CANsub wires; that narrow startup cost is accepted here rather than
   introducing a second per-key reservation system into #212.
2. Install the new entry and first handle with its tail cursor before starting the ingress loop.
3. A joining handle is assigned the current tail while the entry is locked, before its open
   returns.
4. A caller finding `closing` or `failed` waits until physical close removes that generation,
   then retries against a fresh one. It never joins the terminal generation.

As today, every joiner still calls `reconcile_silence` after acquiring its logical handle. The hub
delegates health and silence reconciliation to its raw backend; this design does not move dynamic
framing or per-open `verbatim` state below `SilentBus`.

### Reader failure

A non-timeout raw receive error atomically marks the generation failed and stores the original
error outside the ring. It wakes every finite and infinite receiver, rejects new sends, stops the
reader and closes the raw backend. A handle may drain records committed before the failure, then
every later receive returns the same sticky error.

The failed generation detaches from the registry only after physical close. Old handles remain
bound to its terminal state; they never silently attach to a replacement. A later open creates a
fresh generation even if an old Lua handle has not yet called `close`.

### Close

Handle close is idempotent. It marks that handle closed and wakes its blocked receiver. In-flight
`recv` cannot read a frame after close returns. Pending CANsub items retain only the closed handle's
numeric origin id until they are acknowledged or expire.

The last handle changes the entry to `closing` while leaving its reservation in the registry. It
rejects new operations, waits for an in-flight send to finish, requests ingress stop, joins the
reader, closes the raw backend, then removes the reservation so retrying openers can proceed. The
raw receive uses a bounded poll so shutdown does not depend on traffic arriving. A new physical
open for the key cannot begin before the previous physical close completes.

The entry lock is never held across vendor close, blocking receive or WebSocket write, and the
global registry lock is not part of the per-frame ring path. The one deliberate exception is the
first vendor open described above. Operation ownership/refcounts keep the entry alive across
calls made outside the entry lock.

## What this deliberately does not do

- It does not route every backend through one process-wide broker.
- It does not require one physical handle on Kvaser or change its threading model.
- It does not remove Vector ports or pinning checks.
- It does not add `RxEvent`, ingress timestamps, tracked sends, `open_tx`, or public drop counters
  to `Bus`.
- It does not make PCAN local sends visible to other logical handles; that is unchanged backend
  behaviour, and trace records them at emit.
- It does not synthesize PCAN receive events.
- It does not make subscriber overrun impossible. It bounds memory, isolates the lagging handle
  and keeps enough internal accounting for #213 to expose later.
- It does not establish exact physical-wire ordering on a backend which supplies no comparable
  timestamps. Ring sequence is the order in which the one raw reader accepted records.
- It cannot exactly attribute a later TX acknowledgement after one of several identical pending
  CANsub sends loses its acknowledgement; the oldest-match limitation above is explicit.

Those may be useful future projects, but none is required to fix #212. If uniform ingress metadata
or telemetry later justifies a broader broker, this sequence-ring implementation can be adopted
backend by backend instead of forcing a transport-wide migration now.

## Acceptance tests

### Deterministic transport tests

- An instrumented shared fake asserts one physical open and one raw `recv` loop while two, then
  many, logical handles each receive every injected external frame in order.
- A handle opened after several records starts at the current tail and receives every record
  committed after its subscription boundary, with no retained history leaking into it.
- Stall one handle beyond ring capacity. Its cursor advances by the exact overwritten count while
  a fast handle receives every frame and ingress never blocks.
- Mutating the `data` returned to one handle cannot change a later result for another handle.
- `recv(0)`, finite timeout and `recv(-1)` preserve the public `Bus` contract. Close and fatal
  failure wake a blocked infinite receive.
- Make the raw reader fail with both an empty and a populated ring. Existing records drain, the
  same sticky error follows for every handle, sends fail, and a new opener waits for physical
  close before receiving a clean generation.
- Race final close with open repeatedly and assert the old raw close always precedes the new raw
  open. Race close with send, ingress and blocked receive without use-after-close or double close.
- Same-wire aliases join one entry and incompatible canonical specs fail. A failed first open
  leaves no entry, so a later attempt can retry cleanly.

### CANsub-specific tests

- Preserve `CansubRecord.tx` through the private raw-record seam.
- Handle A sends: its matched TX acknowledgement is skipped by A and returned once to B and C.
- A and B concurrently send different frames: serialized registration/write order and full-frame
  matching assign each acknowledgement to the correct origin.
- A and B send identical frames: the oldest matching pending origin is chosen deterministically.
- Drop the first of two identical acknowledgements and pin the documented ambiguity: the later
  acknowledgement is assigned to the oldest identical pending item, while expiry counts the
  remaining missing acknowledgement.
- An external frame identical to a pending send remains external because its TX bit is clear.
- An unmatched flagged TX acknowledgement is dropped, increments its diagnostic and is never
  returned as RX to any logical handle.
- A raw send failure keeps its pending item for a short grace: an acknowledgement taken off the
  socket before the write reported failure, or arriving just after, is still attributed and
  published to every other handle, whichever thread reaches the hub first. The known hole: an
  identical frame from another handle inside that grace is credited to the failed item.
- Closing an origin before its acknowledgement does not reclassify that acknowledgement and does
  not prevent remaining handles from receiving it.

### Trace and hardware checks

- PCAN records every successful send exactly once at emit, including startup and no-monitor paths;
  it does not depend on local echo support and creates no synthetic receive event.
- CANsub with a ready monitor records a matched device acknowledgement exactly once. Without a
  ready monitor it records at emit and a later acknowledgement does not duplicate the row.
- Failed sends record nothing at emit on either backend; on CANsub a failed write that the device
  acknowledges within its grace is still recorded once, attributed to its origin.
- Monitor + simulation + software ISO-TP/UDS + Lua can share one PCAN wire and one CANsub wire
  without stealing external frames or receiving their own matched CANsub sends.
- Existing `cmd/silentcheck` phases and CANsub classic/FD, TX-record, reader-failure and bounded
  close benches continue to pass.

The shared fake and lifecycle tests land with the hub. Backend cleanup follows only after those
tests prove the single-reader and close/reopen invariants.
