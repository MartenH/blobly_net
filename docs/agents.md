# Driving Blobly Net as an AI agent

This page is for an AI agent (or a person scripting one) that drives Blobly Net. It covers
installing and running it, the safety rule for real hardware, finding out what a project offers
at run time, and the habits that keep a run bounded and its result readable.

## What it is

Blobly Net is an automotive bus tester. It exercises a system under test over CAN, and over
Ethernet through DoIP and SOME/IP: it runs diagnostics, simulates ECUs, scripts tests and reads
back logs. A **project** (a `.blobnet` file) names the channels, the interface each one opens,
its databases (DBC or ARXML) and the ECUs simulated on it.

There are two ways to script it:

- **Python** (`pip install blobly`) puts the engine inside your own Python process: load a
  project, start its simulation, send and receive frames, encode and decode DBC signals, and react
  to traffic with an event loop. This is the primary interface, and the one this page uses.
  The guide is [scripting_python.md](scripting_python.md).
- **Lua** test scripts run headless (`scripts/runtests.sh`) or in the GUI's Script panel. Today
  Lua is the only way to run diagnostics. See [Python or Lua](#python-or-lua).

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

## Simulation first

Work against a simulation unless the user asks for hardware. `projects/sim-demo.blobnet` is two
in-process CAN buses (`inproc:CAN1`, `inproc:CAN2`) with simulated ECUs on them, and a DoIP
entity on loopback. No frame leaves your process, nothing listens beyond this host, and the run
is the same on Linux and Windows:

- CAN1 carries the SUT, which sends Powertrain (0x100) and Heartbeat (0x700) every 100 ms and
  answers Request (0x101) with Response (0x102), the first byte plus one. A ChassisECU sends
  WheelSpeeds (0x300) and BrakeStatus (0x301).
- CAN2 carries BodyStatus (0x200) and BatteryStatus (0x400).
- The database of both is `dbc/blobly_net.dbc`.

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

Paths in a project are relative to the project file.

## Real hardware needs the user's consent

**Never put frames on a real bus without the user's explicit consent.** A frame on a vehicle or a
bench can move an actuator, change an ECU's state or upset a test someone else is running.

- **Starting a project transmits.** From `start()` on, the simulated ECUs send on their rows and
  the cyclic generators on theirs. A generator (`senders:` of any row, a disabled one included)
  may name in its `bus:` an interface that no row configures, so the rows `net.channels` lists
  are not all a start can reach. Loading a project (`Project(path).load()`) transmits nothing:
  load it and look before you start it.
- **Only an in-process bus needs no consent.** `inproc` or `inproc:<name>` exists inside your
  process, and nothing else can see it (`inproc0` is not one: it is a SocketCAN name). Everything
  else can reach beyond it: `udp:` multicasts on the local network segment, a `vcan` interface
  can be forwarded to hardware (`cangw`, a `canbridge`), and every other CAN interface (`can0`,
  `pcan:`, `kvaser:`, `vector:`, `cansub:`, `bridge:`) is hardware. A `udp:` or `vcan` setup the
  user made for this task is theirs to approve; ask.
- **Ethernet.** A DoIP row that simulates nodes hosts an entity on its address, which announces
  itself and answers there. Only a loopback address (127.0.0.0/8, `::1`) keeps it on this host;
  a host name may resolve anywhere.
- **What exists today:** a CAN row with `listen_only: true` refuses every send on its wire, from
  Python, from the simulation and from every other sender in the process. On PCAN, Kvaser,
  Vector and CANsub the adapter is silenced too, so it does not acknowledge frames either. It
  does nothing for a DoIP or SOME/IP row: an entity hosted there still announces and answers.
  There is no transmit opt-in yet. #507 Phase 1 adds one (a runner flag or a `Project`
  argument), and until then a project transmits on every CAN row that is not listen-only.
- **What you must do:** before you start a project that can reach beyond your process, stop and
  ask the user. Name the rows, interfaces and generator targets, and say what would be sent (the
  simulated ECUs, the generators, your own frames). To only watch a real bus, use CAN rows with
  `listen_only: true`. Do not remove `listen_only` from a user's project on your own.

The check below lists what a project can reach: its enabled rows, and every `bus:` its file
names. It reads the file as text, so it may list more than a run would reach (a comment, a
generator that only fires on a key press), never less. When in doubt, ask.

