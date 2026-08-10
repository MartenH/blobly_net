# Simulation — user manual

Blobly Net can *be* the bus as well as watch it. It plays simulated ECUs in its own process, so
a single unit on a bench sees the traffic it would see in a car, and a whole network can be
exercised with no hardware at all.

Everything here is **driver-free and in-process** by default: the `inproc:` transport is a
shared bus inside the running program, so the demos below work identically on Linux and Windows
with nothing plugged in. The same configuration runs against real hardware by changing only the
channel's interface — with one limit worth knowing first: **the hardware transports are classic
CAN.** `transport.CanFrame` carries 0..8 payload bytes, and the SocketCAN and PCAN backends
send `struct can_frame`, so a simulation is 8-byte-limited on a real bus regardless of what the
DBC says. CAN-FD payloads exist only in-process today.

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

## Replay — configurable, but NOT currently played

The project format accepts a replay channel:

```yaml
  - name: CAN1
    mode: replay
    replay: { source: logs/drive.mf4, speed: 1.0, loop: true }
```

**It does nothing today.** `modules/player` can decode `.log` and `.mf4`, but nothing in the app
drives it: there is no replay worker, and `monitorable()` — which decides what gets opened when
you press Start — accepts only `monitor` channels, so a replay channel is not even attached.
Configuring one produces silence, not an error. Reconnecting the player to the GUI is open
work; until then, treat this section as schema documentation rather than a feature.

## Running it without the GUI

```bash
scripts/runtests.sh --project projects/sim-demo.blobnet tests/diag_basic.lua
```

The headless runner brings up the same simulation and executes Lua test scripts against it,
exiting non-zero if any fail — which is what CI uses. The ECUs are built by the same code the
GUI uses, so simulated behaviour matches.

**Two differences to plan around.**

*Vendor bitrates.* Project parsing splits the bitrate out of the interface string, and the
headless runner opens the clean interface — so a PCAN or Kvaser channel configured for anything
other than 500 kbit/s falls back to 500 k and produces no traffic against a bus running at the
configured rate. It works in the GUI, which re-appends the rate. In-process and SocketCAN
channels are unaffected.

*Database paths.* The GUI resolves `databases:` entries
relative to the project file; the headless runner opens them as given, after `runtests.sh` has
changed to the repository root. A project kept outside the repo with relative DBC paths
therefore loads an empty database headlessly — and an empty database means no configured frames,
silently. Use paths that resolve from the repository root, or absolute ones, until the runner
resolves them the same way.

See [scripting.md](scripting.md) for the test API.

## What it cannot do yet

- **Diagnostics are stateless between requests beyond session and security state.** A
  simulated ECU serves the DIDs and DTCs the project gives it; it does not model routines
  (`0x31`), memory access (`0x23`/`0x3D`), or transfer (`0x34`-`0x37`), and writing a DID does
  not affect the signals the ECU transmits.
- **No receive-side validation.** Protection is applied to what is *sent*; the counter and
  checksum of *received* frames are not checked, so a fault in the ECU under test's own
  protection is not flagged automatically.
- **No fault injection** — deliberately corrupting a checksum, freezing a counter, or dropping
  a message to provoke the receiver's error handling. Switching a whole ECU off in the panel is
  the only fault available today.
- **No LIN.** CAN and CAN-FD only; LIN is on the roadmap.
- **Generators are open-loop.** A signal's value follows its formula and cannot react to what
  the ECU under test sends. Closed-loop behaviour belongs in a Lua script.
