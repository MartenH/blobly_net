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

## Bounded waits, errors and exit codes

- **Bound every wait.** `ch.recv(timeout_ms)` returns `None` when nothing came; `run(duration_ms)`
  returns after its duration. Never call `recv(None)`: on a quiet bus it waits for ever, and
  nobody presses Ctrl-C for an agent. A wait for one frame is `ch.expect(id, timeout_ms)`, and for one signal
  value `ch.expect_signal(message, signal, want, timeout_ms)`: one deadline for the whole wait,
  and `blobly.Timeout` when nothing matched, its message saying what came instead.
- **A frame read is consumed.** `recv` and `expect` drop what else they read on the way.
- **One run per process.** A second `start()` raises `BloblyError` with code -3. Use one
  `Project` per process, or stop the first one.
- **Errors.** The engine's refusals are `blobly.BloblyError`, its message the reason and `.code`
  the kind (-1 refused, -2 no such handle, -3 the wrong state). A listen-only row's send is one.
  A fault that could not take effect (`net.fault`) is `blobly.FaultRefused`, a `Refused`. A UDS
  call's failures are subclasses an agent can act on: `NegativeResponse` (with `.nrc`),
  `Timeout` (code -5, also an expectation that ran out), `PendingExpired`, `UndecodableAnswer`,
  `CarrierFailed` and `Refused`; on DoIP also `RoutingDenied` (with `.routing_code` and `.hint`)
  and `ConnectionLost` (a `CarrierFailed`: the next call opens a new connection). A SOME/IP call
  nothing answered is `Timeout`; a flash the bootloader's own answers say did not happen is
  `FlashFailed` (code -11).
  Bad arguments are `ValueError` or `TypeError`, unknown names `AttributeError` or `KeyError`.
  [scripting_python.md](scripting_python.md#16-errors) has the full table.
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
[Testing with pytest](scripting_python.md#14-testing-with-pytest).

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
| [bus_metrics.py](../python/examples/bus_metrics.py) | A channel's bus load and diagnostics counts over N seconds. |
| [uds_diag.py](../python/examples/uds_diag.py) | UDS over CAN: a session, DID reads, a negative response caught, a security unlock, DTCs with a snapshot. |
| [doip_diag.py](../python/examples/doip_diag.py) | UDS over DoIP: announcements heard, the entity discovered, a session, the VIN, DTCs, a functional request. |
| [fault_injection.py](../python/examples/fault_injection.py) | Faults on simulated ECUs seen on the bus: a timed drop, a signal out of range, a refusal. |
| [flash_ecu.py](../python/examples/flash_ecu.py) | Flashing a blobly_emb bootloader with progress and a report, against a simulated one (`--board` for a real one). |
| [someip_node.py](../python/examples/someip_node.py) | SOME/IP against a static-peer node: a method called, a request with what was heard after it, the node's events. |
| [test_sim_demo.py](../python/examples/test_sim_demo.py) | A pytest suite on blobly's plugin: the `project` fixture and one per channel, `expect`, `expect_signal`, `diag` over CAN and DoIP. |

## Python or Lua

| use Python for | use Lua for |
|---|---|
| Raw CAN and CAN-FD frames, DBC messages and signals, the event loop, bus health and metrics (load, dropped and error counts), fault injection, the E2E Profile 1 helpers; UDS over CAN and DoIP (sessions, DIDs, security access, DTCs with snapshots, functional addressing, raw requests); DoIP discovery; SOME/IP send, call and listen; flashing a blobly_emb bootloader. | What #507 Phase 2 has not brought to Python yet ([What is not there yet](scripting_python.md#18-what-is-not-there-yet)). |
| Tests under pytest, and anything that needs the Python ecosystem. | A script in the GUI's Script panel, against a live measurement. |
| An agent's own process: no V toolchain, a `pip install`. | The existing Lua suites in `tests/`, run by `scripts/runtests.sh` from a checkout with the V toolchain. |

The Lua guide is [scripting.md](scripting.md).