```python
import ipaddress
import re

import blobly


def in_process(iface):
    """An in-process CAN bus: `inproc` or `inproc:<name>`."""
    return iface == "inproc" or iface.startswith("inproc:")


def on_loopback(iface):
    """An Ethernet row on this host's loopback: "doip:127.0.0.1:13400", "doip:[::1]:13400"."""
    host = iface.split(":", 1)[1].rsplit(":", 1)[0].strip("[]")
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False                                        # a host name may resolve anywhere


def beyond_this_process(path):
    """What starting this project could reach outside this process, as lines to show the user."""
    net = blobly.Project(path).load()                       # loading transmits nothing
    local = {ch.name for ch in net.channels if ch.kind == "can" and in_process(ch.iface)}
    reach = [f"{ch.name} ({ch.iface})" for ch in net.channels
             if not (in_process(ch.iface) if ch.kind == "can" else on_loopback(ch.iface))]
    with open(path, encoding="utf-8") as f:                 # a generator's bus: a channel or an interface
        targets = re.findall(r"\bbus:\s*[\"']?([^\s,\"'}#]+)", f.read())
    return reach + [f"a generator's bus: {t}" for t in targets if t not in local and not in_process(t)]


reach = beyond_this_process("projects/sim-demo.blobnet")
if reach:
    raise SystemExit("ask the user first: " + "; ".join(reach))
with blobly.Project("projects/sim-demo.blobnet") as net:
    print("inside this process only:", [ch.iface for ch in net.channels])
```

A row that only listens:

```yaml
project:
  name: watching the bench
  version: 8
channels:
  - name: Vehicle
    type: can
    interface: vcan0
    listen_only: true     # every send on this row is refused
```

On SocketCAN, `listen_only` refuses sends, but the controller still acknowledges frames unless
the interface itself is listen-only (`ip link set can0 type can listen-only on`).

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

## Bounded waits, errors and exit codes

- **Bound every wait.** `ch.recv(timeout_ms)` returns `None` when nothing came; `run(duration_ms)`
  returns after its duration. Never call `recv(None)`: on a quiet bus it waits for ever, and
  Ctrl-C cannot end it. A wait for one frame is a loop over `recv` with a deadline
  ([raw_can.py](../python/examples/raw_can.py) has `wait_for`). `expect` is #507 Phase 1.
- **A frame read is consumed.** A loop that waits for one id drops what else it reads.
- **One run per process.** A second `start()` raises `BloblyError` with code -3. Use one
  `Project` per process, or stop the first one.
- **Errors.** The engine's refusals are `blobly.BloblyError`, its message the reason and `.code`
  the kind (-1 refused, -2 no such handle, -3 the wrong state). A listen-only row's send is one.
  Bad arguments are `ValueError` or `TypeError`, unknown names `AttributeError` or `KeyError`.
  [scripting_python.md](scripting_python.md#10-errors) has the full table.
- **Exit codes.** Make a script exit non-zero when a check fails, with one line that says what
  was expected (`sys.exit("FAIL: ...")` exits 1). The examples exit 0 when every check held, 1
  on a failed check or an error, and 2 on a bad argument. pytest exits 0 when every test passed
  and 1 when one failed.
- **Output.** The engine prints its own lines (`project: ...`, `channel CAN1 ...`) on stdout.
  With stdout on a pipe, `sys.stdout.reconfigure(line_buffering=True)` keeps your lines in order
  with them.

## Examples

Complete scripts, each bounded and with a clear exit status, in
[python/examples](../python/examples/README.md):

| example | what it shows |
|---|---|
| [raw_can.py](../python/examples/raw_can.py) | Channels with their kind and interface, receiving, a send and its answer. |
| [dbc_messages.py](../python/examples/dbc_messages.py) | Messages and signals with units, ranges and labels; encode, decode, send by signal name. |
| [event_loop.py](../python/examples/event_loop.py) | `on_message` by id and by message, `on_timer`, `on_health`, `run()`. |
| [signal_monitor.py](../python/examples/signal_monitor.py) | Decoded values of chosen messages over N seconds. |
| [test_sim_demo.py](../python/examples/test_sim_demo.py) | A pytest suite with a module-scoped fixture that starts the project. |

## Python or Lua

| use Python for | use Lua for |
|---|---|
| Raw CAN and CAN-FD frames, DBC messages and signals, the event loop, bus health. | Diagnostics: UDS over CAN and DoIP, DTCs, security access, functional addressing. Python gets these in #507 Phase 1. |
| Tests under pytest, and anything that needs the Python ecosystem. | SOME/IP, flashing, the E2E helpers and fault injection (`sim.fault`). |
| An agent's own process: no V toolchain, a `pip install`. | A script in the GUI's Script panel, against a live measurement. |
| | The existing Lua suites in `tests/`, run by `scripts/runtests.sh` from a checkout with the V toolchain. |

The Lua guide is [scripting.md](scripting.md).
