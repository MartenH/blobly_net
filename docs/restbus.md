# Rest-bus simulation

A rest-bus simulation plays every ECU on the bus *except* the one you are testing, so a single
unit on a bench sees the traffic it would see in a car. Blobly Net builds those ECUs from the
DBC: message ids, cycle times, signal placement and byte order all come from the database, and
the project file only says what the values should *do*.

## Simulating the rest of the bus

In the Simulation panel each channel lists its simulated ECUs with a tick box, so nodes can be
switched on and off while the bus is running — useful for "does the ECU under test complain
when this one goes quiet?".

A node with no explicit configuration transmits every message the DBC says it sends, at the
cycle time the DBC gives, with signals held constant. The panel says
`(frames derived from the DBC)` for those, rather than `0 sig / 0 resp`, which would read as
"this ECU sends nothing".

Per-signal behaviour is configured in the project file:

```yaml
simulation:
  - name: BCM
    signals:
      - { name: VehicleSpeed, type: sine, offset: 70, amplitude: 60, freq: 0.9 }
      - { name: Gear,         type: stepmod, period: 1, count: 6, base: 1 }
    responses:
      - { request: "0x101", response: "0x102", byte: 0, add: 1 }
```

Generators: `const`, `sine`, `sawtooth`, `counter`, `stepmod`.

## End-to-end protection (counter + checksum)

**This is usually what stands between a simulation that works and one a real ECU ignores.**

Production networks protect messages with an *alive counter* that must advance every cycle and
a *checksum* over the payload. A receiver checks both and rejects — normally also DTC-flags —
anything that fails. Send a perfectly-encoded frame with a frozen counter and the ECU under
test will treat the sender as faulty, which looks exactly like a bug in your bench setup.

Declare it per message:

```yaml
simulation:
  - name: BCM
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
| `data_id` | mixed into the checksum only; never occupies payload |

Both fields are named by **signal**, so width, bit position and byte order come from the DBC. A
signal moved in the database moves here too, and nothing has to be restated.

### What actually happens on each send

1. The generators encode their signals.
2. The **counter** is written — `send_index mod 2^width`, so a 4-bit counter wraps at 16
   exactly where the receiver expects, with nothing to configure.
3. The **checksum field is zeroed**, then computed over the whole payload.
4. `data_id`, if set, is appended to the checksum **input** only.
5. The result is encoded into the checksum signal.

The order matters. The counter is written *before* the checksum is computed, so the counter is
covered by it — otherwise a replayed frame with a stale counter would still checksum correctly.
The checksum field is zeroed first because a checksum cannot cover itself; without that, the
result would depend on whatever the previous cycle left in those bits.

### Profiles

| profile | algorithm |
|---|---|
| `crc8_j1850` | CRC-8/SAE-J1850 — poly `0x1D`, init `0xFF`, final xor `0xFF`. What AUTOSAR E2E profiles 1 and 2 are built on. |
| `crc8_autosar` | CRC-8/AUTOSAR — poly `0x2F`, otherwise identical. Better detection over short payloads. |
| `sum8` | low byte of the arithmetic sum. Not a CRC — named honestly, because many OEM "checksum" signals are exactly this. |
| `xor8` | all bytes XORed. As above. |

The two CRCs are pinned in `modules/sim/e2e_test.v` against their published check values
(`crc8_j1850("123456789") == 0x4B`, `crc8_autosar(...) == 0xDF`). A checksum that is merely
self-consistent is worthless — it has to match what the ECU computes, and those constants are
how that is verified without one on the desk.

An unrecognised `profile` falls back to `sum8` rather than refusing to build the frame: a
config typo that silently stops transmission is harder to diagnose on a bench than a visibly
wrong checksum.

### Not yet supported

- **Full AUTOSAR E2E profiles** (P1/P2 header layouts, P4/P5/P6 with CRC-16/CRC-32 and their
  length/id fields). What is here is the frame-level mechanism — counter, checksum, coverage
  order — not the complete profile state machines.
- **Receive-side validation.** Blobly Net protects what it *sends*; it does not yet verify the
  counter and checksum of frames it receives, so a fault in the ECU under test's own protection
  will not be flagged automatically.
- **Fault injection** — deliberately corrupting a checksum, freezing a counter or dropping a
  message to provoke the receiver's error handling. Planned; the mechanism above is its
  precondition.
