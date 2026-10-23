# Scripting Blobly Net from Python

`blobly` puts the Blobly Net engine inside your own Python process. It is a ctypes package over
**libblobly**, the engine built as a shared library with a C ABI (`cmd/libblobly`, `bb.h`).
Loading a project brings up its simulated ECUs, UDS servers, generators and DoIP entities in that
process, exactly as the headless Lua runner does. Your script then sends and receives on the
project's buses directly.

**Python is the primary scripting interface** ([#507](https://github.com/MartenH/blobly_net/issues/507)).
Each capability is written once in the engine and exposed through the C ABI to Python first. Lua
([scripting.md](scripting.md)) stays for the GUI's Script panel, quick bench work and the
existing suites. [What is not there yet](#18-what-is-not-there-yet) lists what Python does not
have yet, with #507's phases.

An AI agent driving Blobly Net should start at [agents.md](agents.md). Complete, runnable
scripts are in [python/examples](../python/examples/README.md).

1. [Setting up](#1-setting-up)
2. [Running](#2-running)
3. [Projects](#3-projects)
4. [Channels and adapters](#4-channels-and-adapters)
5. [Raw frames](#5-raw-frames)
6. [DBC messages and signals](#6-dbc-messages-and-signals)
7. [The event loop](#7-the-event-loop)
8. [Health](#8-health)
9. [Fault injection and E2E](#9-fault-injection-and-e2e)
10. [UDS diagnostics](#10-uds-diagnostics)
11. [DoIP](#11-doip)
12. [SOME/IP](#12-someip)
13. [Flashing](#13-flashing)
14. [Testing with pytest](#14-testing-with-pytest)
15. [Threads](#15-threads)
16. [Errors](#16-errors)
17. [Reference](#17-reference)
18. [What is not there yet](#18-what-is-not-there-yet)

Every Python block in this guide runs as written from the root of a repository checkout:
`python/tests/test_docs.py` runs each one against sim-demo, in CI.

---

## 1. Setting up

### From PyPI

```sh
pip install blobly
```

The wheel carries the engine for its platform inside the package (`blobly/_native/`). It needs no
other package, no V toolchain and, for the software buses, no driver.

| platform | wheel |
|---|---|
| Linux x86_64 | a manylinux wheel. Its tag is the oldest glibc it runs on, taken from the newest glibc symbol the library uses (`manylinux_2_34` for 2026.10.1). |
| Windows x64 | `win_amd64`, with the MinGW runtime DLLs the engine loads and their licences. |
| macOS, Linux on ARM, 32-bit | No wheel. Build the library from a source checkout (below). Nothing here tests those platforms. |

**Python versions.** CPython **3.11 or newer** (`requires-python = ">=3.11"`). CI runs the
package's tests, every example and the pytest example under the runners' own Python (3.12 on
both today) on Linux and on Windows, from the source tree and from the installed wheel, and
under 3.11 on Linux from the source tree, which holds the floor. Newer versions are not run in
CI. Those tests (`python/tests`) are a pytest suite, so CI installs pytest (pinned) beside the
package; `blobly` itself still depends on nothing. The wheel is tagged
`py3-none-<platform>`: it holds no compiled Python code, so one wheel serves every version.
Other implementations are refused when the library loads (PyPy included). The package detaches a
thread from the engine as CPython ends the thread, and only CPython promises to do that on the
ending thread itself.

**Version.** `blobly.__version__` is the package's version, which is the release's (`v.mod`'s, in
PEP 440's spelling: `2026.10.01` installs as `2026.10.1`). `blobly.version()` is the version of
the engine it loaded. The notices of what is compiled into the engine (V's standard library, the
Boehm GC, arxmodel and flatxml) are in `blobly/_native/licenses/`.

### From a source checkout

```sh
./scripts/setup_env.sh                    # once: the pinned V toolchain and the native dependencies
./scripts/build_libblobly.sh build        # build/libblobly.so (Linux) or build/blobly.dll (Windows)
export PYTHONPATH=$PWD/python             # or put python/ on sys.path
```

The package looks for the engine in this order: `BLOBLY_LIB` if it is set, else the copy an
installed wheel carries, else beside the package, else the repository's `build/`. The examples
find the checkout's `python/blobly` on their own when no `blobly` is installed.

A wheel built from a checkout (`python3 scripts/build_wheel.py --native build/libblobly.so`)
carries v.mod's version plus a local label naming the commit (`2026.10.1+git.8027a81`), which
PyPI refuses. Only a release build (`--release`, from the tagged commit) carries the plain
version.

### Loading the engine

**Call `blobly.init()` on the main thread first.** Importing does not load the engine, and the
first call that needs it loads it. bb.h requires that load to happen on the process's main thread,
and the package refuses it anywhere else. Any later call may come from any thread (see
[Threads](#15-threads)).

---

## 2. Running

The smallest useful script sends sim-demo's request and waits, at most a second, for the answer:

```python
import blobly

blobly.init()                                                  # load the engine, on the main thread
with blobly.Project("projects/sim-demo.blobnet") as net:       # loaded and started; stopped at the end
    can1 = net.channels.CAN1
    can1.send(0x101, b"\x05")                                  # sim-demo's SUT answers with 0x102
    answer = can1.expect(0x102, timeout_ms=1000)               # every wait is bounded: blobly.Timeout after a second
    print("answer:", answer)                                   # Frame(0x102 [06])
```

The other blocks in this guide leave `blobly.init()` out: a first call made on the main thread
loads the engine too.

**The examples** in [python/examples](../python/examples/README.md) are complete scripts. Each
defaults to `projects/sim-demo.blobnet`, takes another project's path as its argument, bounds
every wait, and exits 1 with a `FAIL:` line when a check fails:

```sh
python3 python/examples/raw_can.py
python3 python/examples/event_loop.py --ms 3000
pytest python/examples/test_sim_demo.py
```

| example | what it shows |
|---|---|
| [raw_can.py](../python/examples/raw_can.py) | Channels with their kind and interface, receiving, a send and its answer. |
| [dbc_messages.py](../python/examples/dbc_messages.py) | Messages and signals with units, ranges and labels; encode, decode, send by signal name. |
| [event_loop.py](../python/examples/event_loop.py) | `on_message` by id and by message, `on_timer`, `on_health`, `run()`. |
| [signal_monitor.py](../python/examples/signal_monitor.py) | Decoded values of chosen messages over N seconds. |
| [bus_metrics.py](../python/examples/bus_metrics.py) | A channel's bus load and diagnostics counts over N seconds. |
| [test_sim_demo.py](../python/examples/test_sim_demo.py) | pytest on blobly's plugin: the `project` fixture and one per channel, `expect`, `expect_signal`. |

**What the engine prints.** The engine writes its progress and warnings (`project: ...`,
`channel CAN1 (inproc:CAN1): simulating 2 node(s) ...`) to the process's stdout and stderr, as
the headless runner does. When stdout is a pipe, Python buffers its own output and the engine's
lines come out first. `sys.stdout.reconfigure(line_buffering=True)`, or `python -u`, keeps them
in order.

**Exit status** is Python's own. An uncaught exception, `blobly.BloblyError` included, exits 1
with its traceback.

**Ctrl-C.** A call into the engine is not interrupted: the `KeyboardInterrupt` is raised when the
call returns. So the package asks for a wait in slices of at most 100 ms: `recv` (`None`
included), `expect`, `expect_signal`, `run()`, `blobly.wait_released`, a DoIP `discover` and
`blobly.doip_listen` (one exchange each, on a thread of its own that finishes it) all end within
about 100 ms of Ctrl-C. A UDS request is one call into the engine, bounded by its own timing (120 s at
most), and Ctrl-C lands when it returns. A `with` block stops the project on the way out, an
interrupt included.

---

## 3. Projects

A project is a `.blobnet` file ([project_editing.md](project_editing.md)): its channels, each
with an interface, its databases and the ECUs simulated on it.

- `blobly.Project(path)` names the file. `load()` reads it, `start()` brings it up, and `stop()`
  ends the run. `with blobly.Project(path) as net:` loads and starts it, and stops it when the
  block ends.
- **What `start()` brings up**, for every enabled row: the simulated ECUs (`simulation:`) and
  their UDS servers, the cyclic generators (`senders:` with `trigger: cyclic`; every generator is
  then the script's to drive, [Generators](#generators)), and a DoIP
  entity for a DoIP row that simulates nodes. An entity on a loopback address is moved off the
  project's port onto a free one in 30000..31999, as the headless runner moves it, and `ch.iface`
  says where. A SOME/IP row gets nothing.
- **One run per process.** A second `start()` while a run is going raises `BloblyError` with code
  -3, whichever project it is for.
- **`stop()` answers whether the process is free** for the next start: `False` when a loop
  outlived the stop's bound (a driver call that does not return). `blobly.wait_released()` waits
  for it, and a start refuses until then. The `with` block warns (`RuntimeWarning`) in that case.
- **The engine holds one loaded project.** Loading another makes the first one's channels refuse
  rather than reach whatever row now has their position. `start()` reloads its own project if
  another was loaded since. A reload keeps each `Channel` whose row is still at its position
  under its name, so a variable, a timer's closure and a handler go on working. The handlers of
  rows that went are dropped, and the reload names them in a `RuntimeWarning` (from `start()`
  too, which goes on to start).

```python
import blobly

net = blobly.Project("projects/sim-demo.blobnet").load()     # read; nothing runs yet
for ch in net.channels:
    print(ch.name, ch.kind, ch.iface)                         # the interfaces as the project says
net.start()                                                   # the simulated ECUs come up
try:
    print("DoIP1 is served at", net.channels.DoIP1.iface)     # where this run hosts the entity
finally:
    print("free for the next start:", net.stop())
```

### Generators

A started project's generators (its `senders:`, [simulation.md](simulation.md#interactive-senders)) are
`net.generators`, as Lua's `gen.*` has them: every CAN channel's, in project order, a disabled
channel's included (its generator may send on an enabled one). What a script can do with one is
what the Generators panel lets a person do.

- `net.generators["Heartbeat pulse"]` is one by name, or by `"channel/name"` (a name two
  generators answer to raises `KeyError` naming the forms that tell them apart);
  `net.generators[0]` by position, which reaches any of them.
- `g.fire(timeout_ms=5000)` sends its current frame once and returns once the bus took it. A
  cyclic one's bus is opened as the run starts, any other's at its first fire or start, which a
  first `fire` waits for; `Timeout` when the bus did not take it within `timeout_ms` (at most
  5000, from the call), saying whether the frame went out — one the generator had not taken up
  by then is never sent. A stop that overtakes it raises `BloblyError` (code -3). Ctrl-C ends
  the wait within 100 ms, and the fire then ends on its own, within its deadline.
- `g.start(cycle_ms=None)` sends it on its cycle from now (its own for `None`; refused when it
  has none), `g.stop()` ends that, and `g.cycle_ms = 50` changes the cycle from its next frame.
- `g.set(signal, value)` sends a signal at a static value from the next frame, and
  `g.source(signal, kind, **params)` on a value source: `"const"`, `"sine"`, `"sawtooth"`,
  `"counter"` or `"stepmod"`, with the parameters a project writes for it. `signal` is a `Signal`
  or its name; one the generator did not list is added.
- **What could not take effect is refused** with `blobly.GeneratorRefused`: a cycle outside 1 ..
  3600000 ms, a signal its message does not have or its payload does not hold (or any signal of a
  raw frame), a value that is
  not finite, a source that cannot be evaluated (a zero period or count), a generator with
  nothing to send on (its `note` says why), and a send its bus refused (a listen-only row).
- Edits last for the run: a new start brings the generators up as the project writes them. A
  `Generator` goes on working across a stop and start while the run has one of its name and
  channel at its position.

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    can1 = net.channels.CAN1
    hb = net.generators["Heartbeat pulse"]                 # manual: sends only when fired
    hb.set("Counter", 42)
    hb.fire()
    wake = net.generators["CAN1/Cyclic wake (0x123)"]      # cyclic, every 500 ms
    wake.cycle_ms = 100
    wake.stop()
    hb.source("Counter", "counter", start=0, modulo=16)
    hb.start(20)                                           # a manual one runs on a cycle too
    net.run(200)
    print(hb.sent, wake.running)                           # about 11, False
```

---

## 4. Channels and adapters

`net.channels` is the project's **enabled** rows, in project order:
`net.channels.CAN1`, `net.channels["CAN-1"]` for a name that is not an identifier,
`net.channels[0]` by position, iteration, `len()`, `keys()`, and `dir()` for completion in a
REPL. Two rows may share a name: that name is refused as ambiguous, and the rows are reached by
position. `on_message` and `on_health` also take a channel's name as a string.

- `ch.kind` is `"can"` (a CAN-FD row too), `"doip"` or `"someip"`. Only a CAN row carries
  frames. Sending, receiving or registering a handler on another kind raises `BloblyError`, by
  name.
- `ch.iface` is the interface the row opens, as the project composes it: with the bitrate for a
  vendor adapter (`pcan:PCAN_USBBUS1@500000`), and with the moved port for a hosted DoIP row
  while the project runs.
- **The channel's bus handle** is opened at its first use after `start()`: a send, a receive, a
  health check, or a handler registered on it. Frames that arrive before then are not kept for
  it. The handle is the one that `send`, `recv`, `health` and `run()` all use, so the script
  never hears its own sends. `close()` lets it go, and the next use opens another.

### Adapters

A channel reaches whatever its row's interface names: Python has no backend of its own and opens
exactly what the GUI and the headless runner open.

| interface (`ch.iface`) | what it is | Linux | Windows |
|---|---|---|---|
| `inproc:<name>` | A software bus inside this process. Only the project's simulated ECUs and this script are on it. | yes | yes |
| `udp` or `udp:<group>:<port>` | A software bus over UDP multicast (default `239.63.42.1:20000`), shared with other processes. It joins the group on the default interface, so other hosts on the local network segment share it too. | yes | yes |
| `vcan0`, `can0`, ... | SocketCAN: a virtual `vcan` or an adapter's kernel driver. CAN-FD needs the interface at MTU 72 (`scripts/setup_vcan.sh` brings `vcan0` and `vcan1` up that way). | yes | no: there is no SocketCAN on Windows |
| `pcan:<channel>@<rate>[/<data rate>]` | PEAK PCAN, through `PCANBasic.dll`. | no | yes |
| `kvaser:<n>@<rate>[/<data rate>]` | Kvaser, through `canlib32.dll`. | no | yes |
| `vector:<n>@<rate>[/<data rate>][,silent]` | Vector XL, through `vxlapi64.dll`. The application channel must already be assigned. | no | yes |
| `cansub:<device id>/<channel>[@<rate>[/<data rate>]]` | A CSS Electronics CANsub, over its USB network interface. | yes | yes |
| `bridge:<distribution>/<interface>` | A WSL distribution's SocketCAN interface, through `canbridge` ([wsl_bridge.md](wsl_bridge.md)). | no | yes |
| `doip:<host>:<port>`, `someip:<host>:<port>` | Ethernet rows (`kind` `"doip"` or `"someip"`). They are listed but carry no frames. | | |

A data rate in the address (`@500000/2000000`) is what opens a vendor adapter as CAN-FD. The
hardware is described in [can_hardware.md](can_hardware.md) and
[windows_can_hardware.md](windows_can_hardware.md). What is particular to Python:

- **PCAN, Kvaser and Vector are Windows only.** On Linux such an interface is taken for a
  SocketCAN name, and the open fails.
- **Vector: assign the channel first.** The XL library opens *application* channels, and Python
  has no call that maps a physical channel to one. Do it in the GUI's Discover dialog or with
  `cmd/vectorcheck`, then name the application channel in the project.
- **The vendor DLLs are the drivers' own.** The engine loads `PCANBasic.dll`, `canlib32.dll` and
  `vxlapi64.dll` by name when a channel first opens, and the wheel ships none of them. Under
  Python the "application directory" in Windows' DLL search is `python.exe`'s, not
  `blobly_net.exe`'s. Loading them from a CPython host is untested.
- **The WSL bridge starts by itself.** Opening a `bridge:` channel starts `canbridge` in the
  distribution and waits for it, up to 20 s ([The WSL bridge](#the-wsl-bridge)).
- **CANsub: name the device.** The row must carry the device id: Python cannot discover one.
- **Listen-only rows** (`listen_only: true` on a CAN row) refuse every send on their wire with
  `BloblyError`, and PCAN, Kvaser, Vector and CANsub also silence the controller, so the adapter
  does not acknowledge frames either. On SocketCAN the controller still acknowledges unless the
  interface itself is listen-only. The flag does nothing for a DoIP or SOME/IP row.
- **What CI exercises from Python is `inproc:` only.** Every other backend is the same code the
  app runs and is verified on hardware there ([windows_can_hardware.md](windows_can_hardware.md)),
  but not from a Python host.

### The WSL bridge

On Windows, `canbridge` run inside a WSL distribution carries that distribution's CAN interfaces
(`vcan0`, `vcan1`, a real `can0` behind USB/IP) to this process as `bridge:<distribution>/<interface>`
channels ([wsl_bridge.md](wsl_bridge.md)). A project row naming one starts its bridge when it
opens. `blobly.bridge` does it explicitly, as the GUI's Discover dialog does:

```python
from blobly import bridge

for distro in bridge.distributions():  # the installed WSL distributions; [] on Linux
    print(distro, bridge.state(distro))  # ('idle', ''), ('connected', ''), ('failed', why) ...
```

```python
import sys
from blobly import bridge

if sys.platform == "win32" and "Ubuntu-24.04" in bridge.distributions():
    print(bridge.start("Ubuntu-24.04"))  # ['bridge:Ubuntu-24.04/vcan0', 'bridge:Ubuntu-24.04/vcan1']
    bridge.stop("Ubuntu-24.04")
```

- **`start` waits** until the bridge has dialled in and returns its channels, or raises
  `BloblyError` with the bridge's own reason (no vcan module, WSL not in mirrored networking, a
  bridge that did not dial in within 20 s). `start(distro, wait=False)` returns once it is
  launched, and `state(distro)` follows it.
- **The wheel carries `canbridge`** (Windows), in `blobly/_native/` beside the engine, which is
  where a start looks first, then beside the executable (`blobly_net.exe`'s bundle), then on the
  distribution's PATH. `bridge.program()` says which file a start runs. It is a Linux program built
  on Ubuntu 24.04, so the distribution must be at least that new, and WSL needs
  `networkingMode=mirrored` ([wsl_bridge.md](wsl_bridge.md#requirements)).
- **`stop` ends a connected bridge** and every channel open on it. It is refused while a project
  is started, as the GUI offers Disconnect only while stopped, and for a bridge still starting.
  A bridge also exits when this process does.
- **On Linux** there are no distributions, `program()` is `None`, and `start` is refused, saying
  so: use the CAN interface directly.
- **Not verified by CI**: no runner has WSL. A start, its channels and a stop are checked by hand
  on a Windows machine with WSL ([wsl_bridge.md](wsl_bridge.md#from-python)).

---

## 5. Raw frames

- `ch.send(id, data=b"", ext=False, fd=False, brs=False)` puts one frame on the wire. `data` is
  any bytes-like value or iterable of byte values, at most 64 bytes. `ext` asks for a 29-bit id.
  `fd` and `brs` left `False` let the wire decide: a row the project declares CAN-FD frames it
  as FD. The transport refuses what no controller could send (`brs` without `fd`, an id past its
  width, such as 0x800 as an 11-bit id) and remote frames, as it refuses them for every sender in
  the app. A classic frame cannot yet be stated on a CAN-FD wire.
- `ch.recv(timeout_ms=1000)` returns the next frame another node sent, or `None` when nothing
  came within `timeout_ms`. The timeout is rounded down to whole milliseconds; `0` only looks at
  what is queued; `None` waits for ever (Ctrl-C ends it: see above).
- `ch.look()` is one look at what is already queued: `(frame or None, spent)`. `spent` says the
  look stopped at its bound with records still queued behind it, so a poller looks again at once
  rather than sleeping.
- A received **`Frame`** has `id`, `data`, `length`, `ext`, `fd`, `brs`, `rtr` and `esi`. For a
  remote frame `data` is empty and `length` is the length it asks for. Two frames are equal when
  every one of those fields is.
- It also has **`t_ms`**, when it was received: milliseconds on the host's monotonic clock, the
  clock `blobly.now_ms()` reads, with an unspecified zero, so it is compared with other frame
  times and with `now_ms()`, never read as a date. Where the backend stamps a frame (SocketCAN's
  kernel stamp at device receive; a device clock mapped onto the host's) it is that stamp, which
  our reader's delay does not move, so frames read off two wires order as the wires saw them, and
  it is the time the GUI's trace and a Lua script give the same frame. Elsewhere (`inproc:`,
  `udp:`, and the vendor adapters until they read their stamps) it is the receipt: when this
  channel's `recv` read it, so a frame left queued while the script slept carries the time it was
  read, not the time it arrived. It is not part of a frame's value: a received frame equals the
  `Frame` built from its content. `None` on a frame not received.
- `ch.expect(id, timeout_ms=1000, *, ext=None)` waits for the first frame another node sends
  with this id **and** kind, and returns it. When none came it raises `blobly.Timeout`, whose
  message says what came instead. `id` is an int with `ext` its kind (`False` or `None` for 11-bit,
  `True` for 29-bit: an 11-bit id past 0x7FF is refused, naming `ext=True`), or a `Message` of the
  channel, which carries its own. `timeout_ms` is one deadline for the whole wait, however many
  other frames arrive: a finite number of milliseconds (`None` is refused), and nothing is read
  once it has passed but the first look, so a wait of `0` reads at most one queued frame. A stop or
  a start of the project during the wait raises `BloblyError` (code -3).
- **A frame read is consumed.** `recv` takes it off the channel's handle, and so does `expect`:
  a wait for one id drops every other frame it reads on the way.

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    can1 = net.channels.CAN1
    can1.send(0x101, [0x05])
    answer = can1.expect(0x102, timeout_ms=1000)               # an 11-bit 0x102, or blobly.Timeout
    print(answer, answer.data.hex(), answer.length, answer.ext, answer.fd)
    can1.send(0x18DAF110, b"\x02\x10\x01", ext=True)          # a 29-bit id
    can1.send(0x123, bytes(range(12)), fd=True, brs=True)      # a CAN-FD frame, 12 bytes
    frame, spent = can1.look()                                 # what is queued now, no wait
    try:
        can1.expect(0x102, timeout_ms=200)                     # nobody asked again: nothing comes
    except blobly.Timeout as e:
        print(e)  # CAN1: expected a frame 0x102 within 200 ms; 19 other frames came: 9 of 0x300, ...
```

---

## 6. DBC messages and signals

`ch.messages` is the messages of the row's databases (`databases:` in the project, DBC or an
ARXML cluster), merged as the run loaded them: the same database the simulated ECUs encode by.
It exists while the project is started, and raises `BloblyError` (code -3) otherwise. It reads
like the channels: `ch.messages.Powertrain`, `["X"]`, by position, iteration, `keys()`, `dir()`.

- A **`Message`** has `name`, `id`, `ext`, `dlc`, `j1939` (whether the database declares it
  J1939), `channel` and `signals`. It belongs to the run that listed it. After a stop and a start
  it goes on working while the database still has it at its position under its name and id;
  otherwise it raises `BloblyError`.
- A **`Signal`** has `name`, `start_bit` (as the DBC numbers it), `length`, `byte_order`
  (`"little"` for Intel, `"big"` for Motorola), `signed`, `factor`, `offset`, `minimum` and
  `maximum` (both 0 where the DBC states no range), `unit`, `multiplexor`, `multiplexed` and
  `mux_value`. Its value table comes twice: `labels` as `{physical value: text}`, keyed like the
  values `decode()` returns, and `raw_labels` as `{raw key: text}`, keyed as the database keys
  it (two's complement for a signed signal). `raw_labels` has every entry; in `labels`, two keys
  a double cannot tell apart (past 2^53) are one entry.
- `msg.encode(**signals)` returns the `Frame` the message sends with the named signals at these
  physical values and every other at raw 0. A name the message does not have raises
  `BloblyError`, and a value that is not a number raises `TypeError`. The DBC's range is not
  applied, only the signal's width (a value past it is clamped to the nearer end), so a test can
  send an out-of-range value on purpose. `fd`/`brs` are left unset.
- `msg.send(**signals)` encodes and sends on the message's channel, and returns the encoded
  `Frame`.
- `ch.expect_signal(message, signal, want, timeout_ms=1000)` waits for a frame of `message`
  whose decoded `signal` matches `want`, and returns `(frame, value)`. When none came it raises
  `blobly.Timeout`, whose message says what the signal was instead. `message` is a `Message` of
  the channel or its name, and its frames are those of its id and kind (a J1939 message's frames
  from another source address are not its id). `signal` is one of that message's `Signal`s, or
  its name (a name two signals share is refused: pass the `Signal`); an unknown message or signal
  is refused before the wait. `want` is a predicate on the physical value, or a
  value compared with `==`. Decoded values are floats with the rounding of raw × factor + offset:
  on a signal of 0.1 steps, raw 3 decodes as 0.30000000000000004, so want `pytest.approx(0.3)` or
  a predicate there. The deadline and the consumed frames are `expect`'s.
- `ch.decode(frame)` returns `{signal: physical value}` for what the frame says in the row's
  databases: the message of its id and kind (else, for an extended frame, one with its J1939
  PGN), and each signal the frame carries. A multiplexed signal its multiplexor does not select is
  left out, and so is a signal whose bits a frame shorter than the message does not all hold (or
  whose multiplexor's it does not), as Lua's `decode` leaves them out. It returns `None` for a
  frame of no message, and for a remote frame. Which message a frame decoded as is not returned.

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    can1 = net.channels.CAN1
    pt = can1.messages.Powertrain
    print(pt.name, hex(pt.id), pt.dlc, pt.signals.keys())
    gear = pt.signals.Gear
    print(gear.start_bit, gear.length, gear.byte_order, gear.unit, gear.labels[3])   # 43 4 little  Third
    frame = pt.encode(EngineSpeed=1500, Gear=3)                 # Frame(0x100 [70 17 00 00 00 18 00 00])
    print(can1.decode(frame))                                   # {'EngineSpeed': 1500.0, ..., 'Gear': 3.0, ...}
    sent = can1.messages.Request.send(ReqCode=5)                # the SUT answers with Response, RespCode 6
    frame, code = can1.expect_signal("Response", "RespCode", 6, timeout_ms=1000)
    print("sent", sent, "answered", frame, code)                # ... answered Frame(0x102 [06 ...]) 6.0
    _, engaged = can1.expect_signal(pt, gear, lambda g: g >= 1, timeout_ms=1000)  # a Signal, or its name
    print("in gear", engaged)                                   # 1.0 to 6.0: sim-demo steps it each second
```

---

## 7. The event loop

Register handlers on the project, then run the loop for a while:

- `net.on_message(ch, id, fn)` calls `fn(frame)` for each frame on `ch` received during `run()`
  whose id is `id`. An int matches that id of either kind (11- or 29-bit), or of the one kind
  `ext=False` or `ext=True` names. A `Message` matches its
  id **and** kind, as they were when the handler was registered. `None` matches every frame. A
  J1939 message's frames from another source address do not carry its id; `decode()` reads those.
- `net.on_timer(period_ms, fn)` calls `fn()` every `period_ms` during `run()`, on its own grid: a
  late call does not delay the next one, and periods missed while a callback ran long are
  skipped, not made up in a burst. The period is at least 1 ms.
- `net.on_health(ch, fn)` calls `fn(state)` when the controller's fault ladder moves, and at its
  first sample with the state then (see [Health](#8-health)).
- `net.run(duration_ms=1000)` runs the loop for that many milliseconds.

It follows the Lua `run()`'s rules ([scripting.md](scripting.md)), on one thread, with no
background readers:

- **It reads every channel a handler names**, from the channel's own handle. A frame it reads is
  consumed whether or not a handler matched it, and the script's own sends are never heard.
- **A frame reaches every handler it matches**, in registration order, before the loop takes up
  the next frame. A frame read off the bus cannot be read again.
- **The deadline is per event** (a frame, a timer, one health handler): none is taken up once
  the deadline has passed. A callback that runs past it ends `run()` when it returns, and what
  arrived meanwhile stays queued for the next reader.
- **Waiting.** With one channel it blocks in the driver, at most 100 ms at a time. With several
  it looks at each in turn every 0.1 ms (1 ms on Windows).
- **Nesting.** A handler may call `send`, `recv` or `run()` itself. An inner `run()` first gives
  the frame being handled to the handlers after the current one. A timer is never called again
  inside its own callback.
- **An exception in a handler** ends that frame's dispatch and propagates out of `run()`.
- **A channel's error** is a wait with nothing in it, so a bus that fails and comes back is read
  again. One that will not clear while `run()` goes on is raised: the project stopped or
  reloaded (`BloblyError`, code -3), or an error that is not the engine's.
- **Handlers cannot be removed.** They last as long as their `Project`. Sends that go on outside
  `run()` are not built either: a periodic frame is `on_timer` plus `send`, inside `run()`, or a
  generator in the project (`senders:`).

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    can1 = net.channels.CAN1
    msgs = can1.messages
    answers = []
    net.on_message(can1, 0x102, lambda f: print("by id:", f))
    net.on_message("CAN1", msgs.Response, lambda f: answers.append(can1.decode(f)["RespCode"]))
    net.on_timer(100, lambda: msgs.Request.send(ReqCode=5))   # a request every 100 ms
    net.on_health(can1, lambda state: print("CAN1 is", state))  # a software bus never calls it
    net.run(1000)
    print(len(answers), "answers, each", set(answers))         # about 9 answers, each {6.0}
```

---

## 8. Health

`ch.health()` is the controller's fault ladder now: `"ok"`, `"error warning"`,
`"ERROR-PASSIVE"` or `"BUS-OFF"`, or `""` where the backend cannot say. Where the ladder comes
from depends on the backend:

| backend | the ladder | `on_health` reads the channel |
|---|---|---|
| `inproc:`, `udp:` | none: there is no controller, `health()` is always `""` | no, and it never fires |
| PCAN, Kvaser, CANsub, the CAN bridge | the driver is asked: current without a reader | no: the channel's frames are left for `recv` |
| SocketCAN, Vector | moves only while the channel is read | yes, and `run()` consumes its frames as for `on_message` |

On SocketCAN and Vector a channel that only sends keeps its last state, so `health()` outside
`run()` can be stale. `on_health` samples every 100 ms, so a state held for less than that can be
missed, and it never reports `""`.

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    print(repr(net.channels.CAN1.health()))   # '': inproc: is a software bus, with no controller
```

### Bus metrics

`ch.load()` is a `BusLoad`: the load of the frames this channel's handle carried since it opened,
priced at the wire's rates (those of the first enabled row on it; unset is 500 kbit/s).
`percent` is the last whole second, `average` the whole time since the handle opened (both `None`
until one second has passed), `frames` and `bits` the counts behind them. It is the GUI's bus
load, computed by the same code, with two things to know:

- **Decoded frames only.** An error frame, a retransmission and a frame lost in an overrun
  occupied the wire and are not in it, so in an error storm it under-reads; `health()` and
  `diagnostics()` are what say so. A frame costs its bit-times with worst-case stuffing.
- **Both directions, through this handle.** What the channel sends counts once the driver took
  it (the GUI counts our own frames as wire load too), and what it receives counts when it is
  READ (`recv`, `expect`, `run()`): a channel nobody reads sees only its own sends, and a frame
  left queued lands in the second it is read.

`ch.diagnostics()` is a `BusDiagnostics`: what the backend counted since the handle opened that no
frame carried. `dropped` is frames lost before delivery (this handle's queue full, a driver
overrun, a shared ring overwritten), `bus_errors` controller error records, `decode_errors`
records the backend could not decode. Counts only grow while the handle is open, and
`ch.close()` starts the load again at zero. The diagnostics count from the handle's open too,
except on a wire shared through one driver handle (PCAN, CANsub, the CAN bridge): there they are
the wire's, its other handles' ring gaps included, and start again only once the last handle on
the wire closes.

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    can2 = net.channels.CAN2
    for _ in range(100):
        can2.send(0x555, bytes(8))
    print(can2.load().frames)       # 100: this handle's own sends (135 bit-times each)
    print(can2.diagnostics())       # BusDiagnostics(dropped=0, bus_errors=0, decode_errors=0)
```

---

## 9. Fault injection and E2E

**Faults** make a running project's simulated ECUs misbehave on purpose, which is how a test
checks that the ECU under test notices: a message that stops arriving, a checksum that does not
match, a counter that stops, a signal past its declared range. They are Lua's `sim.fault`, judged
by the same rule in the engine. [simulation.md](simulation.md#fault-injection) has what each one
does on the wire and why.

- `net.fault(channel, node, message, kind, ms=None, signal=None)` arms `kind` on the simulated
  `node`'s `message` on `channel`, for `ms` milliseconds (rounded up) or, with `None`, until it is
  cleared. `channel` is a `Channel` or its name, `message` a `Message` or its name, `node` the
  simulated node's name as the project gives it. A fault is keyed by the message's **name**: by
  name it reaches every message of that name the node sends, and a `Message` whose name another
  message of its channel shares raises `ValueError` rather than reach more than the one given. `kind` is a `blobly.FaultKind` or its string:

  | `kind` | on the wire |
  |---|---|
  | `FaultKind.DROP`, `"drop"` | the message is not sent |
  | `FaultKind.BAD_CRC`, `"bad_crc"` | sent with its E2E checksum inverted |
  | `FaultKind.FREEZE_COUNTER`, `"freeze_counter"` | sent, its E2E alive counter stopped |
  | `FaultKind.OUT_OF_RANGE`, `"out_of_range"` | sent with `signal` (a `Signal` or its name) past its declared range; with `None` the engine picks a signal that can carry it |

- `net.clear_fault(channel, node, message)` lifts that message's fault; `net.clear_faults()` lifts
  every one. A start clears them too, and a fault armed with `ms` ends by itself.
- **A fault that could not take effect is refused**, with `blobly.FaultRefused` saying why: a DoIP
  or SOME/IP channel, an unknown kind, a node not simulated on that channel (a sender the DBC
  names is not enough), a message the node does not send,
  `bad_crc` where the node stamps no checksum, `freeze_counter` where it stamps no E2E counter
  (its `protect:` entry or the DBC's E2E declaration), `out_of_range` where no signal has a value
  outside its range. Armed, such a fault would change nothing, and a test of it would pass for
  the wrong reason. sim-demo protects no message, so there `bad_crc` and `freeze_counter` are
  refused. A fault needs the project started (`BloblyError`, code -3, otherwise).

```python
import time

import blobly
from blobly import FaultKind


def count(ch, frame_id, seconds):
    """How many frames of `frame_id` arrive on `ch` in the next `seconds`."""
    end, n = time.monotonic() + seconds, 0
    while (left := end - time.monotonic()) > 0:
        f = ch.recv(left * 1000)
        n += f is not None and f.id == frame_id
    return n


with blobly.Project("projects/sim-demo.blobnet") as net:
    can1 = net.channels.CAN1
    net.fault(can1, "SUT", "Powertrain", FaultKind.DROP, ms=500)   # 500 ms, then it ends by itself
    print([count(can1, 0x100, 0.25) for _ in range(4)])           # about [0, 0, 2, 3]
    brake = can1.messages.BrakeStatus
    net.fault(can1, "ChassisECU", brake, "out_of_range", signal=brake.signals.BrakePedal)
    try:
        net.fault(can1, "SUT", "Powertrain", FaultKind.BAD_CRC)
    except blobly.FaultRefused as e:
        print(e)            # "Powertrain" on "SUT" has no configured checksum — bad_crc would change nothing
    net.clear_faults()
```

**E2E Profile 1 for frames you build** is `blobly.e2e`, Lua's `e2e.p01_crc` and `e2e.p01_protect`.
The CRC is the engine's own Profile 1, the one the simulation stamps with, pinned to an
independent implementation: CRC-8 over poly 0x1D with start 0 and no final XOR, over the Data ID
bytes `mode` names and then every byte of the frame but the CRC's own.

- `e2e.p01_crc(data, data_id, crc_pos, counter_pos, mode="both")` is the CRC byte for `data` as it
  stands, the counter read from the low nibble of `counter_pos`. Compare it with the frame's CRC
  byte to check a received frame; the counter is yours to check (15 is never a Profile 1
  counter).
- `e2e.p01_protect(data, data_id, crc_pos, counter_pos, counter, mode="both")` returns `data` with
  `counter` (0..14) in the low nibble of `counter_pos` and the CRC stamped at `crc_pos`.
- Positions are 0-based bytes, as blobly_emb's `[[frame]].e2e` writes them. `mode` is the Data ID
  mode: `"both"` (low byte, then high), `"low"`, or `"alt"` (low for an even counter, high for an
  odd one). `data` is `bytes`, a `bytearray` or a list of byte values.
- A value Profile 1 cannot have raises `ValueError` with the engine's reason: a counter outside
  0..14, a `data_id` past 16 bits, an unknown mode, positions that are not two distinct bytes of
  the frame.

```python
from blobly import e2e

frame = e2e.p01_protect(bytes.fromhex("E8035A000000"), 0x1244, 4, 5, counter=3)
print(frame.hex(" ").upper())                            # E8 03 5A 00 CF 03
print(e2e.p01_crc(frame, 0x1244, 4, 5) == frame[4])      # True
```

---

## 10. UDS diagnostics

`ch.uds()` opens a UDS (ISO 14229) client on a CAN row, over ISO-TP on the row's bus, or on a
DoIP row over its connection ([DoIP](#11-doip)). It is the Lua `uds.open`: the same rule opens
both (`blobly/udsconn`), and each call is one of the engine's helpers. Answers come back decoded and failures come back typed, so a script parses no UDS
payload of its own. `with` closes the client at the end of the block.

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    with net.channels.CAN1.uds(tx=0x7E0, rx=0x7E8) as diag:  # sim-demo's SUT
        diag.session(0x01)                                    # b'\x01\x00\x32\x01\xf4'
        print(diag.read_did(0xF190))                          # b'BLOBLYNETV0SUT001', multi-frame
        print(diag.last.rtt_us, "us")                         # the timing of that exchange
        try:
            diag.read_did(0xABCD)
        except blobly.NegativeResponse as e:
            print(hex(e.nrc), e.nrc_name)                     # 0x31 requestOutOfRange
        diag.security_access(0x01)                            # seed, reference key, unlocked
        diag.write_did(0xF1AA, b"\xca\xfe")
        print(diag.raw(b"\x22\xf1\xaa"))                      # b'b\xf1\xaa\xca\xfe', SID included
```

[uds_diag.py](../python/examples/uds_diag.py) is a complete script.

**Opening a client.** `ch.uds(tx=None, rx=None)` takes the CAN ids as the Lua `uds.open` does.
`None` is the default, 0x7E0 for `tx` and 0x7E8 for `rx`; 0 is an id like any other. Either id
past 0x7FF makes both 29-bit. An id that is not a CAN identifier (a negative one, or one past 29
bits) is refused. `diag.tx`, `diag.rx` and `diag.ext` are the ids it opened on.

- **CAN and DoIP rows.** On a DoIP row the addressing is the row's, so `tx` and `rx` are refused
  there ([DoIP](#11-doip)). A SOME/IP row is not a diagnostics carrier, and is refused.
- **The project must be started.** A stop lets the client's connection go. The next call after a
  start opens another on the same ids, so a client kept in a variable goes on working. A client
  of a channel that another load did not keep refuses.
- **Threads.** Calls on one client are serialised, so threads may share one; `security_access`
  is one call, seed, key function and key together. `close()` from another thread ends a call in
  progress there within 20 ms of the wait it is in, with `BloblyError` (code -2); a frame already
  handed to the driver is written first. A client nobody closes lets its connection go once it is
  collected, at the next UDS call.

**Security access.** `security_access(level, key_fn=None)` requests the seed for `level` (odd),
computes the key with `key_fn(seed)` and sends it at `level + 1`. Without `key_fn` the key is
blobly_net's reference key, `blobly.reference_key(seed)` (each byte XOR 0xFF), which the simulated
ECUs accept ([security_access.md](security_access.md)). An all-zero seed is ISO 14229-1's "already
unlocked", and no key is sent for it. A wrong key raises `NegativeResponse` (NRC 0x35).

**DTCs.** The fault memory reads as a model: no 0x19 payload is parsed in Python. Each `Dtc` has
its `code`, its display `name` (`P1234-56`), its `status` byte and `bits`, each ISO 14229-1 status
bit the ECU reports, by name (`testFailed`, `confirmedDTC`, ...). A bit outside the ECU's
availability mask is left out, since the ECU says nothing about it: `d.bits.get("pendingDTC")` is
`None` for a bit the ECU does not report. A DTC is given to `snapshot`
and `extended` by its code or its name. A snapshot DID's size, which the answer does not carry, is
learned by reading the DID once (0x22); `did_size` states one that cannot be read.

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    with net.channels.CAN2.uds() as diag:       # CAN2's built-in server stores a snapshot
        for d in diag.supported_dtcs():         # 0x19 0A
            print(d.name, hex(d.status), d.bits["confirmedDTC"])   # P1234-56 0x9 True, ...
        print(diag.dtc_count(0x01))             # 0x19 01: 1 has testFailed
        for s in diag.snapshot_ids():           # 0x19 03: P1234-56, record 1
            print(diag.snapshot(s.code, s.record).records[0].dids)  # {0xF195: b'\x01\x00', ...}
        e = diag.extended("P1234-56")           # 0x19 06
        print(e.occurrence, e.aging, e.failed_cycles)   # 3 0 1
```

**Functional addressing.** `ch.uds_functional(functional_id, clients, request)` sends `request`
once, a Single Frame (7 bytes at most) on the functional id, and each client answers on its own
response id, a multi-frame answer included. It returns a `FunctionalReply` per client, in their
order: `outcome` is `"positive"`, `"negative"`, `"silent"` (nothing within the window, which is
normal for a functional request: ISO 14229-1 has a server not refuse one with 0x11, 0x12, 0x31,
0x7E or 0x7F), `"pending"` (responsePending, then nothing within its P2*) or `"failed"`.

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    can1 = net.channels.CAN1
    with can1.uds(tx=0x7E0, rx=0x7E8) as sut, can1.uds(tx=0x7E1, rx=0x7E9) as chassis:
        for r in can1.uds_functional(0x7DF, [sut, chassis], b"\x22\xf1\x90"):
            print(r.outcome, r.answer[3:])      # positive b'BLOBLYNETV0SUT001', then the chassis's
```

**Waits.** Every call is bounded by the engine's timing (`blobly/uds`). The first answer is waited
for 1000 ms, which a 0x10 answer's P2 can lengthen and never shorten. Each responsePending (0x78)
is then waited for the ECU's P2* plus 1000 ms. One request never takes more than 120 s from its
send, however often the ECU says pending. An answer that names another request (a late or
repeated one, which a real bus can deliver) is skipped and the wait goes on. What is already
queued when a request goes out is drained first, so it cannot be taken for the answer.

**What went wrong.** A failed call raises one of these, each a `BloblyError` with the engine's
message and its code:

| exception | when |
|---|---|
| `blobly.NegativeResponse` | The ECU answered with a negative response. `e.nrc` is its code, `e.nrc_name` ISO 14229-1's name for it, `e.exchange` the `Exchange` it ended. |
| `blobly.Timeout` | Nothing answered within the wait. |
| `blobly.PendingExpired` | The ECU said responsePending (0x78), then nothing more within its P2*. |
| `blobly.UndecodableAnswer` | An answer arrived that cannot be read as one (too short, a DTC list that is not whole records, a negative response that is not `7F <sid> <nrc>`, a snapshot DID whose size cannot be learned). The ECU answered, so the connection is not at fault. |
| `blobly.CarrierFailed` | The carrier failed under the request: the bus (a failed write), or the ISO-TP channel (a frame lost mid-transfer). On DoIP: a negative acknowledgement, or a connection that could not be opened; `blobly.ConnectionLost`, its subclass, is the connection gone ([DoIP](#11-doip)). |
| `blobly.RoutingDenied` | DoIP only, when the client opens: the entity denied the routing activation ([DoIP](#11-doip)). |
| `blobly.Refused` | The request did not go out whole, so the ECU was not asked: an argument out of range (a byte, a DID, a 24-bit group), a sub-function with the suppress bit (0x80) given to a call that waits for its answer (that is `raw_suppressed`), an even level to `security_access`, a request longer than ISO-TP carries (4095 bytes), a listen-only row. |

`diag.last` is the last exchange, whichever call made it and however it ended: the request as it
went out, the answer, the NRC, whether it went out whole, and its timing.

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    with net.channels.CAN1.uds(tx=0x6F0, rx=0x6F8) as nobody:   # nothing answers there
        try:
            nobody.tester_present()
        except blobly.Timeout as e:
            print(e)                                            # UDS: no answer to 0x3E (timeout)
        print(nobody.last.sent, nobody.last.answer)             # True b''
```

---

## 11. DoIP

A DoIP row (ISO 13400) is diagnostics over Ethernet: no frames, but a TCP connection to an entity
at a logical address. `ch.uds()` on it opens the same `UdsClient` over that connection, routing
activation included, so every call of [UDS diagnostics](#10-uds-diagnostics) works unchanged,
with the same waits and errors. `ch.discover()` asks the entity who it is, and
`blobly.doip_listen()` hears the announcements entities send unasked. They are the Lua
`uds.open`, `doip.discover` and `doip.listen`, by the same rules (`blobly/udsconn`).

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    doip1 = net.channels.DoIP1                   # an entity this process hosts
    print(doip1.iface)                           # doip:127.0.0.1:30042, the run's own port
    print(doip1.discover())                      # DoipAnnouncement(vin='BLOBLYNETV0SUT001', ...)
    with doip1.uds() as diag:                    # TCP, then routing activation
        print(hex(diag.tester), hex(diag.ecu))   # 0xe80 0x1000, the row's addresses
        print(diag.read_did(0xF190))             # b'BLOBLYNETV0SUT001'
        print([d.name for d in diag.supported_dtcs()])   # ['P1234-56', 'B2BCD-EF']
        reply, = doip1.uds_functional(None, [diag], b"\x22\xf1\x90")   # to 0xE400
        print(reply.outcome, reply.answer[3:])   # positive b'BLOBLYNETV0SUT001'
```

[doip_diag.py](../python/examples/doip_diag.py) is a complete script.

**Opening a client.** The connection goes from the row's `tester_address` to its `ecu_address`,
`diag.tester` and `diag.ecu`; `tx` and `rx` are refused there, and `diag.tx` / `diag.rx` are
`None`. The open is bounded: the TCP connect and the routing activation within 7 s in all, the
activation answer within 2 s of the connect. A row's entity that this process hosts runs on a port of its own for the run, which
`ch.iface` shows after `start()`. Like any channel open, the open holds the project's state while
it runs, so on an entity that does not answer, other threads' calls wait for its bound. One client
at a time holds a row's connection: an entity takes
one tester address on one connection (ISO 13400-2), so a second `ch.uds()` is refused while the
first is open. Close it, or share it. Between calls the library answers the entity's alive checks
on the connection (ISO 13400-2), so an idle client keeps it. A connection that goes while idle is
the next call's `ConnectionLost`, its `exchange` `None` since that request never went out, and a
0x27 key is sent only on the connection that gave its level's seed: across a reconnect, or a
stop and start, it is refused.

**What goes wrong on DoIP**, besides what any UDS call raises:

| exception | when |
|---|---|
| `blobly.RoutingDenied` | The entity denied the routing activation as the client opened (or opened again after a lost connection). `e.routing_code` is the response code, `e.routing_name` ISO 13400-2's meaning, `e.hint` what to do about it (`""` where there is nothing to add), `e.tester` the tester address it was asked for. Code -9. |
| `blobly.ConnectionLost` | The connection is gone: the entity closed it, it was reset, a message stalled halfway, or a write did not go out within 2 s. A `CarrierFailed`, code -10; `e.exchange` is the `Exchange` it ended (its `sent` says whether the request went out whole). The client's next call opens a new one, which a `close()` from another thread ends like a call: routing activation again, with the session and security state of the old one gone. |
| `blobly.CarrierFailed` | A connection that could not be opened (nothing listens, no routing activation answer), or a negative acknowledgement of a request (an unknown target address). |

**Functional addressing.** `ch.uds_functional(address, [diag], request)` sends `request` to the
functional logical address (`None` is 0xE400) on the client's connection, and the entity answers
from its own address. One connection reaches one entity, so it takes the row's one client and
returns one `FunctionalReply`. An address the entity does not answer is negatively acknowledged:
an outcome of `"failed"`, with the reason in `r.error`.

**Discovery.** `ch.discover(timeout_ms=1200)` sends a vehicle identification request to the row's
entity and returns its answer, a `DoipAnnouncement`: `vin` (`None` when it has none), its
`logical_address`, `eid` and `gid` (6 bytes each), and `source`, the `"host:port"` it came from.
What an entity announces need not be what it serves at DID 0xF190, so a test can read both.
`Timeout` when nothing answered.

`blobly.doip_listen(window_ms=1000, *, port=None, ip6=False, channel=None)` hears the
announcements entities send unasked, for `window_ms`, in the order heard. That is how a tester
finds ECUs it was never told about. Nothing is queued for a listener that is not there, and an
entity announces as it comes up (three times, 500 ms apart, by default): listen right after
`start()`. `channel` listens on the port a DoIP row's entity is on, over IPv6 when its address is
IPv6; a `port` that contradicts it is refused. Without `channel`, `port` defaults to 13400.

```python
import blobly

with blobly.Project("projects/doip-announce-demo.blobnet") as net:   # Talker announces for 4 s
    for a in blobly.doip_listen(1200, channel=net.channels.Talker):
        print(a.vin, hex(a.logical_address), a.source)   # ANNOUNCERVIN00001 0x1000 127.0.0.1:30001
```

`discover` and `doip_listen` with `channel` need the project started: a hosted entity's row names
its run's port only then. IPv4 is the verified path; [doip.md](doip.md) has the IPv6 caveat.

**In pytest**, the `diag` fixture is a DoIP client when a test names the row by parametrizing it,
`@pytest.mark.parametrize("diag", ["DoIP1"], indirect=True)`; with `["CAN1", "DoIP1"]` the test
runs over both carriers, as `test_the_sut_reports_its_vin` in
[test_sim_demo.py](../python/examples/test_sim_demo.py) does.

---

## 12. SOME/IP

`blobly.someip` is the Lua `someip.send`, `someip.call` and `someip.listen`, by the same rules
(`blobly/someip`): messages sent from a local port and what that port heard back, one request
answered, and what a port already carries. None of them needs a project, and none needs a
SOME/IP row: a destination is an IPv4 `"host:port"`. A message is a `SomeipMessage`, its header's
fields and the payload, raw bytes (the layout belongs to the deployment, not to the tester).

```python
from blobly import SomeipMessage, Timeout, someip

try:   # blobly_emb's examples/host_someip: the node on 30490, its peer port 30491
    answer = someip.call("127.0.0.1:30490", SomeipMessage(0x0100, 0x0001, b"\x01"), timeout_ms=300)
    print(answer.type, answer.return_code, answer.payload)   # response 0 b'...'
except Timeout:
    print("no node on 127.0.0.1:30490")                       # what this prints with none running
heard, malformed = someip.listen(300, port=30491)             # what the node publishes to its peer
print(len(heard), malformed)
```

[someip_node.py](../python/examples/someip_node.py) is a complete script.

**Sending.** A blobly_emb node accepts datagrams only from its configured peer endpoint and
answers that endpoint, so `send` and `call` go out FROM a local `port` (`None`: 30491) and hear
the answers on that same socket. Give `service`, `method` and `payload`; a field left `None` takes
its default: `type` a notification for an event id (bit 15 of `method`) and a request otherwise,
`iface` 1, `client` 0x1234 for a request (the node refuses client 0) and 0 for a notification,
`session` the run's next for a request. A request's session goes out once per run, given or not,
so a late reply to one request can never complete another; a session already sent is refused.
Only requests and notifications are sent.

**`someip.call(to, request, *, port=None, timeout_ms=1000)`** returns the RESPONSE or ERROR
mirroring the request's Request ID as soon as it arrives from `to` (`timeout_ms` at least 1), a
`SomeipMessage`: an ERROR is
an answer, with `type` `"error"` and its `return_code`. Events, other senders and stale replies to
an earlier session are skipped. `Timeout` when nothing answered; `Refused` for an event id, client
0 or another type.

**`someip.send(to, msgs, *, port=None, window_ms=1000)`** sends one message or a list of them,
then returns what the port heard for `window_ms`, a `SomeipHeard`: `messages` in the order heard
(a datagram packing several gives each) and how many datagrams were `malformed`, not SOME/IP to
their end. It unpacks as `messages, malformed`.

**`someip.listen(window_ms=1000, *, port=None, group=None, channel=None)`** hears what the
network already carries on `port` (`None`: 30490): a node's events to its peer (listen on the peer
port), a service's events on a multicast `group`, SD offers (join the SD group). Nothing is sent
and nothing is subscribed to, so an event a service sends only to subscribers is not heard
([ethernet_architecture.md](ethernet_architecture.md)). `channel`, a SOME/IP row of the started
project, listens on its bind host, port and group; a `port` or `group` contradicting it is
refused.

A port another listener of this process holds is refused, whichever call holds it: two sockets
on one UDP port split its stream rather than share it. Every wait is its window or timeout, and
Ctrl-C ends it within 100 ms (the exchange then finishes on its own).

---

## 13. Flashing

`blobly.flash.program` is the Lua `flash.program`: the download session against a blobly_emb
bootloader (0x10 02, 0x29 authentication, erase, 0x34 / 0x36 / 0x37, the check routine, 0x11),
the session `cmd/flash` and the GUI's Flash panel run (`blobly/flash`). `flash.BootSim` is a
simulated bootloader, to rehearse a flash with no board.

```python
import blobly
from blobly import flash

with blobly.Project("projects/sim-demo.blobnet") as net:
    can1 = net.channels.CAN1
    with flash.BootSim(can1) as boot:        # stands in for the board; drop it for a real one
        report = flash.program(can1, bytes(4096), progress=lambda done, total: None, quiet=True)
    print(report)                 # FlashReport(bytes=4160, blocks=65, ..., auth='authenticated', ...)
    print(boot.report.verified)   # True: the CRC the image header states matched
```

[flash_ecu.py](../python/examples/flash_ecu.py) is a complete script.

**`flash.program(target, image, *, base=None, sw_version=None, auth=True, seed=None,
seed_file=None, progress=None, quiet=False, tx=None, rx=None)`** returns a `FlashReport`.
`target` is a `Channel` of the started project, opened on `tx` / `rx` (`None`: 0x7B0 / 0x7B8, as
`cmd/flash`) and closed after, or a `UdsClient` — its ids, and the connection a handoff to the
bootloader was made on (`tx` and `rx` are refused then). `image` is `bytes`, or the path of a raw
`.bin`, which gets its header here, or of a BLBT `.img`, sent as it is. `base` is where it goes
(0x08020000, the app slot), `sw_version` a raw image's header version (1).

With `auth` the session signs the bootloader's 0x29 challenge with the tester seed: `seed` (64
hex characters), else the file `seed_file` names, else `$BLOBLY_FLASH_SEED`, else the dev tester
seed. Both, a malformed seed, or a seed with `auth=False`, are refused before anything is sent.
`progress(done, total)`, in blocks, is called at each whole percent and the last block, on the
calling thread, while the flash holds the engine: it may print or record, and a call into blobly
from it is refused (`BloblyError`, code -3). Without it a `flash: transfer ...` line is printed per tenth. Each milestone
prints a `flash: ...` line; `quiet` prints none.

**What goes wrong.** A step the bootloader refused raises `NegativeResponse` with its NRC (a wrong
key is 0x35 at `send proof`, and nothing is erased); one it did not answer `Timeout`.
`blobly.FlashFailed` (code -11) is the session's own verdict: an erase or check routine that
failed (the image is not marked valid), a malformed download answer. A `progress` that raises
stops the transfer before the check, so the image is never marked valid, and its exception is
raised; Ctrl-C does the same within 100 ms once the session runs (opening a `Channel`'s connection
first is bounded as `ch.uds()`'s open is). The client is usable again after either.

**`flash.BootSim(channel, tx=None, rx=None)`** serves a CAN row of the started project as a
blobly_emb bootloader, hearing requests on `tx` and answering on `rx` (the tester's ids, 0x7B0 /
0x7B8 by default), by the rules of blobly_emb's `boot/prog.v`: 0x29, erase and download only in
the programming session, a session change or a reset relocking it, the 0x29 proof verified
against the dev tester key, a download only after an erase and its blocks in sequence, and the
check routine passing only for a valid BLBT header and the body CRC it states. `boot.stop()` (or the end of its `with` block) stops it and
returns a `BootReport`, kept as `boot.report`. Stop it before the project.

---

## 14. Testing with pytest

Tests run on [pytest](https://docs.pytest.org/): plain `assert`, fixtures and pytest's own
reports. `blobly` brings a pytest plugin, `blobly.pytest_plugin`, whose fixtures start the
project, and the channels' `expect` and `expect_signal` do the waiting. There is no copy of the
Lua prelude's `test` and `check.*`. pytest is not a dependency of `blobly`: install it yourself
(`pip install pytest`, 7.0 or newer).

**A suite asks for the plugin** in its root `conftest.py`:

```python
pytest_plugins = ["blobly.pytest_plugin"]
```

and names its project in its ini file (`pytest.ini`, or `[tool.pytest.ini_options]` in
`pyproject.toml`), relative to that file:

```ini
[pytest]
blobly_project = projects/sim-demo.blobnet
```

`pytest -p blobly.pytest_plugin`, or `addopts = -p blobly.pytest_plugin` in the ini file, loads
it too. The plugin is never loaded on its own (it registers no pytest entry point): an installed
`blobly` adds nothing to a suite that has not asked for it, and a source checkout, which has no
entry points, loads it the same way an installed package does.

`--blobly-project=PATH` on the command line, relative to the working directory, overrides the ini
value. Write it with `=`: pytest reads a separate `PATH` as a test path before the plugin has
added the option.

| fixture | what |
|---|---|
| `project` | The started `blobly.Project`. Its run is the test module's: started at the module's first test that asks for it and stopped after the module's last test, so a module may also bring up a project of its own. Each test starts with the CAN channels' handles opened fresh as its setup ends: it hears every frame that arrives from then on, one that comes before its first `expect` included, and nothing an earlier test left queued. After each test, the handlers it registered are dropped and the faults it armed cleared. A test that stopped the run finds it started again in the next one. |
| `can1`, `can2`, ... | One per enabled channel of the project, named after it: the started project's `Channel` of that name. |
| `diag` | A `UdsClient`, closed after the test: on the project's first enabled CAN channel at the default ids (0x7E0 out, 0x7E8 back), else its first DoIP one, or on the channel a test names with `@pytest.mark.parametrize("diag", ["DoIP1"], indirect=True)` ([DoIP](#11-doip)). Other ids are `can2.uds(tx, rx)` in the test. |

**The channel fixtures' names** are the channels' names lowercased, every character that cannot be
in a Python name made `_`, and `_` put before a leading digit: `CAN1` is `can1`, `CAN-1` is `can_1`,
`2nd bus` is `_2nd_bus`. They are read from the project, loaded but not started, as pytest
configures. A name two channels come to, a Python keyword, or another fixture's (the plugin's,
pytest's own such as `tmp_path`, another plugin's) gets no fixture, and pytest warns at its start which channels those are; a test reaches them as
`project.channels[...]`. A fixture of the same name in a suite's conftest.py is the suite's.

What a test changes in the simulated ECUs (a UDS session, cleared DTCs) lasts until its module's
run ends. A test file:

```python
def test_the_sut_answers(can1):
    can1.send(0x101, b"\x05")
    assert can1.expect(0x102, timeout_ms=500).data[0] == 6


def test_the_answer_decodes(can1):
    can1.messages.Request.send(ReqCode=5)
    can1.expect_signal("Response", "RespCode", 6, timeout_ms=500)


def test_the_vin(diag):
    assert diag.read_did(0xF190) == b"BLOBLYNETV0SUT001"
```

**A failed expectation** is a test failure. Its message says what was expected and what came
instead, and the traceback ends at the test's own line:

```text
    def test_late(can1):
        can1.send(0x101, b"\x05")
>       can1.expect(0x555, timeout_ms=300)
E       blobly._lib.Timeout: CAN1: expected a frame 0x555 within 300 ms; 29 other frames came: 16 of 0x300, 6 of 0x301, 3 of 0x100, 3 of 0x700, 1 of 0x102
```

**Reports** are pytest's own. `--junitxml=report.xml` writes the JUnit XML a CI server reads,
each failure with the same message; `-x`, `-k`, `-q` and the rest work as usual. The exit
status is pytest's: 0 when every test passed, 1 when one failed.

The complete suite is [test_sim_demo.py](../python/examples/test_sim_demo.py), with its
[conftest.py](../python/examples/conftest.py) and [pytest.ini](../python/examples/pytest.ini).

---

## 15. Threads

- **Load the engine on the main thread** (`blobly.init()`). After that any thread may call in. A
  thread is attached to the engine on its first call and detached when it ends, without you
  doing anything.
- **Loading, starting and stopping, and opening or closing a channel, are serialised** by the
  package, so threads may share a project.
- **Use a channel from one thread at a time.** Some drivers forbid two threads on one handle
  (Kvaser's canlib), and others keep state that a receive updates and a send or a health check
  reads (SocketCAN). Give each thread its own channel. A Python `Channel` is one handle.
- **`run()` runs on the thread that calls it**, and its handlers run there too.

```python
import threading
import time

import blobly


def frames_in(ch, seconds):
    """How many frames `ch` received in `seconds`."""
    end, n = time.monotonic() + seconds, 0
    while time.monotonic() < end:
        n += ch.recv(100) is not None
    return n


with blobly.Project("projects/sim-demo.blobnet") as net:
    counts = {}
    worker = threading.Thread(target=lambda: counts.update(CAN2=frames_in(net.channels.CAN2, 1.0)))
    worker.start()                                 # CAN2 is the worker's; CAN1 stays the main thread's
    counts["CAN1"] = frames_in(net.channels.CAN1, 1.0)
    worker.join()
    print(counts)                                  # about {'CAN1': 92, 'CAN2': 7}
```

---

## 16. Errors

| exception | when |
|---|---|
| `blobly.BloblyError` | The engine refused, or a call failed (its subclasses say how: `Refused`, `FaultRefused`, and the ways a UDS call fails): a project that does not load, a channel that will not open, a send the transport refuses, a listen-only row, a channel of an earlier load, an ambiguous name, an unknown signal in `encode`. Also: no engine found, a first load off the main thread, a Python that is not CPython. `str(e)` is the engine's message; `e.code` says which kind. |
| `blobly.FaultRefused` | A `Refused` (code -1): the engine refused a fault that could not take effect, and armed nothing (see [Fault injection and E2E](#9-fault-injection-and-e2e)). |
| `blobly.GeneratorRefused` | A `Refused` (code -1): the engine refused a generator call that could not take effect (see [Generators](#generators)). |
| `blobly.Timeout` | Nothing came within the wait: an `expect` or `expect_signal` saw no match (the message says what was expected and what came instead), a UDS request or a SOME/IP call nothing answered. A `BloblyError`, code -5. |
| `blobly.FlashFailed` | A flash's own verdict: the bootloader's answers say the flash did not happen (see [Flashing](#13-flashing)). A `BloblyError`, code -11. |
| `ValueError` | An argument no CAN frame or wait can have: an id that is not an integer of at most 29 bits, more than 64 bytes of data, a NUL in a path or signal name, a timeout past 2^31 - 1 ms, a timer period that is not a number of at least 1 ms, a `run()` duration that is not a finite number, zero or more. A fault's `ms` that is not more than 0 (or past 2^31 - 1), a fault's `Message` of another channel or of a name its channel shares. An `on_message` id past the width its `ext` names (29 bits when `None`). What Profile 1 cannot be, in `blobly.e2e`, with the engine's reason. A SOME/IP header field past its width, a nonzero `return_code` or a payload past one datagram on a message sent, a call's timeout under 1 ms. A flash's `base` past 32 bits, a NUL in its `seed_file`, an image past 2 GiB. |
| `TypeError` | A timeout that is not a finite number (or `None`, which `expect` refuses too), a signal value that is not a number, an `on_message` id that is not an int, `None` or a `Message`, or an `ext` that is not a bool or is given beside a `Message` or `None`. A fault's or an `e2e` call's argument of the wrong type. |
| `AttributeError` | An unknown name as an attribute: `net.channels.NOPE`, `msgs.NOPE`, `signals.NOPE`. The message lists the names there are; `hasattr` and `getattr(c, name, default)` read it as absent. |
| `KeyError`, `IndexError` | An unknown name by `["NOPE"]`, a position past the end. |
| `RuntimeWarning` (a warning) | A `with` block's stop found a loop that outlived the stop's bound. A reload (`load()`, or `start()` reloading) dropped the handlers of rows that went, named in it. |

`BloblyError.code` is bb.h's:

| code | meaning |
|---|---|
| -1 | refused, with the reason in the message |
| -2 | no such bus handle, or a closed one |
| -3 | the wrong state: nothing loaded, not started, already started, a previous run still releasing, a channel or message of an earlier load or run |
| -5 | `blobly.Timeout`: nothing came within the wait |

A UDS call's failures are subclasses, each with a code of its own: see
[UDS diagnostics](#10-uds-diagnostics).

| code | exception | meaning |
|---|---|---|
| -1 | `blobly.Refused` | refused (every `BloblyError` with code -1 is one) |
| -4 | `blobly.NegativeResponse` | the ECU answered with a negative response |
| -5 | `blobly.Timeout` | nothing came within the wait: no UDS answer, or no match for an expectation |
| -6 | `blobly.PendingExpired` | responsePending (0x78), then nothing within the ECU's P2* |
| -7 | `blobly.UndecodableAnswer` | an answer arrived that cannot be read as one |
| -8 | `blobly.CarrierFailed` | the carrier failed under the request |
| -9 | `blobly.RoutingDenied` | a DoIP entity denied the routing activation |
| -10 | `blobly.ConnectionLost` | the DoIP connection is gone (a `CarrierFailed`) |
| -11 | `blobly.FlashFailed` | a flash ran, and the bootloader's answers say it did not happen |

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:
    try:
        net.channels.CAN1.send(0x800, b"")     # 0x800 does not fit an 11-bit id
    except blobly.BloblyError as e:
        print("refused:", e, "code", e.code)   # ... does not fit a 11-bit identifier, code -1
    try:
        blobly.Project("projects/sim-demo.blobnet").start()
    except blobly.BloblyError as e:
        print("one run per process, code", e.code)   # -3
```

---

## 17. Reference

Import everything from `blobly`, and the E2E helpers, SOME/IP, flashing and the WSL bridge from
`blobly.e2e`, `blobly.someip`, `blobly.flash` and `blobly.bridge`. The submodules
`blobly.project`, `blobly.events` and `blobly.faults` are the implementation, and their other
names are not part of the interface.
`python/tests/test_docs.py` checks that every public class, method, property and attribute of
the package is named in this section.

### Module `blobly`

| name | what |
|---|---|
| `blobly.init()` | Loads the engine. Call it on the main thread before any other thread calls in. |
| `blobly.version()` | The engine's version, v.mod's spelling (`"2026.10.01"`). |
| `blobly.now_ms()` | The host's monotonic clock in ms (a float): the clock of a received frame's `t_ms`, so `f.t_ms - sent_at` is a latency (on a wire that stamps frames, or one read while the answer arrives). |
| `blobly.wait_released(timeout_ms=None)` | Waits until the process is free for a start: `True`, or `False` once `timeout_ms` passed (`None` waits for ever). Ctrl-C ends the wait within 100 ms. |
| `blobly.reference_key(seed)` | blobly_net's reference key for a 0x27 seed (each byte XOR 0xFF), the key the simulated ECUs accept. |
| `blobly.doip_listen(window_ms=1000, *, port=None, ip6=False, channel=None)` | The DoIP announcements heard for `window_ms`, each a `DoipAnnouncement`: on `port` (13400), or on the port of DoIP `channel`'s entity. |
| `blobly.__version__` | The package's version (`"2026.10.1"`); `"0+source"` in a source checkout. |
| `blobly.e2e` | The E2E Profile 1 helpers: see Module `blobly.e2e`. |
| `blobly.someip` | SOME/IP send, call and listen: see Module `blobly.someip`. |
| `blobly.flash` | Flashing a blobly_emb bootloader: see Module `blobly.flash`. |
| `blobly.bridge` | The CAN bridge into WSL: see Module `blobly.bridge`. |

### Module `blobly.e2e`

| name | what |
|---|---|
| `blobly.e2e.p01_crc(data, data_id, crc_pos, counter_pos, mode="both")` | The Profile 1 CRC byte for `data` as it stands, an `int`. |
| `blobly.e2e.p01_protect(data, data_id, crc_pos, counter_pos, counter, mode="both")` | `data` with `counter` (0..14) written and the CRC stamped, as `bytes`; the input is not changed. |

### Module `blobly.someip`

| name | what |
|---|---|
| `blobly.someip.call(to, request, *, port=None, timeout_ms=1000)` | One request from local `port` (30491) to `to`, an IPv4 `"host:port"`: the RESPONSE or ERROR mirroring it, a `SomeipMessage`. `Timeout` when none came. |
| `blobly.someip.send(to, msgs, *, port=None, window_ms=1000)` | One `SomeipMessage` or a list sent from local `port` (30491); what the port heard for `window_ms` after, a `SomeipHeard`. |
| `blobly.someip.listen(window_ms=1000, *, port=None, group=None, channel=None)` | What `port` (30490) heard for `window_ms`, joining `group`, or on SOME/IP `channel`'s endpoint: a `SomeipHeard`. |

### Module `blobly.flash`

| name | what |
|---|---|
| `blobly.flash.program(target, image, *, base=None, sw_version=None, auth=True, seed=None, seed_file=None, progress=None, quiet=False, tx=None, rx=None)` | Flashes `image` into a blobly_emb bootloader on `target`, a `Channel` (0x7B0 / 0x7B8) or a `UdsClient`: a `FlashReport`. |
| `blobly.flash.BootSim`, `blobly.flash.FlashReport`, `blobly.flash.BootReport` | The same classes as `blobly.BootSim`, `blobly.FlashReport` and `blobly.BootReport`. |

### `SomeipMessage`

`blobly.SomeipMessage(service, method, payload=b"", type=None, iface=None, client=None,
session=None, return_code=0, at_ms=None, source=None, protocol=None)`: a SOME/IP message, its header's fields and
its payload. A value: frozen, compared field by field.

| member | what |
|---|---|
| `m.service`, `m.method` | The service id, and the method or event id. |
| `m.payload` | The payload, `bytes`. |
| `m.type` | `"request"`, `"notification"`, `"response"`, `"error"`, or `"type nn"` for another code heard. `None` to send: a notification for an event id, a request otherwise. |
| `m.iface` | The interface version (`None` to send: 1). |
| `m.client`, `m.session` | The Request ID (`None` to send: 0x1234 and the run's next session for a request, 0 for a notification). |
| `m.return_code` | The return code (an ERROR's says why). |
| `m.at_ms` | Heard: ms into the window; a call's answer, ms after the send. `None` on one not heard. |
| `m.source` | Heard: the `"host:port"` it came from. |
| `m.protocol` | Heard: the protocol version (0x01 is the only one SOME/IP defines). |
| `m.event` | Whether `method` is an event id (bit 15 set). |

### `SomeipHeard`

What a window heard (`someip.send`, `someip.listen`), a named tuple: `messages, malformed = heard`.

| member | what |
|---|---|
| `heard.messages` | The `SomeipMessage`s in the order heard. |
| `heard.malformed` | How many datagrams were not SOME/IP to their end: counted, never hidden. |

### `FlashReport`

What a completed flash did (`flash.program`).

| member | what |
|---|---|
| `r.bytes`, `r.blocks` | Header and image as transferred, and the 0x36 requests. |
| `r.wrapped` | The image was a BLBT `.img`, sent as it is. |
| `r.auth` | `"authenticated"`, `"not required"` (a keyless boot refused the challenge) or `"skipped"` (`auth=False`). |
| `r.reset_acknowledged` | The 0x11 reset was answered; `False` when its answer was lost to the reset, which is normal. |

### `BootSim`, `BootReport`

`blobly.BootSim(channel, tx=None, rx=None)`: a simulated blobly_emb bootloader on a CAN row of the
started project (see [Flashing](#13-flashing)). `with BootSim(ch) as boot:` stops it at the end of
the block.

| member | what |
|---|---|
| `boot.channel` | The `Channel` it serves. |
| `boot.stop()` | Stops it, once; returns the `BootReport`. |
| `boot.report` | The `BootReport` once stopped, else `None`. |
| `BootReport.authenticated` | The last 0x29 proof verified against the dev tester key. |
| `BootReport.erases`, `BootReport.blocks`, `BootReport.checks`, `BootReport.resets` | How many erases, 0x36 blocks, check routines and resets it answered. |
| `BootReport.bytes` | What the last download was sent, header included. |
| `BootReport.verified` | The last check routine passed: the CRC the image header states. |
### Module `blobly.bridge`

| name | what |
|---|---|
| `blobly.bridge.distributions()` | The WSL distributions installed for this user, sorted; `[]` where there is no WSL, and on Linux. |
| `blobly.bridge.start(distro, wait=True)` | Starts the bridge in `distro` unless it is connected or starting. With `wait`, returns its `rows()` once it has dialled in, and raises `BloblyError` with its reason if it fails; without, returns `None` once launched. `Refused` where it cannot be launched: no such distribution, or not on Windows. |
| `blobly.bridge.state(distro)` | `(state, reason)`: `"idle"`, `"starting"`, `"connected"` or `"failed"`, and why it failed (`""` otherwise). |
| `blobly.bridge.rows(distro)` | A connected bridge's channels as interfaces (`"bridge:Ubuntu-24.04/vcan0"`); `[]` when it is not connected. |
| `blobly.bridge.stop(distro)` | Disconnects a connected bridge, which ends it, and returns once it has gone. `BloblyError` (code -3) when it is not connected, or while a project is started; `Timeout` when it was cut but had not gone within 2 s. |
| `blobly.bridge.program()` | The `canbridge` a start runs: beside the engine (the Windows wheel's), else beside the executable; `None` when there is none (a start then runs the distribution's own) and on Linux. |

### `Project`

`blobly.Project(path)`: a `.blobnet` project. `path` is a `str`, `bytes` or path-like; a NUL in it
raises `ValueError`. It is also an `EventLoop`.

| member | what |
|---|---|
| `net.load()` | Reads the project into the engine, which holds one load at a time, and makes its listen-only rows and CAN-FD framing the ones every send is checked against. Returns `net`. `BloblyError` with code -3 while a stopped run is still releasing (`blobly.wait_released`). A reload keeps each channel still at its position under its name, and names the rows whose handlers it dropped in a `RuntimeWarning`. |
| `net.start()` | Brings the enabled rows up (simulated ECUs, UDS servers, generators, DoIP entities). Reloads first if the engine holds another load. Returns `net`. |
| `net.stop()` | Ends the run. `True` when the process is free for the next start; `False` when a loop outlived the stop's bound (`blobly.wait_released`). Stopping a project that is not started answers whether the process is free. |
| `with net:` | `start()` on entry, `stop()` on exit; warns (`RuntimeWarning`) when the stop returned `False`. |
| `net.channels` | The enabled rows, a `Channels`. `BloblyError` before `load()`. |
| `net.path` | The project file's absolute path (bytes when given bytes). |
| `net.started` | Whether this project is running. |
| `net.on_message(ch, id, fn, *, ext=None)`, `net.on_health(ch, fn)`, `net.on_timer(period_ms, fn)`, `net.run(duration_ms=1000)` | The event loop: see `EventLoop`. |
| `net.fault(channel, node, message, kind, ms=None, signal=None)` | Arms a fault on a simulated node's message while the project is started: `kind` a `FaultKind` or its string, for `ms` milliseconds or until cleared. `FaultRefused` where it could not take effect. |
| `net.clear_fault(channel, node, message)` | Lifts that message's fault. |
| `net.clear_faults()` | Lifts every fault. |
| `net.generators` | The run's generators, a `Generators` ([Generators](#generators)). `BloblyError` (code -3) when not started. |

### `EventLoop`

The event loop's rules without the engine, which `Project` runs over the project's channels. It
reaches time, frames and health only through hooks a subclass supplies, so a test can drive the
rules with fakes (`python/tests/test_events.py` does).

| member | what |
|---|---|
| `on_message(channel, id, fn, *, ext=None)` | `fn(frame)` for each frame on `channel` (a `Channel` or its name) received during `run()` whose id is `id`: an int (of the kind `ext` names: `None` either, `False` 11-bit, `True` 29-bit), a `Message` (its id and kind), or `None` (every frame). |
| `on_health(channel, fn)` | `fn(state)` during `run()` when the controller's ladder moves, and at its first sample. Sampled every 100 ms; never `""`. |
| `on_timer(period_ms, fn)` | `fn()` every `period_ms` (at least 1) during `run()`, on its own grid. |
| `run(duration_ms=1000)` | The loop, for a finite number of milliseconds, zero or more. |

### `Channels`, `Messages`, `Signals`

The collections of `net.channels`, `ch.messages` and `msg.signals`. All three read the same way.

| member | what |
|---|---|
| `c.Name` | The item of that name. `AttributeError` listing the names when there is none; `BloblyError` when two items share it. |
| `c["Name"]`, `c[i]` | By name (`KeyError` when there is none), or by position (`IndexError` past the end). |
| `for x in c`, `len(c)` | In project or database order. |
| `c.keys()` | The names, in order, each once. |
| `dir(c)` | The names that are identifiers and unique: what a REPL completes. |

### `Channel`

One enabled row of the project (`net.channels.CAN1`).

| member | what |
|---|---|
| `ch.name` | The row's name. |
| `ch.kind` | `"can"`, `"doip"` or `"someip"`. Only a CAN row carries frames. |
| `ch.iface` | The interface the row opens: as the project composes it, and while started, as the run has it. |
| `ch.send(id, data=b"", ext=False, fd=False, brs=False)` | Puts a frame on the wire. `fd`/`brs` left `False` take the wire's declared format. |
| `ch.recv(timeout_ms=1000)` | The next frame another node sent, or `None` after `timeout_ms` (rounded down to whole ms; `0` only looks; `None` waits for ever). Ctrl-C ends the wait within 100 ms. |
| `ch.look()` | `(frame or None, spent)`: one look at what is queued, without waiting. |
| `ch.expect(id, timeout_ms=1000, *, ext=None)` | The first frame another node sends with this id and kind (an int and `ext`, or a `Message`), within one deadline; `Timeout` otherwise. Frames read meanwhile are consumed. |
| `ch.expect_signal(message, signal, want, timeout_ms=1000)` | `(frame, value)`: the first frame of `message` whose `signal` matches `want` (a predicate, or a value compared with `==`), within one deadline; `Timeout` otherwise. Frames read meanwhile are consumed. |
| `ch.health()` | The controller's ladder now: `"ok"`, `"error warning"`, `"ERROR-PASSIVE"`, `"BUS-OFF"`, or `""`. |
| `ch.load()` | A `BusLoad`: the load of the decoded frames this channel's handle sent and read since it opened ([Bus metrics](#bus-metrics)). |
| `ch.diagnostics()` | A `BusDiagnostics`: the backend's dropped, controller-error and undecodable counts since the handle opened (on PCAN, CANsub and the CAN bridge, the shared wire's). |
| `ch.messages` | The row's database messages, a `Messages`, while the project is started. |
| `ch.decode(frame)` | `{signal: physical value}`, or `None` for a frame of no message or a remote frame. |
| `ch.uds(tx=None, rx=None)` | A `UdsClient` on this row: on a CAN row requests on `tx`, answers on `rx` (default 0x7E0 / 0x7E8); on a DoIP row over its connection, `tx` and `rx` refused. |
| `ch.uds_functional(functional_id, clients, request, window_ms=1000)` | `request` once on the functional id, each of `clients` (one or more `UdsClient`s of this channel) answering on its own id: a `FunctionalReply` each, in their order. On a DoIP row the functional logical address (`None`: 0xE400) and the row's one client. `window_ms` bounds each first answer. |
| `ch.discover(timeout_ms=1200)` | A DoIP row's entity asked who it is: a `DoipAnnouncement`; `Timeout` when none came. |
| `ch.close()` | Lets the bus handle go, and the connections of its UDS clients; the next use opens another. |

### `BusLoad`, `BusDiagnostics`

What `ch.load()` and `ch.diagnostics()` return: named tuples ([Bus metrics](#bus-metrics)).

| field | what |
|---|---|
| `BusLoad.percent` | The load over the last whole second, in percent; `None` until one has passed. |
| `BusLoad.average` | The load since the handle opened; `None` until one second has passed. |
| `BusLoad.frames` | The frames counted since open, both directions. |
| `BusLoad.bits` | Their nominal bit-times, worst-case stuffing. |
| `BusLoad.nominal` | The arbitration rate they are priced at, bit/s. |
| `BusDiagnostics.dropped` | Frames lost before delivery: a full queue, a driver overrun, a shared ring overwritten. |
| `BusDiagnostics.bus_errors` | Controller error records the device reported. |
| `BusDiagnostics.decode_errors` | Records the backend could not decode. |

### `Frame`

`blobly.Frame(id, data=b"", ext=False, fd=False, brs=False, rtr=False, esi=False, length=None, t_ms=None)`:
a CAN frame, as `recv` returns it and as `encode` builds it.

| member | what |
|---|---|
| `f.id` | The identifier. |
| `f.data` | The payload, `bytes`. |
| `f.length` | The payload's length; for a remote frame, the length it asks for. |
| `f.ext` | A 29-bit identifier. |
| `f.fd`, `f.brs` | CAN-FD, and its bit-rate switch. |
| `f.rtr` | A remote frame (no payload). |
| `f.esi` | CAN-FD's error-state indicator. |
| `f.t_ms` | When a received frame arrived, in ms on the `blobly.now_ms()` clock: its receive stamp where the backend has one, else when `recv` read it; `None` on a frame not received. Not part of the value. |
| `f == g`, `hash(f)` | Every field but `t_ms` equal; equal frames hash alike, so a frame can be a set member or a dict key. A frame is a value: setting a field raises `AttributeError`. |

### `Message`

A message of a row's databases (`ch.messages.Powertrain`).

| member | what |
|---|---|
| `msg.name` | Its name in the database. |
| `msg.id`, `msg.ext` | Its identifier, and whether it is 29-bit. |
| `msg.dlc` | The payload length `encode` gives it. |
| `msg.j1939` | Whether the database declares it J1939. |
| `msg.channel` | The `Channel` it belongs to. |
| `msg.signals` | Its signals, a `Signals`. |
| `msg.encode(**signals)` | The `Frame` with these signals at these physical values, every other at raw 0. |
| `msg.send(**signals)` | Encodes and sends on its channel; returns the `Frame`. |

### `Signal`

A signal of a message (`msg.signals.EngineSpeed`). physical = raw × `factor` + `offset`.

| member | what |
|---|---|
| `sig.name` | Its name. |
| `sig.start_bit`, `sig.length` | Where it sits, as the DBC numbers it, and its width in bits. |
| `sig.byte_order` | `"little"` (Intel) or `"big"` (Motorola). |
| `sig.signed` | Whether the raw value is two's complement. |
| `sig.factor`, `sig.offset` | The scaling. |
| `sig.minimum`, `sig.maximum` | The DBC's range; both 0 where it states none. Not applied by `encode`. |
| `sig.unit` | Its unit, `""` when none. |
| `sig.multiplexor` | Whether it is the message's multiplexor. |
| `sig.multiplexed`, `sig.mux_value` | Whether it is present only for one multiplexor value, and which. |
| `sig.labels` | The value table as `{physical value: text}`. |
| `sig.raw_labels` | The value table as `{raw key: text}`, every entry. |

### `UdsClient`

A UDS client on a CAN or DoIP row (`ch.uds()`). See [UDS diagnostics](#10-uds-diagnostics) and
[DoIP](#11-doip).

| member | what |
|---|---|
| `diag.channel` | The `Channel` it is on. |
| `diag.tx`, `diag.rx`, `diag.ext` | The CAN ids it opened on, and whether they are 29-bit (`None` on DoIP). |
| `diag.tester`, `diag.ecu` | A DoIP row's logical addresses, the tester's and the ECU's (`None` on CAN). |
| `diag.session(session=0x01)` | 0x10 DiagnosticSessionControl. Returns the answer after its SID: the session, then its timing record, whose P2 and P2* the client adopts. |
| `diag.tester_present()` | 0x3E 00 TesterPresent. |
| `diag.read_did(did)` | 0x22 ReadDataByIdentifier: the DID's value. |
| `diag.write_did(did, data)` | 0x2E WriteDataByIdentifier. |
| `diag.security_access(level, key_fn=None)` | 0x27: the seed for `level`, the key from `key_fn(seed)` (the reference key without one) at `level + 1`. Returns the seed; an all-zero seed (unlocked already) sends no key. |
| `diag.reset(kind=0x01)` | 0x11 ECUReset (1 hard, 2 key-off-on, 3 soft). Returns the answer after its SID. |
| `diag.comm_control(control, comm_type=0x01)` | 0x28 CommunicationControl: `control` 0..3 for messages of `comm_type`. |
| `diag.dtc_setting(on)` | 0x85 ControlDTCSetting: `True` on, `False` off (anything else is a `TypeError`). |
| `diag.clear_dtcs(group=0xFFFFFF)` | 0x14 ClearDiagnosticInformation: one DTC or a 24-bit group (the default is all). |
| `diag.dtcs(mask=0xFF)` | 0x19 02: the DTCs with any of `mask`'s status bits, each a `Dtc`. |
| `diag.supported_dtcs()` | 0x19 0A: every DTC the ECU supports, each with its whole status. |
| `diag.dtc_count(mask=0xFF)` | 0x19 01: how many DTCs have any of `mask`'s status bits. |
| `diag.snapshot_ids()` | 0x19 03: each DTC holding a snapshot, a `SnapshotId`. |
| `diag.snapshot(dtc, record=0xFF)` | 0x19 04: a `Snapshot` of DTC `dtc` (its code, or its name). |
| `diag.extended(dtc, record=0xFF)` | 0x19 06: the `Extended` data of DTC `dtc`. |
| `diag.did_size(did, size)` | States a snapshot DID's size, for one the client cannot read to learn it. |
| `diag.ext_record_size(record, size)` | States an extended data record's size (blobly_emb's 0x01..0x03 are known). |
| `diag.raw(request)` | Sends `request`; returns the positive answer, its SID included. |
| `diag.raw_suppressed(request)` | Sends `request` with suppress-positive-response set on its sub-function: silence is success, a refusal raises. Returns whether a positive answer came anyway. |
| `diag.last` | The last exchange, an `Exchange`, or `None` before the first, after a stop let the connection go, and after a functional request (its `FunctionalReply` is the answer). |
| `diag.close()`, `with diag:` | Lets the connection go for good; a later call refuses. |

### `Exchange`

One request a `UdsClient` put through, answered or not (`diag.last`).

| member | what |
|---|---|
| `x.request` | The request as it went out (a suppressed one with its bit set). |
| `x.answer` | The positive answer, a negative one's `7F <sid> <nrc>`, an undecodable one as it came, or `b""` when none came. |
| `x.nrc` | The negative response's code, else `None`. |
| `x.sent` | Whether the request went out whole. `False`: the ECU never had all of it, so repeating it does not ask twice. |
| `x.rtt_us` | From the send to the final answer, or to the failure, in microseconds. |
| `x.pending`, `x.pending_us` | How many responsePending (0x78) came, and the time from the first to the end. |

### `Dtc`, `SnapshotId`, `SnapshotRecord`, `Snapshot`, `Extended`

The fault memory as the ECU reported it.

| member | what |
|---|---|
| `Dtc.code`, `Dtc.name` | The 24-bit DTC and failure-type byte, and SAE J2012's display (`U0121-00`). |
| `Dtc.status`, `Dtc.availability` | The status byte, and the bits the ECU reports (0xFF where its answer carries no mask). |
| `Dtc.bits` | `{name: bool}` for each ISO 14229-1 status bit the ECU reports. |
| `SnapshotId.code`, `SnapshotId.name`, `SnapshotId.record` | A DTC holding a snapshot, and the record's number. |
| `SnapshotRecord.number`, `SnapshotRecord.dids` | A snapshot record's number, and `{did: value}` in the ECU's order. |
| `Snapshot.dtc`, `Snapshot.records` | The DTC with its status, and its records (none: nothing stored). |
| `Extended.dtc`, `Extended.records` | The DTC with its status, and `{record number: bytes}`. |
| `Extended.occurrence`, `Extended.aging`, `Extended.failed_cycles` | blobly_emb's counters (records 0x01, 0x02, 0x03), `None` where the answer does not carry one. |

### `FunctionalReply`

One client's reply to a functional request (`ch.uds_functional`).

| member | what |
|---|---|
| `r.outcome` | `"positive"`, `"negative"`, `"silent"`, `"pending"` or `"failed"`. |
| `r.answer` | The answer's bytes (positive, or `7F <sid> <nrc>`); `b""` for none. |
| `r.nrc` | A negative answer's code, else `None`. |
| `r.pended` | Whether responsePending came on the way. |
| `r.error` | Why it failed, else `""`. |

### `DoipAnnouncement`

What a DoIP entity says about itself (`ch.discover`, `blobly.doip_listen`).

| member | what |
|---|---|
| `a.vin` | The VIN, or `None` when the entity has none. |
| `a.logical_address` | Its logical address. |
| `a.eid`, `a.gid` | Its entity id and group id, 6 bytes each. |
| `a.source` | `"host:port"` it came from, which a tester dials. |

### `FaultKind`

`blobly.FaultKind`, a `str` enum: what `net.fault` does to a message. Its plain string works too.

| member | what |
|---|---|
| `FaultKind.DROP` | `"drop"`: not sent. |
| `FaultKind.BAD_CRC` | `"bad_crc"`: sent with its E2E checksum inverted. |
| `FaultKind.FREEZE_COUNTER` | `"freeze_counter"`: sent, its E2E alive counter stopped. |
| `FaultKind.OUT_OF_RANGE` | `"out_of_range"`: sent with one signal past its declared range. |

### `FaultRefused`

`blobly.FaultRefused`, a `Refused`: the engine refused a fault that could not take effect,
and armed nothing.

| member | what |
|---|---|
| `str(e)` | Why, in the engine's words. |
| `e.code` | -1. |

### `Generators`, `Generator`

`net.generators` is a `Generators`: the run's generators, every CAN channel's in project order.

| member | what |
|---|---|
| `gens["Name"]`, `gens["CAN1/Name"]`, `gens[i]` | By name, else by channel and name (`KeyError` for none, or for a name two share); by position (`IndexError` past the end). |
| `for g in gens`, `len(gens)` | In project order. |
| `g.name`, `g.channel`, `g.message`, `g.trigger` | Its name, the name of the channel it is written under, its DBC message (`""` for a raw frame), and `"manual"`, `"key"` or `"cyclic"` as the project writes it. |
| `g.id`, `g.ext` | The frame's id (its message's) and whether it is 29-bit. |
| `g.running` | Sending on its cycle now. |
| `g.cycle_ms` | Its cycle, 0 for none; set it (1 .. 3600000) to change it from the next frame. |
| `g.sent` | Frames its bus took, fired and cyclic alike. |
| `g.target`, `g.note` | The interface it sends on, and why it cannot send (`""` when it can). |
| `g.fire(timeout_ms=5000)` | Sends its current frame once; returns once the bus took it. `Timeout` after `timeout_ms` (at most 5000). |
| `g.start(cycle_ms=None)`, `g.stop()` | Sends it on its cycle (its own for `None` or 0); ends that. |
| `g.set(signal, value)` | `signal` at a static value from the next frame. |
| `g.source(signal, kind, **params)` | `signal` on a value source from the next frame: `kind` one of `"const"`, `"sine"`, `"sawtooth"`, `"counter"`, `"stepmod"`; `params` from `value`, `offset`, `amplitude`, `freq`, `phase`, `min`, `max`, `period`, `start`, `step` (1 when omitted), `modulo`, `count`, `base`, every other 0. |

### `GeneratorRefused`

`blobly.GeneratorRefused`, a `Refused`: the engine refused a generator call that could not take
effect, and nothing changed.

| member | what |
|---|---|
| `str(e)` | Why, in the engine's words. |
| `e.code` | -1. |

### `BloblyError`, `Refused`, `NegativeResponse`, `Timeout`, `PendingExpired`, `UndecodableAnswer`, `CarrierFailed`, `ConnectionLost`, `RoutingDenied`, `FlashFailed`

`blobly.BloblyError(message, code=-1)`, an `Exception`: the engine refused, or a call failed. The
others are its subclasses (see [Errors](#16-errors) and
[UDS diagnostics](#10-uds-diagnostics)).

| member | what |
|---|---|
| `str(e)` | The engine's message; for an expectation's `Timeout`, what was expected and what came instead. |
| `e.code` | -1 refused, -2 no such handle, -3 the wrong state; -4 to -10 the ways a UDS call fails; -11 a flash's own verdict. |
| `e.nrc`, `e.nrc_name` | `NegativeResponse` only: the code, and ISO 14229-1's name for it. |
| `e.exchange` | `NegativeResponse` and `ConnectionLost`: the `Exchange` it ended. |
| `e.routing_code`, `e.routing_name`, `e.hint`, `e.tester` | `RoutingDenied` only: the routing activation response code, ISO 13400-2's meaning, what to do about it, and the tester address asked for. |

### `blobly.pytest_plugin`

The pytest plugin ([Testing with pytest](#14-testing-with-pytest)). Not imported by `blobly`: a
suite loads it with `pytest_plugins = ["blobly.pytest_plugin"]` or `-p blobly.pytest_plugin`.

| name | what |
|---|---|
| `project` | Fixture: the started `Project`, its run the test module's; each test hears what arrives from its start, and its handlers and faults go with it. |
| `can1`, ... | Fixtures: one per enabled channel, named after it (lowercased, `_` for what a Python name cannot hold). |
| `diag` | Fixture: a `UdsClient` on the first enabled CAN channel (at 0x7E0 / 0x7E8), else the first DoIP one, or on the one named by parametrizing it indirectly; closed after the test. |
| `blobly_project` | Ini value: the project, relative to the ini file. |
| `--blobly-project=PATH` | Command line: the project, relative to the working directory; overrides the ini value. |

---

## 18. What is not there yet

Python covers bringing a project up, its channels, raw CAN, DBC messages and signals, the event
loop, bus health and metrics, fault injection, generator control, the E2E Profile 1 helpers, UDS over CAN and DoIP, DoIP
discovery, SOME/IP send, call and listen, flashing, the WSL bridge, `expect` and a pytest plugin. The rest is planned in [#507](https://github.com/MartenH/blobly_net/issues/507):

**Phase 1: diagnostics from Python.**
- UDS over CAN is here ([UDS diagnostics](#10-uds-diagnostics)): sessions, DIDs, 0x27, resets,
  0x14 / 0x28 / 0x85, DTCs with snapshots and extended data, functional addressing, raw and
  suppressed requests, the exchange timing and typed errors.
- The DoIP tester is here ([DoIP](#11-doip)): UDS over DoIP rows, functional addressing to
  0xE400, `discover` and `doip_listen`, with a denied routing activation and a lost connection
  typed.

**Phase 2: the rest of Lua's surface, and gaps both languages share.**
- SOME/IP send, call and listen are here ([SOME/IP](#12-someip)), and so is `flash.program`
  ([Flashing](#13-flashing)), with a simulated bootloader to rehearse it against.
- Stating a frame's format (a classic frame on a CAN-FD wire).
- Generator control is here ([Generators](#generators)): fire, start, stop, the cycle, a signal's
  value or source.
- Replay control and recording to a file.
- E2E verify on receive, and E2E declared in the DBC applied on send.
- Background cyclic senders and a session keep-alive (one owner thread per channel).
- Bus metrics are here ([Bus metrics](#bus-metrics)): load, and the dropped, error and
  undecodable counters, during a run.
- Raw ISO-TP; UDS timing and P2 configuration; the DoIP gateway retarget.
- Targets by node name from `system.toml`, and the DID codec from `ecu.toml`.
- Opening an interface that is not a project row, interface discovery, Vector channel
  assignment.
- J1939 transport-protocol reassembly and the address directory.

**Phase 3: hardening for AI.** A JSON run report and an overall run timeout, an API stability
policy for this package, and possibly an MCP server.

Also not built: a Python console beside a running GUI measurement (this package brings a project
up in your own process), removing a handler, and wheels for platforms other than Linux x86_64 and
Windows x64. Review findings on the package that are still being checked against `main` are in
[#506](https://github.com/MartenH/blobly_net/issues/506).
