# Rest-bus simulation

An ECU on a bench is alone. It expects the car around it: the other nodes' cyclic messages, their
alive counters and checksums, network management, an answer when it asks. Without them it sets
timeout DTCs, refuses to leave its fallback mode, or simply goes to sleep. A **rest bus** is that
car, played by Blobly Net: the ECU under test is the one real node, and every other node on its
buses is simulated.

**Quick start.** In the project, add one line to the bus the ECU sits on, naming every node of its
database except the ECU under test and the tester you play yourself:

```yaml
    simulate: [BodyECU, ChassisECU, BatteryECU]
```

Set the bus's adapter, press **▶ Start**, and the `TX-S` rows in the trace are the rest bus.

![A DBC or ARXML database feeds Blobly Net's simulated nodes, which put cyclic frames on the CAN bus, with E2E counters and checksums where the database declares them; from the project they also answer UDS requests and, where the bus's NM cluster is configured, announce network management. The real ECU under test sits on the other side of the bus, and a Python or Lua test sets signals in the simulated nodes and checks what the ECU under test sends back.](rest-bus.drawio.svg)

There are two ways to build one:

| | from the database | from a recording |
|---|---|---|
| what you need | the bus's DBC or ARXML | a capture of the real car, and the DBC to say who sent what |
| what it sends | the other nodes' messages, at the database's timing | the capture, with the ECU under test's own frames taken out |
| counters and checksums | fresh per frame, where the database's E2E declaration or a `protect:` entry names them (otherwise a counter signal holds its start value) | the recorded ones; they jump back where a loop wraps |
| signal values | start values, generators, or values a script sets | the car's real values and jitter |
| answers requests | yes, through the project: the built-in UDS server or `uds:` servers, and `responses:` rules on a node | no |
| faults on demand | yes | no |

