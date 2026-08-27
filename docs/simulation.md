# Simulation — user manual

Blobly Net can *be* the bus as well as watch it. It plays simulated ECUs in its own process, so
a single unit on a bench sees the traffic it would see in a car, and a whole network can be
exercised with no hardware at all.

Everything here is **driver-free and in-process** by default: the `inproc:` transport is a
shared bus inside the running program, so the demos below work identically on Linux and Windows
with nothing plugged in. The same configuration runs against real hardware by changing only the
channel's interface.

**CAN-FD reaches the frames we originate, not just the ones we replay** (#202). The format is a
property of the CHANNEL, declared in the project (`type: canfd` plus a data rate) rather than
inferred from a payload size, and it is applied inside `transport.open` — the same seam
listen-only uses, and for the same reason: an emitter never sees the decision, it is simply
handed a bus that frames what it sends. So generators, senders, E2E protection and the
simulated ECUs all put real FD frames on an FD channel, with BRS when the data phase differs
from the arbitration one. Nothing in `modules/sim` sets the flag itself, and that is the point.
Replay is unchanged: frames read from a recording carry the FD bits the recording captured.

Not every backend can carry it. SocketCAN, `inproc` and `udp` all do; Vector and Kvaser do, both
verified on hardware — PCAN cross-vendor against a Kvaser at 1/2/4/8 Mbit/s (#217), Kvaser and
Vector to 8 Mbit/s, CANsub at 2 Mbit/s.

For *why* it is built this way, see [simulation_architecture.md](simulation_architecture.md) —
that is the design document. This page is how to use it.

## Try it in one minute

Open `projects/sim-demo.blobnet` and press **▶ Start**. Two independent buses come up, several
ECUs begin transmitting, and the trace fills. The **Simulation** panel lists each bus with its
ECUs; the tick boxes switch nodes on and off *while it runs*, which is the quickest way to
answer "what does the ECU under test do when this one goes quiet?".

## The model: networks own the database

A **channel** is a bus. It carries the DBC, the transport, and the ECUs simulated on it:

```yaml
channels:
  - name: CAN1
    type: can
    interface: inproc:CAN1      # in-process. Real hardware: a bare `can0` on Linux
                                # (SocketCAN is the fallback — there is no `socketcan:`
                                # prefix), or `pcan:PCAN_USBBUS1@500000` /
                                # `kvaser:0@500000` on Windows.
    mode: monitor
    databases:
      - dbc/blobly_net.dbc      # the NETWORK owns the database, not the ECU
    simulation:
      - name: SUT               # must SEND something in the DBC — named as a message's
                                # transmitter. A BU_ entry alone is not enough; a node
                                # that owns no message transmits nothing (and is
                                # reported). Response-only nodes are the exception.
        ...
```

Because the database belongs to the network, a simulated ECU never restates message ids, cycle
times, signal placement or byte order. It says only what its values should *do*. Move a signal
in the DBC and the simulation follows.

Channel `mode` is `off`, `monitor` (RX, the default) or `replay`. Simulation runs independently
of the mode — the ECUs configured on a channel transmit whenever the measurement is running.

## Simulating ECUs

### The whole rest of the bus, quickly

```yaml
    simulate: [BCM, ChassisECU, Gateway]     # shorthand: default behaviour
```

Each named node transmits every **cyclic** message the DBC says it sends, at the DBC's cycle
time, with signals held constant. Messages with no `GenMsgCycleTime` (or zero) are event-driven
and are **not** transmitted — nothing decides when they should fire. Send those from the
Generators panel, or drive them from a script; if a rest-bus test needs event traffic, that is
where it comes from. The panel describes these as `(frames derived from the DBC)` rather than
`0 sig / 0 resp`, which would read as "this ECU sends nothing".

**One exception: a node called `SUT`.** That name is special-cased to a hand-tuned reference
model — sines, staircases, a rolling counter and a `0x101`→`0x102` response rule — matching the
Python SUT the native simulation was verified against. Its signals do *not* stay constant. It
is the shipped demo database's own ECU; any other name behaves as described above.

This is the usual starting point for rest-bus work: name every node **except** the one on the
bench.

### With real signal behaviour

```yaml
    simulation:
      - name: SUT
        signals:
          - { name: EngineSpeed,  type: sine,    offset: 1600, amplitude: 1500, freq: 0.7, phase: 0 }
          - { name: BrakePressure, type: sawtooth, min: 0, max: 1500, period: 6 }
          - { name: Gear,         type: stepmod, period: 1, count: 6, base: 1 }
          - { name: Counter,      type: counter, start: 0, step: 1, modulo: 256 }
          - { name: DoorOpen,     type: const,   value: 0 }
```

| `type` | behaviour | parameters |
|---|---|---|
| `const` | a fixed value | `value` |
| `sine` | `offset + amplitude·sin(freq·t + phase)` | `offset`, `amplitude`, `freq` (rad/s), `phase` |
| `sawtooth` | ramps `min`→`max` over `period` seconds, repeating | `min`, `max`, `period` |
| `counter` | `start + step·n` per send, wrapping at `modulo` | `start`, `step`, `modulo` |
| `stepmod` | a staircase: `base + (⌊t/period⌋ mod count)` | `period`, `count`, `base` |

Signals with no generator keep their payload bits at **raw zero**, which is not the same as
physical zero: a signal with an offset decodes as that offset, so a temperature declared with
offset -40 reads as -40 °C rather than 0. Give it a `const` generator if you want a particular
physical value.

A generator naming a signal the node does not send is reported rather than silently ignored.

`counter` is a *signal* generator and is unrelated to the alive counter in
[protection](#end-to-end-protection-counter--checksum) — use that one for E2E.

### Answering requests

```yaml
        responses:
          - { request: "0x101", response: "0x102", byte: 0, add: 1 }
```

When a frame with id `request` arrives, the ECU replies on `response` with the request's payload
and `add` added to byte `byte`. Simple by design — it exists to make round-trips observable, not
to model diagnostics. For real diagnostic behaviour use the scripting layer (below).

The response's frame format (standard or extended) comes from the DBC message with that id.

## End-to-end protection (counter + checksum)

**This is usually what stands between a simulation that works and one a real ECU ignores.**

Production networks protect messages with an *alive counter* that must advance every cycle and
a *checksum* over the payload. A receiver checks both and rejects — normally also DTC-flags —
anything that fails. A perfectly-encoded frame with a frozen counter makes the ECU under test
treat the sender as faulty, which looks exactly like a bug in your bench setup.

```yaml
        protect:
          - { message: Powertrain, counter: AliveCounter, crc: CRC, profile: crc8_j1850, data_id: 42 }
          - { message: DoorStatus, counter: Cnt }
```

| field | meaning |
|---|---|
| `message` | DBC message name to protect |
| `counter` | signal carrying the alive counter — omit for none |
| `crc` | signal carrying the checksum — omit for none |
| `profile` | `crc8_j1850` (default), `crc8_autosar`, `sum8`, `xor8` |
| `data_id` | mixed into the checksum only, never into the payload. `0` is a real id: written explicitly it contributes, omitted it does not, and the two give different checksums |

Both are named by **signal**, so width, bit position and byte order come from the DBC.

### On each send

1. the generators encode their signals;
2. the **counter** is written — `send_index mod 2^width`, so a 4-bit counter wraps at 16 exactly
   where the receiver expects, with nothing to configure;
3. the **checksum field is zeroed**, then computed over the whole payload;
4. `data_id`, if configured, is appended to the checksum **input** as four little-endian bytes;
5. the result is written into the checksum signal.

The counter goes in *before* the checksum is computed, so the checksum covers it — otherwise a
replayed frame with a stale counter would still validate. The checksum field is zeroed first
because a checksum cannot cover itself.

### Profiles

| profile | algorithm |
|---|---|
| `crc8_j1850` | CRC-8/SAE-J1850 — poly `0x1D`, init `0xFF`, final xor `0xFF`. What **AUTOSAR E2E profile 1** uses. |
| `crc8_autosar` | CRC-8/AUTOSAR, a.k.a. **CRC8H2F** — poly `0x2F`. What **AUTOSAR E2E profile 2** uses. |
| `sum8` | low byte of the arithmetic sum. Not a CRC — many OEM "checksum" signals are exactly this. |
| `xor8` | all bytes XORed. As above. |

**These are CRC primitives, not complete AUTOSAR E2E profiles.** The named algorithm is the one
the profile uses, but the surrounding rules are blobly's own: the coverage convention above, and
a Data ID appended as four little-endian bytes to the checksum input. A real profile-1 or -2
receiver also expects that profile's header layout, its Data-ID handling and its counter state
machine, so matching the algorithm name alone does not make a frame interoperable — it can still
reject every one. Full profile support is open work.

Picking the wrong algorithm is a separate and equally real bench trap: a profile-2 receiver fed
`crc8_j1850` computes a different checksum and rejects every frame, indistinguishable from a
wiring fault. The two CRCs
are pinned against their published check values (`0x4B` / `0xDF` over `"123456789"`), so they
match what the ECU computes rather than merely being self-consistent.

### Rules that are easy to get wrong

- **One entry per message.** Protection is keyed by message name, so a second entry for the same
  message replaces the first — put the counter and the checksum in the *same* entry.
- **Use different signals** for `counter` and `crc`. The checksum is computed with its own field
  zeroed, so pointing both at one signal writes the counter and then overwrites it.
- An entry setting **neither** `counter` nor `crc` protects nothing.

All of these, plus unknown message/signal names and unrecognised profiles, are **reported** —
under the node in the Simulation panel, and on stderr from the headless runner. Protection that
matches nothing would otherwise apply nowhere while the panel still displayed its count.

## Whose frame is this? The trace's `origin` column

The moment you simulate, three parties transmit on one bus: **you as tester**, **you as the
ECUs around the device under test**, and **the device under test itself**. All three used to
arrive looking identical — the trace showed `RX`/`TX`, which answered "did I press send", never
"whose frame is this". (On the virtual buses and SocketCAN our own sends also come back to the
monitor, so they landed in the same `RX` pile as the real ECU's.)

The `origin` column answers it, in the vocabulary CAN tooling already uses — `TX` is us, `RX` is
somebody else — with one marker for the half of "us" that is the simulation:

| origin | meaning |
|---|---|
| `TX` | we emitted it as a tester — the Diagnostics panel, generators, Shell, Flash, trace dump |
| `TX-S` | our simulated rest-of-bus emitted it, including its UDS responses |
| `RX` | **not ours** — the device under test, or anything else real |
| `REP` | a recording you opened in the viewer; nothing was transmitted |

`REP` is the one that is not a direction, and deliberately so: a candump line does not say whether
its recorder sent or received it, so calling an imported frame `RX` — as the old column did —
claims something the file cannot support. (When a recording can be *played onto the bus* as the
rest-bus simulation, those frames are ours and become `TX-S`; see #98. `REP` keeps meaning "a file
on screen".)

`origin` is searchable: type `rx` in the trace filter to see only what the real ECU put on the
wire, or `s` (or `sim`, or the full `tx-s`) for only your simulation.

**It is observed, never declared.** The label does not come from your project file. Each emitter
records what it is about to send, and a received frame is matched against those records —
one-shot, oldest first, exact on id width, RTR and payload. What matches nothing of ours is the
other side.

On **PCAN and Kvaser** (Windows only — on Linux those names are ordinary SocketCAN interfaces) the driver never hands your own transmissions back, so there is nothing to
match: `TX`/`TX-S` there come from the tap alone (still accurate — we know what we sent) and
`RX` is everything the driver delivered. No row can be wire-*confirmed* there, and none is
marked for silence — but a row is still marked `!` when the driver **refuses** the send outright,
which is the one wire verdict those backends can give you.

That one-shot rule is what makes the case below visible. Leave a simulated ECU running while the
real one it stands in for is on the bench and both transmit `0x700`:

```
0x700  Heartbeat  CAN1  RX      8   00
0x700  Heartbeat  CAN1  TX-S  290   00
```

Byte-identical frames, two transmitters, two rows. Before this the trace showed one row of 298
and nothing looked wrong. A label derived from configuration would have shown the same single
row — it would have called every `0x700` simulated, because the project says `0x700` is ours.

### `TX-S!` — sent, but never seen on the wire

An outbound row is written when we hand the frame to the driver, so it states *intent*. If the
frame never comes back within a couple of seconds — on a bus where an echo could have arrived —
the row is marked `!`:

```
0x100  Powertrain  CAN1  TX-S!  82   44 01 00 …
```

Intent and wire disagree in every bench failure worth catching. CAN needs an ACK from **at least
one other node**, so a lone node's frames never reach the wire at all — the same goes for a wrong
bitrate, CANH/CANL swapped, or a link that is down. Those all used to look like a working bus.

In the grouped view the mark applies to the **group**: it appears if any frame in the window went
unanswered, not just the newest one — whose echo window has had the least time to close.

**Recordings follow the wire.** A frame we transmit is written to the `.log` when it comes back
off the bus, not when we hand it to the driver — so the file is in observation order. Recording
at emit put a fast responder's answer ahead of the request that caused it, because the simulation
and the monitor are different threads on different sockets and neither waits for the other. Two
consequences worth knowing: a frame that never reaches the wire is not in the recording (it is in
the trace, marked), and on **PCAN/Kvaser**, where the driver never returns our own frames, we
record at emit instead — there is nothing else to record from.

**Silence is not evidence.** The mark is only ever applied where an echo could have arrived: no
monitor on that bus (a generator firing at a channel you are not watching), a channel disabled
mid-run, or a driver that never hands your own transmissions back (PCAN and Kvaser do not) all
mean nobody was looking — so nothing is marked, rather than a healthy bus being accused.

## Diagnostics: a UDS server per ECU

By default each simulated channel runs **one** diagnostic server on `0x7E0` / `0x7E8` with
built-in content, so every ECU answers as the same target. Give a node its own and it becomes a
distinguishable one:

```yaml
    simulation:
      - name: BCM
        uds:
          rx: "0x7E1"          # tester -> ECU (where it listens)
          tx: "0x7E9"          # ECU -> tester (where it answers)
          dids:
            - { id: "0xF190", text: "BLOBLY-BCM-0001" }   # ASCII
            - { id: "0xF195", bytes: "01 00" }            # raw bytes
          dtcs:
            - { code: "0x900101", status: 9 }
            - { code: "0x900102" }                         # status defaults to 0x09
      - name: ECM
        uds:
          rx: "0x7E0"
          tx: "0x7E8"
          dids:
            - { id: "0xF190", text: "BLOBLY-ECM-0002" }
```

A DID's value is `text` **or** `bytes`, never guessed from the string — `"0100"` is four
characters or two bytes depending on which you meant, so you say which.

Supported services are `0x10` session control, `0x22`/`0x2E` read/write by identifier, `0x27`
security access, `0x19` sub `0x02` read DTCs (filtered by the requested status mask), and
`0x3E` tester present. Anything else answers `serviceNotSupported`.

**Configure one and you own diagnostics on that channel:** the built-in `0x7E0`/`0x7E8` server
stops running. Otherwise the two would both answer whenever their ids overlapped, and which
reply the tester saw would depend on scheduling. A channel with no `uds:` anywhere keeps the
default, unchanged.

**29-bit addressing is inferred** from the ids: any address above `0x7FF` opens the ISO-TP
channel in extended format, so normal fixed addressing (`0x18DA10F1` / `0x18DAF110`) works
without a separate flag. Mixing an 11-bit and a 29-bit address in one pair is reported — ISO-TP
uses one format for both.

A configuration that cannot work is **reported and not started**, so it can never half-run:
an unset address, `rx` equal to `tx`, an id beyond 29 bits, a pair mixing 11-bit and 29-bit,
two servers sharing a request *or* a response id, one ECU's request id being another's response
id (it would eat that ECU's replies and answer them with a negative response), a DID above the
16-bit range or longer than 4092 bytes (one ISO-TP transfer, minus the response header), a DTC
above the 24-bit range, or a DTC status that is not a byte.

Out-of-range values are **dropped, never narrowed**, because narrowing turns a mistake into a
different *valid* value: `0x1F190` would masquerade as `0xF190`, DTC `0x1123456` as `0x123456`,
and status `265` as `9`.

**Unticking an ECU silences its diagnostics too**, not just its frames: its ISO-TP channel is
closed, so it neither answers a multi-frame request's flow control nor queues requests to
answer late when it comes back. A test that simulates an ECU going offline finds nothing at its
address, which is the point.

The **Diagnostics panel** picks which target to address when more than one is configured.

## The same ECU over Ethernet (DoIP)

A `type: doip` channel is diagnostics over TCP, not a bus: no frames, no database, no
generators. It is addressed by a **logical pair** rather than CAN ids, so a node on it needs no
`rx`/`tx` — supplying them is reported as ignored:

```yaml
  - name: DoIP1
    type: doip
    interface: doip:127.0.0.1:13400
    tester_address: "0x0E80"      # us
    ecu_address: "0x1000"         # the entity
    simulation:
      - name: SUT
        uds:                      # no rx/tx: addressing is the pair above
          dids:
            - { id: "0xF190", text: "BLOBLYNETV0SUT001" }
```

`sim-demo` ships this alongside CAN1 and CAN2, serving the **same identity** as its `SUT`. A
script reads either carrier with the same body, because the carrier follows the channel:

```lua
local can = uds.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })
local eth = uds.open("DoIP1")                    -- no ids: they cannot be honoured here
check.equal(eth:read_did(0xF190), can:read_did(0xF190))
```

**One channel is one entity at one logical address.** Extra UDS nodes on it have no address to
answer on — the first is served and the rest are reported. Several ECUs means several channels,
as `doip-network-demo.blobnet` does on `127.0.0.1/.2/.3`.

An entity has **two identity surfaces**: what discovery announces and what DID `0xF190` serves.
They are resolved to one string at startup — a disagreement between `vin:` and a node's DID is
refused rather than picked — and a write to `0xF190` moves the announcement with it. Both are
observable:

```lua
check.equal(doip.discover("DoIP1").vin, uds.open("DoIP1"):read_did(0xF190))
```

**The entity announces itself at Start.** ISO 13400 says a DoIP ECU broadcasts a vehicle
announcement when it comes up — three times, 500 ms apart — and that is how a tester discovers
ECUs nobody told it about. Ours does the same, per ECU:

```yaml
    announce_count: 3          # ISO default; 0 = a silent ECU
    announce_interval_ms: 500
    announce_to: ""            # blank = derive (see below)
```

`announce_count: 0` is worth having on purpose: it simulates an ECU that never announces itself,
which is exactly the fault a tester relying on discovery should be tested against.

Where they go is derived from the entity's own address unless `announce_to` says otherwise. A
**loopback** entity broadcasts to `127.255.255.255` and never leaves the machine; anything else
uses the limited broadcast and **does go out on the network the bench is on** — like a real ECU,
and worth knowing before plugging into a shared lab LAN.

From a script, listen for them the way a real tester would:

```lua
local seen = doip.listen(1200)                     -- window in ms, port defaults to 13400
local seen = doip.listen(1200, { port = 13555 })   -- an entity bound elsewhere
-- seen = { { vin = "BLOBLYNETGATEWAY1", logical_address = 0x1000, from = "127.0.0.1:13400" }, ... }
```

Nothing is queued for a listener that is not there, and **a script cannot get there first**: the
entities come up before the suite is parsed, the same way an ECU is powered long before a tester
is plugged in. So a short burst is unobservable from Lua by construction — to test passive
discovery, configure a sequence long enough to still be running when the script starts, as
`projects/doip-announce-demo.blobnet` does. For an entity on the ISO default (three, 500 ms
apart), use `doip.discover()`: asking is what a tester that arrived late has to do anyway. **IPv4 is the verified path**; see the IPv6 caveat in [doip.md](doip.md). `doip.discover(channel)` remains the
ask-and-answer half.

Payload limits follow the carrier, not the ECU: DoIP carries a 64 KiB diagnostic message, so a
DID too large for one ISO-TP transfer is served here and reported there.

> **A real socket.** ▶ Start in the GUI, and `scripts/runtests.sh` headless, both host the
> entity and bind port 13400 while it runs. The channel goes green only once the listener is
> actually up: if the port is taken it stays `idle` and the Log says why, rather than showing
> green beside an entity that is not ours. See [doip.md](doip.md).

## Fault injection

A rest-bus that only sends correct traffic answers one question: does the ECU work when
everything else does. The one a bench actually has to answer is the opposite — does it *notice*
when something is wrong, and does it do the right thing about it.

Per message, from the Simulation panel or from a script:

| fault | what the receiver sees |
|---|---|
| `drop` | the message stops arriving — provokes timeout handling and its DTC |
| `bad_crc` | the checksum no longer matches the payload |
| `freeze_counter` | traffic continues, but the alive counter stops advancing |
| `out_of_range` | one signal carries a value beyond its declared maximum |

From Lua, which is what makes a fault a regression test rather than a demo:

```lua
local d = uds.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })

sim.fault("CAN1", "BCM", "Powertrain", "drop", 3000)  -- 3 s, then it clears itself
sleep_ms(3500)
check.truthy(#d:read_dtcs() > 0, "no DTC after the message stopped arriving")

sim.fault("CAN1", "BCM", "Powertrain", "bad_crc")     -- until cleared
sim.clear_fault("CAN1", "BCM", "Powertrain")
```

The **channel comes first**: a project may run the same node and message names on two buses, and
dropping a frame on the wrong one invalidates observations of a network nobody was testing.

A fault that cannot take effect is **refused, loudly** — an unknown node or message, `bad_crc`
where the project configures no checksum, `freeze_counter` where it configures no E2E counter,
`out_of_range` on a signal with no illegal value. Arming a fault that changes nothing is the
difference between a test that fails and a test that lies.

A fault with a lifetime expires on its own; one without stays until cleared. The distinction
matters because a fault you have to switch off by hand is one you forget to switch off.

**Faults are applied last** — after the generators encode the frame and after protection stamps
it. That is the only order in which "corrupt the checksum" means what it says: a checksum
computed over already-corrupted data is simply a valid checksum for different data, which the
receiver accepts and no test notices.

Details worth knowing:

- `bad_crc` **inverts** the checksum rather than zeroing it, because zero is a legitimate
  checksum value — a receiver that happened to compute 0 would accept the "corrupted" frame.
- `out_of_range` is applied **before** protection, so the frame arrives with a *valid* checksum
  and the receiver reaches its range handling. Applied after, it would be rejected as a
  checksum error and the fault would test the opposite of what it claims.
- `freeze_counter` stalls the **E2E counter only**. An ordinary `counter` generator in the same
  message keeps running — a message may carry both, and freezing the second is behaviour nobody
  asked for.
- `drop` still counts as a cycle, so the counter has moved on by the next frame that *does*
  arrive — a gap, which is how a receiver tells a dropped frame from a stalled sender.
- `out_of_range` needs a signal that can actually carry the violation onto the wire. Three
  cannot, and none is offered: a signal using its whole declared range (there is no illegal
  value), a **multiplexed** signal (only written when its selector is active, so the fault may
  never reach the bus), and the **counter or checksum field itself** (a violation written there
  is overwritten moments later when protection is stamped, and the frame goes out valid).
  Both raw endpoints are considered, so a signal with a negative factor — whose physical
  maximum sits at raw zero — is handled.
- Leaving a `freeze_counter` steps the counter past the frozen value before the first recovered
  frame, so the receiver does not see one more stall *after* the fault is gone.

### Checking the other side's protection

Protection is verified on **received** frames too.

For messages the simulation itself sends, the same `protect:` entries are reused — a project
describes those once and both directions follow it.

For the **ECU under test**, use the channel-level `verify:` block. It is separate on purpose: in
a rest-bus setup that ECU is the one node you deliberately do *not* simulate, so no simulated
node's `protect:` can describe it — and its counter and checksum are exactly what a bench needs
checked.

```yaml
  - name: CAN1
    interface: can0
    databases: [dbc/vehicle.dbc]
    verify:                       # what the ECU on the bench should be sending
      - { message: EcuStatus, counter: AliveCounter, crc: CRC, profile: crc8_j1850 }
    simulation:                   # the rest of the bus
      - name: BCM
```

A channel with only `verify:` and no `simulation:` transmits **nothing at all** — no frames and
no diagnostic server — so it can watch a real bench without putting anything on the wire beside
the ECU under test.

Add `id:` — and `extended:` where one id exists in both formats — when a message name is
ambiguous, since merged databases can carry one name several times:

```yaml
      - { message: Status, id: "0x222", extended: false, counter: Cnt, crc: CRC }
```

**One entry per message**, with the counter and the checksum together. Split across two entries
the second replaces the first, so half the checks would silently not run; that is reported, and
the first entry wins so the result is at least deterministic.

Entries that would check nothing are reported when the measurement starts, and **not built** —
the two decisions share one predicate, so a warning always means the entry really was skipped
rather than applied to the wrong frame. Reported: an unknown message, a signal the message does
not have, an ambiguous name, an entry naming neither field or the same signal for both, an
unrecognised profile, a multiplexed counter or checksum (frames on other branches would go
unchecked), and a malformed `id`/`data_id`. A check that silently does nothing is worse than
none, because it is trusted.

Violations appear beside the message name in the trace:

```
 1240.6  CAN1  RX  0x100  Powertrain  !CRC          11 22 33 ...
 1340.6  CAN1  RX  0x100  Powertrain  !CNT stalled  11 22 33 ...
```

| verdict | meaning |
|---|---|
| `!CRC` | the checksum does not match the payload as received |
| `!CNT stalled` | the alive counter repeated — the sender is stuck |
| `!CNT skipped` | the counter jumped — frames were lost, or the sender restarted |
| `!LEN` | shorter than the DBC message, so its protection fields are not all present |

They are searchable, so typing `!crc` in the trace filter shows only the bad frames, and they
appear in both the grouped and flat trace views.

Recordings are checked too: loading a `.log` or `.mf4` capture re-runs the verification, so a
violation seen live is still there after saving and reopening. Only the channel's `verify:`
entries are applied there — a candump log carries no direction, so a capture made while the tool
was transmitting would otherwise replay our OWN frames as received and report false failures.

How the frames are matched back to a channel depends on where the labels came from:

- a **candump `.log`** names an interface that somebody configured, so its labels are matched
  against the project's channels;
- an **`.mf4`** also carries `CAN_DataFrame.Dir` per frame, which says whether **the recording
  device** transmitted it. That device is not you: in a capture from somebody else's bench, `tx`
  marks *their* tester's traffic. It is the only provenance a recording can hold — a candump line
  has none, so every one reads `unknown` — and it is a hint for #98's subtraction rule, not a
  substitute for the DBC's per-message sender;
- an **`.mf4`** names buses in the RECORDING's own numbering — `CAN_DataFrame.BusChannel`, which
  some writers count from 0 and others from 1 — so its labels arrive as `mf4:bus0`, `mf4:bus2`
  and so on (`mf4:group0`, `mf4:group1`, … for a file that carries no BusChannel at all), and
  they **never**
  go through that matching. They are not names in your project's namespace, and a channel could
  legitimately be called anything, `mf4:bus1` included.

Either way, an unrecognised label resolves to the project's bus only when **both sides** are
unambiguous: exactly one CAN bus configured (the project's bus count, not the number of buses that
happen to carry `simulation:` or `verify:` entries) **and** exactly one bus in the recording. A
one-bus project importing a two-bus capture is still a guess — running both through one stateful
verifier interleaves counters from different buses. Otherwise it is left unchecked rather than
guessed at — attaching one bus's verdicts to another's frames would
be worse than not checking. This is also why the buses stay separate in the trace: before, every
MF4 frame was labelled `can`, so the same id on two buses merged into one row.

J1939 frames resolve through the same PGN fallback the trace uses, since a live frame carries a
different priority and source address than the DBC records. Counter state is kept per actual
id: two source addresses are two senders with two independent sequences.

The checksum is judged **first and alone**: a frame whose checksum is wrong says nothing
reliable about its counter, since those bits are as likely to be corrupt as any others. A
counter wrap is not a skip at any counter width, and the first frame of a stream is never a
violation — a tester attaching mid-stream must not see a fault it caused by arriving. Remote
(RTR) frames are skipped entirely: they carry no payload, so any verdict about their bytes
would be about bytes nobody sent.

## Interactive senders

Triggerable frames, for the "now do this" half of bench work:

```yaml
    senders:
      - name: Rev to 6000 rpm
        key: r                       # single-character hotkey
        message: Powertrain          # resolved via the DBC
        trigger: key                 # manual | key | cyclic
        signals:
          - { name: EngineSpeed, value: 6000 }
          - { name: Gear, value: 4 }
      - name: Cyclic wake
        id: 0x123                    # or a raw id + data, with no DBC involved
        data: 01 00                  # hex TEXT, not a YAML array
        trigger: cyclic
        cycle_ms: 500
```

`trigger` is `manual` (button only), `key` (button plus the hotkey, when no text field has
focus) or `cyclic` (sent automatically while the measurement runs).

`data:` is parsed as a string of hex bytes (`01 00`, `0102FF`). A YAML sequence such as
`[0x01, 0x00]` is *not* interpreted as bytes — it is stringified and misread.

`bus:` sends on a different bus, and it takes the **interface string**, not the channel's name:
`bus: inproc:CAN2`, not `bus: CAN2`. The value is passed straight to the transport, so a
channel name lands there as a device name and fails to open.

## Replay — playing a recording onto a bus

The project format accepts a replay channel:

```yaml
  - name: CAN1
    mode: replay
    replay: { source: logs/drive.mf4, speed: 1.0, loop: true }
```

**It plays.** A `mode: replay` channel is opened at Start like any monitored one and a worker
pumps the recording onto its bus at the recorded cadence. The **Replay panel** (activity bar
▸ Rep, or View ▸ Replay) is the transport surface while it runs: one row per playing recording,
with a seek bar that doubles as the position readout, pause/resume, a **loop** tick and speed
(0.25×–4×) — commands land on the worker within 50 ms, and every bus fed by one recording stays
on that one clock.

**Loop is armed, not pressed.** Ticking it never does anything by itself: the flag is read only
when playback reaches the end of the recording, and it decides whether that end wraps to the
start or stops. So ticking it while paused does nothing until you resume and run out, and
ticking it on a row that has already finished does nothing at all — that end is behind it, and
Restart is what moves it. Panel changes are transport-transient, like speed: `loop:` in the
project is what a Stop/Start restores, and the row says so while the two differ.

Two keys carry the facts a recording cannot supply — `bus:` (which recorded bus feeds this
channel; a multi-bus `.mf4` holds several and their names are the recording's, not the
project's) and `exclude:` (nodes whose messages are withheld, resolved through the channel's
databases by DBC sender).

**Scan fills those keys from facts.** The Configure replay row's **Scan recording** button
decodes the file off the UI thread and shows what is in it: every bus with its frame count
(`use` writes `bus:`), and per bus the nodes the attached DBCs attribute frames to — with
counts, because on a captured vehicle bus the busiest node is usually the ECU now sitting on
the bench. Tick a node to put it in `exclude:`; frames with no declared sender and ids the
DBC does not define are counted separately and replay regardless (the same policy the replay
itself applies — the preview and the subtraction share one attribution, `player.census`
beside the `Decider`). Scan is display-only: Start loads the recording for itself either way.

**The panel shows the grouping before it exists.** While stopped, the Replay panel lists the
replay channels grouped **by recording** — the spawner's own canonical-path key — with the
shared file as the header and each member's recorded bus beside its play-on-Start tick.
"(one clock)" appears over the members that will actually PLAY (ticked, not listen-only, not
DoIP): the badge describes the group Start builds, and a member Start would drop says why in
red instead of counting toward it. Where a Scan of that recording exists, the pairing is
checked through the same resolver Start uses — a `bus:` the file does not hold, an ambiguous
empty one, or one recorded bus mapped twice all show Start's refusal before Start gives it;
without a Scan the panel says it cannot know rather than guessing. Speed/loop disagreements
inside a group are flagged the same way (one clock means one pacing).

**The set is fixed at Start.** Which replay channels play is decided when you press Start, and
ticking one on or off while the run is going says so rather than taking effect — Stop and Start
to change it. Channels reading one recording share a clock, so a channel joining late could not
be given the timing the others already have, and one leaving would hand its bus to whoever asked
for it next while the worker was still writing to it. Both were real defects; neither is worth a
click.

The frames are transmitted as **TX-S**, not `REP`: they are ours, put on the wire by us, so the
trace counts them with the simulation and claims their echoes. `REP` still means a file on
screen, where nothing was transmitted.

**It is PLAYBACK, not simulation**, and the difference decides whether it is enough for a given
bench. A recording cannot answer a request, and its alive counters and CRCs are the recorded
ones — consistent within a lap, jumping backwards at a `loop:` wrap, where a receiver policing
counter continuity will flag them once per lap. Simulated nodes stamp those fresh (`protect:`)
and can answer (`responses:`). What replay buys instead is traffic no generator reproduces: real
signal values, real jitter, real event-driven messages, from the car itself.

**Headless, it works.** `cmd/restbus` replays one recorded bus onto a live one with the ECU
under test subtracted:

```sh
v -enable-globals -path "@vlib|@vmodules|modules" run cmd/restbus/main.v \
    --source capture.mf4 --bus CAN1 --dbc CAN01.dbc --exclude SUT_ECU --iface vcan0
restbus --source capture.mf4 --list          # which buses the recording holds
restbus ... --dry-run                        # what the subtraction would do, transmitting nothing
```

`--bus` takes either the recording's own name for a bus (`CAN1`) or the label its frames carry
(`mf4:group25`); the name is a convenience, the label is the identity.

**Several buses at once**, which is what a real bench needs — the ECU under test sits on all of
them and gateways between them:

```sh
restbus --source capture.mf4 --exclude SUT_ECU \
    --map CAN1,vcan0,com/CAN01.dbc \
    --map CAN2,vcan1,com/CAN02.dbc
```

Every mapped bus replays from **one time-sorted stream against one clock**, so the recording's
cross-bus ordering survives. Separate players per bus would put an arbitrary skew between them —
invisible in a trace, and exactly the relationship a gateway is built to police. Frames are
relabelled to their destination interface as they are selected, so the sender is a map lookup.

Two mappings are refused rather than warned about, because both produce a run that looks like it
worked: the same recorded bus mapped twice (its traffic sent two ways), and two recorded buses
mapped onto one interface (ids that never shared a wire colliding — the collapse `mf4:busN`
labelling exists to prevent, reintroduced by config). A mapped bus that yields no frames, or
whose every frame belongs to the excluded node, is reported per bus rather than summed away. The subtraction itself is
in `modules/player` (`without_senders`, `on_bus`, `check_nodes`), so the GUI will not have to
re-decide any of it.

**What it does with the awkward cases**, none of which the database answers on its own:

| case | what happens | why |
|---|---|---|
| message sent by an excluded node | withheld | the SUT is the only source of its own messages |
| message with no transmitter in the DBC (`Vector__XXX`) | replayed; `--drop-unattributed` withholds | no safe default: replaying risks a collision, withholding risks silence. The report counts them and names the ids either way |
| **remote frame** (a request for an id, not a transmission of it) | never replayed, and counted | this app does not transmit remote frames at all — CAN-FD has none and nothing here asks for one (#215). They are still decoded and shown, so a recording that contains them reads honestly; they are simply not put back on a wire |
| id absent from the DBC entirely | replayed | the recording proves it was on the wire; the database is one description of the bus, not the bus |
| `--exclude` names a node the DBC does not declare | **refused, exits non-zero** | a typo subtracts nothing and looks exactly like a working rest bus |

Pacing sleeps until each frame is due rather than polling on a tick, because a tick quantises
every message's recorded period and real captures go well below one: on the recordings this was
built against, a busy bus can repeat a frame in well under a millisecond. Filtering never changes the cadence —
the loop is pinned to the *source* bus's span, so removing the SUT's frames cannot shorten a lap
or move its origin.

**CAN-FD replays.** The `fd`/`brs` flags come from the recording's own `EDL`/`BRS` fields (and a
payload over 8 bytes is FD whatever the flag says), and travel through to the wire. `--dry-run`
reports the FD share, because the destination interface has to be FD-capable and up — SocketCAN
declines `CAN_RAW_FD_FRAMES` on a classic interface, and the send then fails with that named as
the likely cause rather than a bare errno. This matters at real scale: of one vehicle's 12
databased buses, six are majority FD, one entirely so.

**Who counts as a sender.** A DBC may name additional transmitters with `BO_TX_BU_`, and the
subtraction honours all of them — matching only the `BO_` transmitter would leave the SUT's own
frames in the replay whenever it is the secondary sender.

**It is tracked, not forgotten: [#98](https://github.com/MartenH/blobly_net/issues/98).** The
point of finishing it is a rest bus driven by *a real capture from the car* rather than by
signal generators somebody typed — the SUT hears its actual environment. The plumbing is small but not one line
(a worker pumping `player.due()` onto the bus, `monitorable()` accepting replay channels, and
**source-bus selection** — a multi-bus `.mf4` loads every bus into one entry list, so the config
has to say which recorded bus feeds which channel; `canlog`/`mf4` already read the files and
`player` already paces them);
the part that needs deciding is what to **leave out**, because a capture contains the ECU under
test too, and replaying its own messages back at it puts two transmitters on every one of its
ids. The DBC already names each message's sender, which is most of what makes the subtraction
possible — but not all of it: a DBC may give a message **no** transmitter (`Vector__XXX`, which
`candb` normalises to empty), and nothing in `replay:` says which node is the ECU under test. So
the rule needs both an explicit "this is the SUT" and an answer for messages the database cannot
attribute — replay them, or hold them back — rather than assuming every id resolves.
Those frames are our simulation, sourced from a file, and the trace would label them as such
rather than as a recording — `REP` means "a file on screen", where nothing was transmitted.

## Running it without the GUI

```bash
scripts/runtests.sh --project projects/sim-demo.blobnet tests/diag_basic.lua
```

The headless runner brings up the same simulation and executes Lua test scripts against it,
exiting non-zero if any fail — which is what CI uses. The ECUs are built by the same code the
GUI uses, so simulated behaviour matches.

Database paths and vendor bitrates are handled exactly as the GUI handles them — `databases:`
entries resolve against the project file's own directory, and a PCAN or Kvaser channel is
opened at its configured rate — so a project kept anywhere on disk, at any bitrate, behaves the
same either way. Paths you pass on the command line are made absolute before the wrapper
changes to the repository root, so `--project my.blobnet` works from whatever directory you
happen to be in.

See [scripting.md](scripting.md) for the test API.

## What it cannot do yet

- **Diagnostics are stateless between requests beyond session and security state.** A
  simulated ECU serves the DIDs and DTCs the project gives it; it does not model routines
  (`0x31`), memory access (`0x23`/`0x3D`), or transfer (`0x34`-`0x37`), and writing a DID does
  not affect the signals the ECU transmits.
- **One logical address per DoIP channel.** An entity answers for itself; several ECUs over
  Ethernet means several channels.
- **No LIN.** CAN, CAN-FD and DoIP; LIN is on the roadmap.
- **Generators are open-loop.** A signal's value follows its formula and cannot react to what
  the ECU under test sends. Closed-loop behaviour belongs in a Lua script.
