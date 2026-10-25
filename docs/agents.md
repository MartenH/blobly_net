# Driving Blobly Net as an AI agent

This page is for an AI agent (or a person scripting one) that drives Blobly Net. It covers
installing and running it, finding out what a project offers at run time, and the habits that
keep a run bounded and its result readable.

## What it is

Blobly Net is an automotive bus tester. It exercises a system under test over CAN, and over
Ethernet through DoIP and SOME/IP: it runs diagnostics, simulates ECUs, scripts tests and reads
back logs. A **project** (a `.blobnet` file) names the channels, the interface each one opens,
its databases (DBC or ARXML) and the ECUs simulated on it.

There are two ways to script it:

- **Python** (`pip install blobly`) puts the engine inside your own Python process: load a
  project, start its simulation, send and receive frames, encode and decode DBC signals, react
  to traffic with an event loop, inject faults into the simulated ECUs, run UDS over CAN and
  DoIP, talk SOME/IP and flash a blobly_emb bootloader. This is the primary interface, and the
  one this page uses.
  The guide is [scripting_python.md](scripting_python.md).
- **Lua** test scripts run headless (`scripts/runtests.sh`) or in the GUI's Script panel. See
  [Python or Lua](#python-or-lua).

## Install and run

```sh
pip install blobly                        # Linux x86_64 or Windows x64, CPython 3.11 or newer
git clone https://github.com/MartenH/blobly_net.git   # the example projects and scripts
cd blobly_net
python3 python/examples/raw_can.py        # runs against projects/sim-demo.blobnet
```

The wheel carries the engine and no projects, so the clone is where `projects/sim-demo.blobnet`
and the examples come from. In a checkout without the wheel, build the engine instead
(`./scripts/build_libblobly.sh build`, which needs the V toolchain that `./scripts/setup_env.sh`
installs); the examples then use the checkout's `python/blobly`.

A script loads the engine on the main thread, then brings the project up in a `with` block, which
stops it on the way out:

```python
import blobly

blobly.init()                                              # on the main thread, first
with blobly.Project("projects/sim-demo.blobnet") as net:   # loaded and started
    print(net.channels.keys())                             # ['CAN1', 'DoIP1', 'CAN2']
```

## Simulation

`projects/sim-demo.blobnet` is two in-process CAN buses (`inproc:CAN1`, `inproc:CAN2`) with
simulated ECUs on them, and a DoIP entity on loopback, so a script can be developed with no
hardware, the same on Linux and Windows:

- CAN1 carries the SUT, which sends Powertrain (0x100) and Heartbeat (0x700) every 100 ms and
  answers Request (0x101) with Response (0x102), the first byte plus one. A ChassisECU sends
  WheelSpeeds (0x300) and BrakeStatus (0x301).
- CAN2 carries BodyStatus (0x200) and BatteryStatus (0x400).
- DoIP1 is a DoIP entity serving the SUT's identity over UDS, on a loopback port of the run's own
  (`ch.iface` says which): `net.channels.DoIP1.uds()` reaches it, `discover()` asks who it is.
- No bootloader is simulated in the project; `blobly.BootSim(net.channels.CAN1)` starts one, so a
  flash (`blobly.flash.program`) can be rehearsed with no board.
- The database of both CAN buses is `dbc/blobly_net.dbc`.

To test something else in simulation, write a project whose rows use `inproc:` and whose
`simulation:` block describes the ECUs ([simulation.md](simulation.md)). One row is enough:

```yaml
project:
  name: my simulation
  version: 8
channels:
  - name: CAN1
    type: can
    interface: inproc:CAN1
    databases:
      - ../dbc/blobly_net.dbc
    simulation:
      - name: SUT
        responses:
          - { request: "0x101", response: "0x102", byte: 0, add: 1 }
```

Paths in a project are relative to the project file. Loading a project (`Project(path).load()`)
transmits nothing; starting it starts its simulated ECUs and cyclic generators.

## Find out what a project offers

Ask the project instead of assuming names, ids or interfaces:

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    for ch in net.channels:
        print(ch.name, ch.kind, ch.iface)                  # CAN1 can inproc:CAN1, ...
    can1 = net.channels.CAN1
    for msg in can1.messages:                              # the row's databases, while started
        print(msg.name, hex(msg.id), msg.dlc, "bytes")
        for sig in msg.signals:
            print("  ", sig.name, sig.unit, sig.minimum, sig.maximum, sig.labels)
```

- `ch.kind` is `"can"`, `"doip"` or `"someip"`; only a CAN row carries frames.
- `ch.iface` is what the row opens, as the run has it (a hosted DoIP entity's moved port included).
- `ch.messages` exists only while the project is started.
- Names come from `keys()`, and every collection completes with `dir()`. An unknown name raises
  `AttributeError` listing the names there are.
- `ch.decode(frame)` names the signals of any frame you receive.
- The package is typed (it ships `py.typed`), so a type checker (pyright, mypy) resolves every
  method and what it returns in a script you write. It cannot know a project's names (channels,
  messages, signals): only the running project does
  ([vscode.md](vscode.md#what-completion-knows)).

### Find out what hardware is attached

No project is needed to ask what is present, or to open a bus by its address:

```python
import blobly

for i in blobly.interfaces():                # SocketCAN links, vendor channels, software buses
    print(i.address, i.kind, i.fd, i.description)
print(blobly.vector.driver() or blobly.vector.assignments())   # Vector, Windows only
with blobly.open("inproc:PROBE") as bus:     # any address a row could name, e.g. "vcan0"
    print(bus.load())
```

- `i.address` is what `blobly.open` and a project row's `interface:` take; `i.kind` the backend
  (`"socketcan"`, `"vcan"`, `"pcan"`, `"kvaser"`, `"vector"`, `"cansub"`, `"bridge"`, `"udp"`,
  `"inproc"`); `i.fd` `True`, `False` or `None` (unknown).
- A CANsub is found by `blobly.discover_cansub(700)`, which waits its window; a Vector physical
  channel is mapped to an application channel by `blobly.vector.assign`
  ([scripting_python.md](scripting_python.md#vector-channel-assignment)).
- A bus opened by address obeys the loaded project's `listen_only` rows: nothing is transmitted on
  a wire the project silences.

### Nodes and their DIDs

A project that blobly_emb's `system.toml` describes (beside the project, beside one of its
databases, or in its folder's parent) has **nodes**, each with a diagnostic description from its
`ecu.toml`. Ask the model rather than spelling CAN ids, DID numbers or byte layouts:

```python
import blobly

with blobly.Project("projects/described-ecu-demo/described-ecu-demo.blobnet") as net:
    print(net.system, net.nodes.keys())                # .../system.toml ['zone_a']
    node = net.nodes.zone_a
    for t in node.targets:                             # where the run reaches it
        print(t.channel.name, t.tx, t.rx)              # edge 1984 1992
    for d in node.dids:                                # its DIDs, then the ISO ones it does not declare
        print(hex(d.id), d.name, d.kind, [p.hint for p in d.parts], d.write_gate)
    with node.uds() as diag:                           # the channel and ids come from the model
        print(diag.read("SteerLimit"))                 # 360: decoded by the node's layout
        try:
            diag.write("SteerLimit", 300)
        except blobly.WriteGated as e:                 # nothing sent: the gate's session and level
            print(e)
            diag.session(e.session)
            diag.security_access(2 * e.level - 1)
        diag.write("SteerLimit", 300)
        print([d.fault for d in diag.dtcs()])          # the DTCs by the description's fault names
        diag.write("SteerLimit", 360)
```

- `net.system` is `None` and `net.nodes` empty when no system.toml describes the project.
- A `Did`'s `parts` say what a value is made of and what each accepts (`hint`, `"u16 0..360"`);
  `read` returns that, and `write` takes it. `write_gate` is `None` for a DID that is not writable.
- A write the description refuses (out of range, not writable) is `Refused` and sends nothing; one
  the connection has not unlocked yet is `WriteGated` (`.session`, `.level`) and sends nothing.
  Nothing unlocks on its own: an agent decides to switch and unlock.
- A node reached on no channel of the project is refused with how it is reached; give the
  project that row.

## Bounded waits, errors and exit codes

- **Bound every wait.** `ch.recv(timeout_ms)` returns `None` when nothing came; `run(duration_ms)`
  returns after its duration. Never call `recv(None)`: on a quiet bus it waits for ever, and
  nobody presses Ctrl-C for an agent. A wait for one frame is `ch.expect(id, timeout_ms)`, and for one signal
  value `ch.expect_signal(message, signal, want, timeout_ms)`: one deadline for the whole wait,
  and `blobly.Timeout` when nothing matched, its message saying what came instead. Add `e2e=True`
  to either and a frame of the message that fails its E2E check raises `blobly.E2eError` (code
  -12, `.status` the verdict); every received frame carries that verdict as `f.e2e`.
- **A frame read is consumed.** `recv` and `expect` drop what else they read on the way.
- **Send in the background, not from a loop.** A frame the SUT must keep receiving while the
  script waits (a heartbeat, a polled request) is `ch.send_cyclic(id, data, period_ms=...)` or
  `msg.send_cyclic(period_ms, **signals)` in a `with` block; it stops at the block's end, or at
  the project's stop. A non-default UDS session is kept with `ch.uds(keep_alive_ms=2000)`; a
  keep-alive that failed is a `blobly.KeepAliveWarning` at the client's next call.
- **One run per process.** A second `start()` raises `BloblyError` with code -3. Use one
  `Project` per process, or stop the first one.
- **Errors.** The engine's refusals are `blobly.BloblyError`, its message the reason and `.code`
  the kind (-1 refused, -2 no such handle, -3 the wrong state). A listen-only row's send is one.
  A fault that could not take effect (`net.fault`) is `blobly.FaultRefused`, a `Refused`. A UDS
  call's failures are subclasses an agent can act on: `NegativeResponse` (with `.nrc`),
  `Timeout` (code -5, also an expectation that ran out), `PendingExpired`, `UndecodableAnswer`,
  `CarrierFailed` and `Refused`; on DoIP also `RoutingDenied` (with `.routing_code` and `.hint`)
  and `ConnectionLost` (a `CarrierFailed`: the next call opens a new connection); a described
  write its gate does not allow yet is `WriteGated` (code -13, a `Refused`). A SOME/IP call
  nothing answered is `Timeout`; a flash the bootloader's own answers say did not happen is
  `FlashFailed` (code -11).
  Bad arguments are `ValueError` or `TypeError`, unknown names `AttributeError` or `KeyError`.
  [scripting_python.md](scripting_python.md#17-errors) has the full table.
- **Exit codes.** Make a script exit non-zero when a check fails, with one line that says what
  was expected (`sys.exit("FAIL: ...")` exits 1). The examples exit 0 when every check held, 1
  on a failed check or an error, and 2 on a bad argument. pytest exits 0 when every test passed
  and 1 when one failed.
- **Output.** The engine prints its own lines (`project: ...`, `channel CAN1 ...`) on stdout.
  With stdout on a pipe, `sys.stdout.reconfigure(line_buffering=True)` keeps your lines in order
  with them.

## Reading a Lua run's result

`scripts/runtests.sh --report run.json --timeout 120 tests/my_suite.lua` writes the result as
JSON: `status` and `exit_code` for the verdict, then each test's `status`, `message` and
`line`, and `timeout.test` naming the test that was running when a run timed out. Read the exit
status first — 0 passed, 1 a test failed, 2 refused (fix the arguments or the project; nothing
ran), 3 a script error, 4 timeout — and the file for the detail. Always pass `--timeout`: without it a
script stuck in a loop never ends, and one waiting on a silent ECU ends only when its own waits do.
The schema is in [scripting.md](scripting.md#exit-status-and-the-run-report).

## Writing a test

Tests are pytest files on blobly's plugin. Start from
[test_sim_demo.py](../python/examples/test_sim_demo.py) and the two files beside it:
[conftest.py](../python/examples/conftest.py) loads the plugin
(`pytest_plugins = ["blobly.pytest_plugin"]`) and [pytest.ini](../python/examples/pytest.ini)
names the project. The rules are in
[Testing with pytest](scripting_python.md#15-testing-with-pytest).

- The `project` fixture is the started project, and `can1` its channel `CAN1`: a fixture per
  channel, named after it; `diag` is a UDS client on the first CAN channel, or on the one a test
  names with `@pytest.mark.parametrize("diag", ["DoIP1"], indirect=True)`. A test hears what
  arrives from its start, and its handlers and faults do not reach the next test; what it changed
  in a simulated ECU lasts until its module ends.
- A test is a few lines, and names no project (the ini file or `--blobly-project` does):

  ```python
  def test_sut_answers(can1):
      can1.send(0x101, b"\x05")
      assert can1.expect(0x102, timeout_ms=500).data[0] == 6
  ```
- Wait with `expect` and `expect_signal`, and check with plain `assert`. A failed expectation
  says what was expected and what came instead.
- Run it as `pytest tests/ --blobly-project=path/to/project.blobnet --junitxml=report.xml`. The
  exit status is 0 when every test passed and 1 when one failed, and the report carries each
  failure's message.

## Examples

Complete scripts, each bounded and with a clear exit status, in
[python/examples](../python/examples/README.md):

| example | what it shows |
|---|---|
| [raw_can.py](../python/examples/raw_can.py) | Channels with their kind and interface, receiving, a send and its answer. |
| [dbc_messages.py](../python/examples/dbc_messages.py) | Messages and signals with units, ranges and labels; encode, decode, send by signal name. |
| [event_loop.py](../python/examples/event_loop.py) | `on_message` by id and by message, `on_timer`, `on_health`, `run()`. |
| [signal_monitor.py](../python/examples/signal_monitor.py) | Decoded values of chosen messages over N seconds. |
| [background_send.py](../python/examples/background_send.py) | A message sent on a period in the background while the script waits, and a UDS session kept alive. |
| [bus_metrics.py](../python/examples/bus_metrics.py) | A channel's bus load and diagnostics counts over N seconds. |
| [uds_diag.py](../python/examples/uds_diag.py) | UDS over CAN: a session, DID reads, a negative response caught, a security unlock, DTCs with a snapshot. |
| [doip_diag.py](../python/examples/doip_diag.py) | UDS over DoIP: announcements heard, the entity discovered, a session, the VIN, DTCs, a functional request. |
| [isotp_raw.py](../python/examples/isotp_raw.py) | Raw ISO-TP with no UDS on top: a multi-frame answer, a malformed request and its bytes; a UDS client's waits read and stated. |
| [fault_injection.py](../python/examples/fault_injection.py) | Faults on simulated ECUs seen on the bus: a timed drop, a signal out of range, a refusal. |
| [e2e_check.py](../python/examples/e2e_check.py) | E2E Profile 1 as a DBC declares it: each received frame's verdict, a broken sender caught by `expect(..., e2e=True)`, a send by name stamped. |
| [flash_ecu.py](../python/examples/flash_ecu.py) | Flashing a blobly_emb bootloader with progress and a report, against a simulated one (`--board` for a real one). |
| [interfaces.py](../python/examples/interfaces.py) | No project: the interfaces present, the Vector channels, a frame exchanged on a bus opened by address. |
| [j1939_listen.py](../python/examples/j1939_listen.py) | J1939 with the script as every node: a BAM rejoined and decoded by PGN, an RTS/CTS connection followed, a dropped packet as a fault, the address directory after a contested claim. |
| [nm_monitor.py](../python/examples/nm_monitor.py) | Network management: who keeps the bus awake, who woke it, and the wait for releasing and asleep, on the NM demo's replayed recording. |
| [someip_node.py](../python/examples/someip_node.py) | SOME/IP against a static-peer node: a method called, a request with what was heard after it, the node's events. |
| [test_sim_demo.py](../python/examples/test_sim_demo.py) | A pytest suite on blobly's plugin: the `project` fixture and one per channel, `expect`, `expect_signal`, `diag` over CAN and DoIP. |

## Python or Lua

| use Python for | use Lua for |
|---|---|
| Raw CAN and CAN-FD frames, DBC messages and signals, the event loop, bus health and metrics (load, dropped and error counts), fault injection, E2E (each received frame's verdict, the declared E2E stamped on a send by name, the Profile 1 helpers); UDS over CAN and DoIP (sessions, DIDs, security access, DTCs with snapshots, functional addressing, raw requests, the waits, a node behind a DoIP gateway); raw ISO-TP; DoIP discovery; SOME/IP send, call and listen; flashing a blobly_emb bootloader; replaying a recording and recording to a file; J1939 multi-packet messages, their faults and the address directory (`ch.j1939()`); the NM reading, who keeps the bus awake and the wait for asleep (`ch.nm()`); the interfaces present, a bus by address, Vector assignment. | What #507 Phase 2 has not brought to Python yet ([What is not there yet](scripting_python.md#19-what-is-not-there-yet)). |
| Tests under pytest, and anything that needs the Python ecosystem. | A script in the GUI's Script panel, against a live measurement. |
| An agent's own process: no V toolchain, a `pip install`. | The existing Lua suites in `tests/`, run by `scripts/runtests.sh` from a checkout with the V toolchain. |

The Lua guide is [scripting.md](scripting.md).