**Start from the database.** It needs nothing but the file the OEM already gave you, it behaves
the same on every run, and a test can set any signal a simulated node sends (all but the E2E
counter and checksum) or drop or corrupt any of its messages on purpose. Replay is the second way,
for when real signal behaviour matters more than control ([below](#from-a-recording-instead)).

This page is the guided path. [simulation.md](simulation.md) has the full rules for each piece.
A project lists its buses under `buses:`; each entry is a **row** (one row of the Buses panel)
with its adapter, its databases and what is simulated on it.

## From a DBC, in one line

**The rule: in `simulate:`, name every node except the ECU under test and the tester you play
yourself.** The node names are the DBC's `BU_` line, which the DBC editor shows under **ECU Nodes
(BU_)**. The network owns the database, so a simulated node never restates an id, a cycle time or
a signal's position; move a signal in the DBC and the rest bus follows
([the model](simulation.md#the-model-networks-own-the-database)).

[`projects/restbus-db.blobnet`](../projects/restbus-db.blobnet) is a complete rest bus, with no
hardware and no drivers:

```yaml
project:
  name: Rest bus from the database
  version: 2

buses:
  - name: CAN1
    adapter: virtual
    address: RESTBUS
    databases:
      - ../dbc/blobly_net.dbc
    simulate: [BodyECU, ChassisECU, BatteryECU]
```

The demo database names five nodes: `SUT`, `Tester`, `BodyECU`, `ChassisECU` and `BatteryECU`.
`SUT` is the ECU under test. `Tester` is the role your test plays: its only message, `Request`,
has no cycle, so a simulated `Tester` would send nothing anyway. Those two are left out.

In your own project, type the `simulate:` line under the bus in **Configuration ▸ File** and
press **Save text** (the Buses tab has no field for it). Then press **▶ Start** and check:

- the **Simulation** panel lists the bus with its simulated nodes;
- the trace fills with `TX-S` rows, one per simulated frame;
- headless, the start line says `simulating 3 node(s)`.

What each named node then sends, all read from the DBC:

- every **cyclic** message it transmits (as the `BO_` transmitter or in `BO_TX_BU_`), at its
  `GenMsgCycleTime` (else the file's default), the first one after `GenMsgStartDelayTime`;
- every signal at its **start value**: `GenSigStartValue`, else the file's `BA_DEF_DEF_` for it,
  else raw 0. Raw 0 is not physical 0: the demo's `InteriorTemp` has offset -40, so it reads
  -40 °C;
- an **event** or **mixed** message (`GenMsgSendType`) when the raw value of one of its signals
  changes, by a generator that moves with time (`sine`, `sawtooth`, `stepmod`) or by a value a
  script sets or clears: once plus `GenMsgNrOfRepetition` repetitions, `GenMsgCycleTimeFast` apart
  (10 ms where the file states neither that nor a delay), never closer than `GenMsgDelayTime`.
  A mixed message keeps its cycle as well;
- a **multiplexed** message with its multiplexor first and only the selected page's signals;
- a message in the **format** its database states for it (classic, CAN-FD, BRS), else the row's.

What it does not send:

- an event-only message nothing changes. A start value is not a change, and neither is a `const`
  or a `counter` generator, so such a message stays silent until a time-moving generator or a
  script changes one of its signals;
- a message with neither a cycle time nor an event send type, such as `Tester`'s `Request`;
- anything, if the node owns no message in the DBC. That is reported, since a node listed only in
  `BU_` transmits nothing.

The node's entry in the Simulation panel (expand it) and the headless runner's output say how
many of its messages are never sent. [The whole rest of the bus, quickly](simulation.md#the-whole-rest-of-the-bus-quickly)
has the exact timing rules.

Do not list a node named **`SUT`** expecting the plain DBC-derived node: a `SUT` with no
`signals:` or `responses:` of its own gets the demo database's hand-tuned model instead
([the exception](simulation.md#the-whole-rest-of-the-bus-quickly)).
[`projects/restbus-2vcan.blobnet`](../projects/restbus-2vcan.blobnet) is the other way round:
on two vcan buses it simulates `SUT` too, with generators and a response rule of its own, as a
stand-in for an ECU that is not on the bench.

**On a bench**, change the adapter: `adapter: socketcan` with `address: can0` on Linux, with the
link brought up at the bus's bitrate (`ip link set can0 up type can bitrate 500000`), or
`adapter: pcan` / `kvaser` / `vector` with `bitrate: 500000` on Windows
([can_hardware.md](can_hardware.md), [windows_can_hardware.md](windows_can_hardware.md)). If the
ECU answers diagnostics on `0x7E0` / `0x7E8` itself, add `builtin_uds: false`
([below](#diagnostics-in-the-rest-bus)), or two ECUs answer every request. One row per bus the
ECU sits on, each with its own database and `simulate:` list.

## From AUTOSAR ARXML

An ARXML system description is a database entry like a DBC. The shipped fixture
`dbc/example.arxml` has one CAN cluster, `Body`, and three ECUs; with `ECU_A` under test:

```yaml
  - name: CAN1
    adapter: virtual
    address: BODY
    protocol: canfd               # Body carries a CAN-FD frame
    bitrate: 500000
    data_bitrate: 2000000
    databases:
      - "../dbc/example.arxml#Body"
    simulate: [ECU_B, ECU_C]
```

`#Body` names the cluster, which a file with several clusters requires. The cluster carries a
CAN-FD frame, so the row is CAN-FD; Start warns when it is classic. `ECU_C` follows the rule but
sends nothing here: its one frame, `Wide`, is event-only.

The file is read natively, so it stays the source of truth: nothing is regenerated when the OEM
sends a new one. What the reader could not resolve, or chose not to extract, is reported on load
rather than dropped, and so is what the simulation does differently from the file: a frame with
mixed cyclic and event timing is sent on its cycle only, an event-only frame is not sent, and a
SecOC layout is carried but not stamped.

**Import ARXML...** in the Configuration panel builds the rows for you. It takes an `.arxml`, an
`.arxmodel.toml` (several files merged as one description), or an ExtractEditor `.e3proj` (which
also ticks the ECU its extract is of):

1. map each CAN cluster onto an interface, or leave it out;
2. tick the ECUs under test;
3. leave **simulate every other ECU that sends on an imported cluster (rest bus)** ticked (it is
   by default);
4. **Import**.

Each mapped cluster becomes a row reading `net.arxml#<Cluster>` at the cluster's rate (CAN-FD
when the cluster carries an FD frame), with every ECU that sends on it but the ones under test in
`simulate:`. The rows hold references only: frames, timing and E2E stay in the file. The rates are
the one thing copied, so Start warns when a row no longer matches the cluster it reads, as a
reissued extract can leave it: its CAN-FD setting on any adapter, and its rate and data rate where
Blobly Net sets them (PCAN, Kvaser, Vector, CANsub; on SocketCAN the rate is `ip link`'s).

For a tool that needs a DBC, `cmd/arxml2dbc` ([source checkout only](building.md#command-line-tools-source-checkout-only)) exports one with the E2E contract as attributes
wherever the DBC attributes can express it (the load notes name any contract it leaves out).
[simulation.md](simulation.md#the-model-networks-own-the-database) has the reader's rules.

## Making it behave

Start values are enough for an ECU that only checks the messages arrive. When it reacts to their
content, give the signals behaviour. There are three ways, and they combine.

**Generators in the project**, per signal of a simulated node. The node keeps every other signal
at its start value:

```yaml
    simulation:
      - name: ChassisECU
        signals:
          - { name: WheelFL,       type: sine,     offset: 60, amplitude: 8, freq: 0.9 }
          - { name: BrakePressure, type: sawtooth, min: 0, max: 1500, period: 6 }
      - name: BodyECU          # no signals: the same as listing it in simulate:
```

The value sources are `const`, `sine`, `sawtooth`, `counter` and `stepmod`
([with real signal behaviour](simulation.md#with-real-signal-behaviour)). The GUI has no field to
type a value into a simulated signal; a value changes through a generator like these or a script.

**One signal set from a test**, while everything else goes on as the project makes it: a pedal
pressed, a door opened. The value is written over the node's own source and **before protection**,
so the checksum covers it and the receiver sees a valid frame:

```lua
sim.set("CAN1", "ChassisECU", "BrakeStatus", "BrakePedal", 80)   -- from the next frame
expect_signal("CAN1", 0x301, "BrakePedal", 80, 1000)
sim.clear("CAN1", "ChassisECU", "BrakeStatus", "BrakePedal")     -- back to the project's source
```

From Python it is `net.set_signal(...)` / `net.clear_signal(...)`, and from C `bb_sim_set` /
`bb_sim_clear`. A value that cannot reach the wire is refused: the E2E counter or checksum, a value
wider than the signal, a node or message that is not simulated there. A value past the signal's
declared range is allowed, since a test sends one on purpose
([setting a signal](simulation.md#setting-a-signal)).

**The bits no signal covers** go out as 0 unless the row or the ARXML states a fill byte, as an
AUTOSAR sender's unused-bit pattern does: `fill: 0xFF` on the row
([fill](simulation.md#the-bits-no-signal-covers-fill)).

## Protection and network management

A real ECU rejects a frame whose alive counter does not advance or whose checksum is wrong, and
usually sets a DTC for it. A rest bus that gets this wrong looks exactly like a broken bench.

**E2E is stamped by each simulated sender.** A message whose DBC declares it (`E2ECounterSignal`,
`E2ECrcSignal`, `E2EProfile`, `E2EDataId`, defined in [dbc_attributes.md](dbc_attributes.md)), or
whose ARXML states it, is protected with no configuration at all: the simulated `Chassis` of
[`projects/e2e-demo.blobnet`](../projects/e2e-demo.blobnet) stamps its `BrakeStatus` that way.
For a database that declares nothing, a `protect:` entry on the node says the same:

```yaml
    simulation:
      - name: Chassis
        protect:
          - { message: BrakeStatus, counter: BrakeCounter, crc: BrakeCrc, profile: autosar_p01, data_id: 0x1244 }
```

The counter and checksum are named by signal, so their width and position come from the database.
`autosar_p01` and `autosar_p05` are AUTOSAR E2E Profiles 1 and 5 as specified; the other profiles
are checksum primitives for OEM schemes. A `protect:` entry overrides the database's declaration,
for example a wrong Data ID on purpose
([end-to-end protection](simulation.md#end-to-end-protection-counter--checksum)). A declaration
Blobly Net cannot apply is reported at load, and the message goes out unprotected. From ARXML that
means a profile other than PROFILE_01 or PROFILE_05, a data-id mode other than ALL-16-BIT, or a
protected range that is not the whole frame.

**Network management.** To keep the network awake for the ECU under test, the simulated nodes
announce their NM PDU on the cluster's cycle while the run is up. With a plain DBC, state the
cluster on the row and each announcing node's NM id and NID on the node:

```yaml
    nm: { lo: 0x500, hi: 0x53F, timeout_ms: 2000, cycle_ms: 200 }
    simulation:
      - name: BodyECU
        nm: { id: 0x511, nid: 0x11 }
```

A node without its own `nm:` entry announces nothing there, and a row's range with no `cycle_ms`
announces nothing at all. An ARXML cluster gives each ECU's NM id but not its NID, so a node adds
`nm: { nid: … }`; blobly_emb's `system.toml` (the system description of Blobly's embedded ECU
framework) gives both. A script releases the network, and the nodes fall silent, then requests it
again: Python `ch.nm().release()` / `ch.nm().request()`, Lua `nm.release(ch)` / `nm.request(ch)`
([network management](simulation.md#network-management), [nm.md](nm.md#simulated-nodes-announce)).

**Checking the ECU under test's own protection.** The node you do not simulate is the one whose
counter and checksum most need checking. Describe them in the row's `verify:` block:

```yaml
    verify:                       # what the ECU on the bench should be sending
      - { message: BrakeCommand, counter: CommandCounter, crc: CommandCrc, profile: autosar_p01, data_id: 0x2201 }
    simulation:                   # the rest of the bus
      - name: Chassis
```

A frame that fails shows `!CRC`, `!CNT stalled`, `!CNT skipped` or `!LEN` beside its name in the
trace, and a script reads a verdict on each received frame (the same ones, plus `timeout` where
the message declares `E2ETimeout`)
([checking the other side's protection](simulation.md#checking-the-other-sides-protection)).

## Diagnostics in the rest bus

Each wire with simulated nodes runs one built-in UDS server on `0x7E0` / `0x7E8` unless a node on
that wire has a `uds:` block of its own; the headless runner's start line says `+ UDS server`.
When the ECU on the bench answers those ids itself, turn it off with `builtin_uds: false` on the
row (any enabled row on the wire turns it off for the wire).

Give a simulated node a `uds:` block and it becomes its own diagnostic target, with its own
addresses, DIDs and DTCs, so a tester can address each simulated ECU apart
([a UDS server per ECU](simulation.md#diagnostics-a-uds-server-per-ecu)). A node's `responses:`
rules answer a request frame with a response frame ([answering requests](simulation.md#answering-requests)).

Over Ethernet, a `type: doip` row hosts a DoIP entity for the node listed in its own
`simulation:`. That node is addressed by the row's `tester_address` / `ecu_address` and has no
CAN ids; one entity per row, so give it the same DIDs to serve the same identity as a CAN node
([over Ethernet](simulation.md#the-same-ecu-over-ethernet-doip)). Where a blobly_emb `system.toml`
describes the ECUs, a simulated server addressed like one of its nodes answers as that node's
`ecu.toml` describes it: its DIDs at their sizes, its session and security gates, its faults
([described servers](simulation.md#described-servers-an-ecu-as-blobly_emb-describes-it)).

## Robustness: fault injection

A rest bus that only sends correct traffic answers one question: does the ECU work when everything
else does. The bench question is the opposite: does it notice when something is wrong. Break one
message of one simulated node, from the Simulation panel or a script:

| fault | what the ECU under test sees |
|---|---|
| `drop` | the message stops arriving: its timeout handling and DTC |
| `bad_crc` | the checksum no longer matches the payload |
| `freeze_counter` | traffic continues, the alive counter stops |
| `out_of_range` | one signal past its declared range, with a valid checksum |

```lua
sim.fault("CAN1", "ChassisECU", "WheelSpeeds", "drop")         -- until cleared
sim.fault("CAN1", "ChassisECU", "BrakeStatus", "drop", 3000)   -- 3 s, then it clears itself
sim.clear_fault("CAN1", "ChassisECU", "WheelSpeeds")
```

From Python: `net.fault(...)`, `net.clear_fault(...)`, `net.clear_faults()`. A fault that cannot
take effect is refused, for example `bad_crc` on a message the node stamps no checksum on (no
`protect:` entry and no E2E declaration in the database), so a test cannot pass for the wrong
reason ([fault injection](simulation.md#fault-injection)).

## From a recording instead

Replay a capture of the real car with the ECU under test **subtracted by DBC sender**: every frame
of a message the DBC says the excluded node transmits is withheld. The rest go out at their
recorded cadence, except remote frames, which are never replayed. A frame whose message has no
transmitter in the DBC, or is not in it, is replayed, so with an incomplete DBC some of the ECU's
own frames get through; check the counts **Scan recording** shows. In the GUI it is a
`mode: replay` row:

```yaml
  - name: CAN1
    adapter: socketcan
    address: can0
    mode: replay
    databases: [db/vehicle.dbc]
    replay: { source: logs/drive.mf4, bus: CAN1, exclude: [SUT_ECU], loop: true }
```

The row's **Scan recording** button lists the recording's buses and, per bus, the nodes the DBC
attributes frames to, with counts; tick the ECU under test to fill `exclude:`. The Replay panel
pauses, seeks, changes speed and loops while it runs.

Headless, `cmd/restbus` does the same from a source checkout (`./scripts/setup_env.sh` installs
the toolchain); `restbus` below stands for `v -enable-globals run cmd/restbus/main.v`:

```sh
restbus --source capture.mf4 --list                  # the buses the recording holds
restbus --source capture.mf4 --bus CAN1 --dbc db/vehicle.dbc --exclude SUT_ECU --iface can0
restbus ... --dry-run                                # what the subtraction would do, sending nothing
restbus ... --drop-unattributed                      # withhold frames no DBC transmitter claims
restbus --source capture.mf4 --exclude SUT_ECU \
    --map CAN1,can0,db/CAN01.dbc --map CAN2,can1,db/CAN02.dbc
```

Several buses replay from **one clock**, so the cross-bus timing a gateway polices survives. An
`--exclude` naming a node that no mapped database declares is refused, because a typo would
subtract nothing; a node that only some of the databases declare is noted for the buses whose
database lacks it. A large `.mf4` is streamed from the file rather than loaded. Lua's
`replay.start` and Python's `net.replay` play a recording onto a running project's row the same
way.

Prefer a recording when the ECU's behaviour depends on realistic signal values, jitter or event
traffic no generator reproduces. Prefer the database for everything else: a recording cannot
answer a request, its counters and checksums are the recorded ones (a receiver policing counter
continuity flags each loop wrap), and nothing in it can be changed or broken on demand. The two
mix: a replay row for one bus beside database-driven rows for the others. In the GUI the replay
row plays at Start; headless (the Lua runner, Python) it comes up as a plain bus and plays when
the script calls `replay.start` / `net.replay`
([replay](simulation.md#replay--playing-a-recording-onto-a-bus)).

## Running it

**In the GUI.** Open the project and press **▶ Start**. The **Simulation** panel lists each bus
with its simulated nodes; untick one while it runs to see what the ECU under test does when that
node goes quiet. The trace's `origin` column tells the parties apart: `TX-S` is the rest bus
(simulated nodes and a replayed recording), `TX` is you as tester, and `RX` is everything Blobly
Net did not send: the ECU under test, plus any other real node on the bus. Type `rx` in the trace
filter to see only frames that were not ours
([whose frame is this](simulation.md#whose-frame-is-this-the-traces-origin-column)). The
**Script** panel runs a Lua suite such as [`tests/rest_bus.lua`](../tests/rest_bus.lua) against
the running project.

**Headless, from Lua.** A suite names its project in a `-- @project` line in its leading comment,
resolved relative to the script, so it runs from any directory:

```lua
-- @project ../projects/restbus-db.blobnet
test("the brake pedal reaches the bus", function()
  sim.set("CAN1", "ChassisECU", "BrakeStatus", "BrakePedal", 80)
  expect_signal("CAN1", 0x301, "BrakePedal", 80, 1000)
end)
```

From a source checkout, `./scripts/runtests.sh` runs it (the first run compiles the runner):

```sh
./scripts/runtests.sh tests/rest_bus.lua
```

```
project: Rest bus from the database  (.../projects/restbus-db.blobnet)
channel CAN1 (inproc:RESTBUS): simulating 3 node(s) + UDS server

=== .../tests/rest_bus.lua ===
  ok   the rest bus is up
BodyStatus    0x200 from BodyECU    every  200.0 ms (DBC: 200 ms)
WheelSpeeds   0x300 from ChassisECU every   20.0 ms (DBC: 20 ms)
BrakeStatus   0x301 from ChassisECU every   50.0 ms (DBC: 50 ms)
BatteryStatus 0x400 from BatteryECU every  500.1 ms (DBC: 500 ms)
  ok   each simulated node sends its messages at the database's cycle
  ok   with no ECU attached, nothing of SUT's is on the bus
  ...
```

The measured cycles vary a little from run to run, and `UDS server` is the built-in one on
`0x7E0` / `0x7E8`. The runner exits non-zero when a test fails, and `--report run.json` writes the
verdict as data ([scripting.md](scripting.md#exit-status-and-the-run-report)).

**From Python.** The rest bus runs inside the script's own process. With `blobly` installed
(`pip install blobly`, or a checkout's `python/` on the path:
[setting up](scripting_python.md#1-setting-up)):

```python
import blobly

with blobly.Project("projects/restbus-db.blobnet") as net:
    net.wait_ready(5000)
    can1 = net.channels.CAN1
    net.set_signal(can1, "ChassisECU", "BrakeStatus", "BrakePedal", 80)
    frame, pedal = can1.expect_signal("BrakeStatus", "BrakePedal", 80, 1000)
    net.fault(can1, "ChassisECU", "WheelSpeeds", "drop", ms=500)
```

[`python/examples/rest_bus.py`](../python/examples/rest_bus.py) is the same story as a complete
script. For a test suite, blobly's pytest plugin starts the project once per module (or once per
session) and begins each test with every channel's queue read away, so a test hears only what
arrives during it; handlers and faults a test leaves behind are cleared after it
([testing with pytest](scripting_python.md#15-testing-with-pytest)).

**In CI.** Both run with no hardware on an `inproc:` bus, and the bench and the CI run can share
one project file: `--interface CAN1=inproc:CI` on `scripts/runtests.sh` attaches a row to another
interface for one run ([scripting.md](scripting.md#usage)); from Python it is
`blobly.Project(path, interfaces={"CAN1": "inproc:CI"})`, and the pytest plugin takes
`blobly_interfaces` / `--blobly-interface` the same way. A test of the rest bus alone runs
anywhere; a test of the ECU's answers needs the ECU, or a stand-in for it in CI. `tests/rest_bus.lua`
is the first kind, and its check that nothing of `SUT`'s is on the bus holds only with no ECU
attached.

## Limits

- **Generators are open-loop.** A signal follows its formula and cannot react to what the ECU under
  test sends; closed-loop behaviour belongs in a script.
- **An event-only message is silent** until a time-moving generator (`sine`, `sawtooth`,
  `stepmod`) changes one of its signals or a script sets one; `const` and `counter` never trigger
  it. A message with neither a cycle time nor an event send type is never sent.
- **No GUI field sets a simulated signal.** Use a generator in the project or a script (the Script
  panel runs Lua).
- **A recording cannot answer**, and its counters and checksums are the recorded ones.

[What it cannot do yet](simulation.md#what-it-cannot-do-yet) lists the rest, diagnostics and DoIP
included.
