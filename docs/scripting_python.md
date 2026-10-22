# Scripting Blobly Net from Python

`blobly` puts the Blobly Net engine inside your own Python process. It is a ctypes package over
**libblobly**, the engine built as a shared library with a C ABI (`cmd/libblobly`, `bb.h`).
Loading a project brings up its simulated ECUs, UDS servers, generators and DoIP entities in that
process, exactly as the headless Lua runner does. Your script then sends and receives on the
project's buses directly.

**Python is the primary scripting interface** ([#507](https://github.com/MartenH/blobly_net/issues/507)).
Each capability is written once in the engine and exposed through the C ABI to Python first. Lua
([scripting.md](scripting.md)) stays for the GUI's Script panel, quick bench work and the
existing suites. Today Lua also has what Python does not have yet: diagnostics (UDS over CAN and
DoIP), SOME/IP, flashing, the E2E helpers, fault injection and `expect`.
[What is not there yet](#12-what-is-not-there-yet) lists those, with #507's phases.

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
9. [Threads](#9-threads)
10. [Errors](#10-errors)
11. [Reference](#11-reference)
12. [What is not there yet](#12-what-is-not-there-yet)

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
CI. The wheel is tagged
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
[Threads](#9-threads)).

---

## 2. Running

The smallest useful script sends sim-demo's request and waits, at most a second, for the answer:

```python
import time

import blobly

blobly.init()                                                  # load the engine, on the main thread
with blobly.Project("projects/sim-demo.blobnet") as net:       # loaded and started; stopped at the end
    can1 = net.channels.CAN1
    can1.send(0x101, b"\x05")                                  # sim-demo's SUT answers with 0x102
    deadline = time.monotonic() + 1.0
    while time.monotonic() < deadline:                         # every wait is bounded
        frame = can1.recv(100)                                 # at most 100 ms; None when nothing came
        if frame is not None and frame.id == 0x102:
            print("answer:", frame)                            # Frame(0x102 [06])
            break
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
| [test_sim_demo.py](../python/examples/test_sim_demo.py) | pytest: a module-scoped fixture starts the project. |

**What the engine prints.** The engine writes its progress and warnings (`project: ...`,
`channel CAN1 (inproc:CAN1): simulating 2 node(s) ...`) to the process's stdout and stderr, as
the headless runner does. When stdout is a pipe, Python buffers its own output and the engine's
lines come out first. `sys.stdout.reconfigure(line_buffering=True)`, or `python -u`, keeps them
in order.

**Exit status** is Python's own. An uncaught exception, `blobly.BloblyError` included, exits 1
with its traceback.

**Ctrl-C.** A call into the engine is not interrupted: the `KeyboardInterrupt` is raised when the
call returns. `recv(timeout_ms)` returns within its timeout, and `run()` waits at most a second at
a time, so Ctrl-C ends either within its wait. `recv(None)` on a quiet bus never returns, and
Ctrl-C cannot end it. A `with` block stops the project on the way out, an interrupt included.

---

## 3. Projects

A project is a `.blobnet` file ([project_editing.md](project_editing.md)): its channels, each
with an interface, its databases and the ECUs simulated on it.

- `blobly.Project(path)` names the file. `load()` reads it, `start()` brings it up, and `stop()`
  ends the run. `with blobly.Project(path) as net:` loads and starts it, and stops it when the
  block ends.
- **What `start()` brings up**, for every enabled row: the simulated ECUs (`simulation:`) and
  their UDS servers, the cyclic generators (`senders:` with `trigger: cyclic`), and a DoIP
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
  rows that went are dropped, and the reload raises `BloblyError` naming them (from `start()` too,
  which then has not started: call it again).

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
- **The WSL bridge does not start from a pip install.** Opening a `bridge:` channel starts
  `canbridge` in the distribution. The engine looks for `canbridge` beside the host executable
  (here `python.exe`), else on the distribution's PATH. A pip install ships no `canbridge`, so
  from Python the bridge starts only where `canbridge` is on the distribution's PATH (copy it from
  the Windows bundle). WSL needs mirrored networking, and the open can block up to 20 s while
  the bridge starts. Untested from Python.
- **CANsub: name the device.** The row must carry the device id: Python cannot discover one.
- **Listen-only rows** (`listen_only: true` on a CAN row) refuse every send on their wire with
  `BloblyError`, and PCAN, Kvaser, Vector and CANsub also silence the controller, so the adapter
  does not acknowledge frames either. On SocketCAN the controller still acknowledges unless the
  interface itself is listen-only. The flag does nothing for a DoIP or SOME/IP row.
- **What CI exercises from Python is `inproc:` only.** Every other backend is the same code the
  app runs and is verified on hardware there ([windows_can_hardware.md](windows_can_hardware.md)),
  but not from a Python host.

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
  what is queued; `None` waits for ever (avoid it: see Ctrl-C above).
- `ch.look()` is one look at what is already queued: `(frame or None, spent)`. `spent` says the
  look stopped at its bound with records still queued behind it, so a poller looks again at once
  rather than sleeping.
- A received **`Frame`** has `id`, `data`, `length`, `ext`, `fd`, `brs`, `rtr` and `esi`. For a
  remote frame `data` is empty and `length` is the length it asks for. Two frames are equal when
  every field is. A received frame carries no timestamp yet.
- **A frame read is consumed.** `recv` takes it off the channel's handle, so a loop that waits for
  one id drops every other frame it reads on the way.

```python
import time

import blobly


def wait_for(ch, frame_id, timeout_ms):
    """The first frame with this id within timeout_ms, else None. Other frames are consumed."""
    deadline = time.monotonic() + timeout_ms / 1000
    while (left_ms := (deadline - time.monotonic()) * 1000) > 0:
        frame = ch.recv(left_ms)
        if frame is not None and frame.id == frame_id:
            return frame
    return None


with blobly.Project("projects/sim-demo.blobnet") as net:
    can1 = net.channels.CAN1
    can1.send(0x101, [0x05])
    answer = wait_for(can1, 0x102, 1000)
    print(answer, answer.data.hex(), answer.length, answer.ext, answer.fd)
    can1.send(0x18DAF110, b"\x02\x10\x01", ext=True)          # a 29-bit id
    can1.send(0x123, bytes(range(12)), fd=True, brs=True)      # a CAN-FD frame, 12 bytes
    frame, spent = can1.look()                                 # what is queued now, no wait
```

`expect`, a wait for one frame or one signal value with the timeout built in, is #507 Phase 1;
until then the loop above is the pattern.

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
- `ch.decode(frame)` returns `{signal: physical value}` for what the frame says in the row's
  databases: the message of its id and kind (else, for an extended frame, one with its J1939
  PGN), and each signal the frame carries. A multiplexed signal its multiplexor does not select is
  left out. It returns `None` for a frame of no message, and for a remote frame. Which message a
  frame decoded as is not returned.

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
    print("sent", sent)
```

---

## 7. The event loop

Register handlers on the project, then run the loop for a while:

- `net.on_message(ch, id, fn)` calls `fn(frame)` for each frame on `ch` received during `run()`
  whose id is `id`. An int matches that id of either kind (11- or 29-bit). A `Message` matches its
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
- **Waiting.** With one channel it blocks in the driver, at most a second at a time. With several
  it looks at each in turn every 0.1 ms (1 ms on Windows).
- **Nesting.** A handler may call `send`, `recv` or `run()` itself. An inner `run()` first gives
  the frame being handled to the handlers after the current one. A timer is never called again
  inside its own callback.
- **An exception in a handler** ends that frame's dispatch and propagates out of `run()`.
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

---

## 9. Threads

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

## 10. Errors

| exception | when |
|---|---|
| `blobly.BloblyError` | The engine refused: a project that does not load, a channel that will not open, a send the transport refuses, a listen-only row, a channel of an earlier load, an ambiguous name, an unknown signal in `encode`. Also: no engine found, a first load off the main thread, a Python that is not CPython. `str(e)` is the engine's message; `e.code` says which kind. |
| `ValueError` | An argument no CAN frame or wait can have: an id that is not an integer of at most 29 bits, more than 64 bytes of data, a NUL in a path or signal name, a timeout past 2^31 - 1 ms, a timer period that is not a number of at least 1 ms, a `run()` duration that is not a finite number, zero or more. |
| `TypeError` | A timeout that is not a finite number (or `None`), a signal value that is not a number, an `on_message` id that is not an int, `None` or a `Message`. |
| `AttributeError` | An unknown name as an attribute: `net.channels.NOPE`, `msgs.NOPE`, `signals.NOPE`. The message lists the names there are. |
| `KeyError`, `IndexError` | An unknown name by `["NOPE"]`, a position past the end. |
| `RuntimeWarning` (a warning) | A `with` block's stop found a loop that outlived the stop's bound. |

`BloblyError.code` is bb.h's:

| code | meaning |
|---|---|
| -1 | refused, with the reason in the message |
| -2 | no such bus handle, or a closed one |
| -3 | the wrong state: nothing loaded, not started, already started, a previous run still releasing, a channel or message of an earlier load or run |

Diagnostic errors (a negative response, a timeout) arrive with diagnostics in #507 Phase 1.

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

## 11. Reference

Import everything from `blobly`. The submodules `blobly.project` and `blobly.events` are the
implementation, and their other names are not part of the interface.
`python/tests/test_docs.py` checks that every public class, method, property and attribute of
the package is named in this section.

### Module `blobly`

| name | what |
|---|---|
| `blobly.init()` | Loads the engine. Call it on the main thread before any other thread calls in. |
| `blobly.version()` | The engine's version, v.mod's spelling (`"2026.10.01"`). |
| `blobly.wait_released(timeout_ms=None)` | Waits until the process is free for a start: `True`, or `False` once `timeout_ms` passed (`None` waits for ever). |
| `blobly.__version__` | The package's version (`"2026.10.1"`); `"0+source"` in a source checkout. |

### `Project`

`blobly.Project(path)`: a `.blobnet` project. `path` is a `str`, `bytes` or path-like; a NUL in it
raises `ValueError`. It is also an `EventLoop`.

| member | what |
|---|---|
| `net.load()` | Reads the project into the engine, which holds one load at a time. Returns `net`. A reload keeps each channel still at its position under its name, and raises `BloblyError` naming the rows whose handlers it dropped. |
| `net.start()` | Brings the enabled rows up (simulated ECUs, UDS servers, generators, DoIP entities). Reloads first if the engine holds another load. Returns `net`. |
| `net.stop()` | Ends the run. `True` when the process is free for the next start; `False` when a loop outlived the stop's bound (`blobly.wait_released`). Stopping a project that is not started answers whether the process is free. |
| `with net:` | `start()` on entry, `stop()` on exit; warns (`RuntimeWarning`) when the stop returned `False`. |
| `net.channels` | The enabled rows, a `Channels`. `BloblyError` before `load()`. |
| `net.path` | The project file's absolute path (bytes when given bytes). |
| `net.started` | Whether this project is running. |
| `net.on_message(ch, id, fn)`, `net.on_health(ch, fn)`, `net.on_timer(period_ms, fn)`, `net.run(duration_ms=1000)` | The event loop: see `EventLoop`. |

### `EventLoop`

The event loop's rules without the engine, which `Project` runs over the project's channels. It
reaches time, frames and health only through hooks a subclass supplies, so a test can drive the
rules with fakes (`python/tests/test_events.py` does).

| member | what |
|---|---|
| `on_message(channel, id, fn)` | `fn(frame)` for each frame on `channel` (a `Channel` or its name) received during `run()` whose id is `id`: an int (either kind), a `Message` (its id and kind), or `None` (every frame). |
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
| `ch.recv(timeout_ms=1000)` | The next frame another node sent, or `None` after `timeout_ms` (rounded down to whole ms; `0` only looks; `None` waits for ever). |
| `ch.look()` | `(frame or None, spent)`: one look at what is queued, without waiting. |
| `ch.health()` | The controller's ladder now: `"ok"`, `"error warning"`, `"ERROR-PASSIVE"`, `"BUS-OFF"`, or `""`. |
| `ch.messages` | The row's database messages, a `Messages`, while the project is started. |
| `ch.decode(frame)` | `{signal: physical value}`, or `None` for a frame of no message or a remote frame. |
| `ch.close()` | Lets the bus handle go; the next use opens another. |

### `Frame`

`blobly.Frame(id, data=b"", ext=False, fd=False, brs=False, rtr=False, esi=False, length=None)`:
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
| `f == g` | Every field equal. |

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

### `BloblyError`

`blobly.BloblyError(message, code=-1)`, an `Exception`: the engine refused.

| member | what |
|---|---|
| `str(e)` | The engine's message. |
| `e.code` | -1 refused, -2 no such handle, -3 the wrong state (see [Errors](#10-errors)). |

---

## 12. What is not there yet

Python covers bringing a project up, its channels, raw CAN, DBC messages and signals, the event
loop and bus health. The rest is planned in [#507](https://github.com/MartenH/blobly_net/issues/507):

**Phase 1: diagnostics from Python.**
- UDS over CAN, with Lua's helpers (sessions, DIDs, 0x27, DTCs with snapshots and extended data,
  functional addressing, raw and suppressed requests), the exchange timing returned as data, and
  typed `NegativeResponse` and `Timeout` errors.
- The DoIP tester: UDS over DoIP rows, `discover` and `listen`. Today a DoIP row is listed and its
  entity hosted, but Python cannot talk to it.
- A pytest plugin: `project`, `channel` and `diag` fixtures, `expect` and `expect_signal`.
- Fault injection (`sim.fault`) and the E2E Profile 1 helpers.

**Phase 2: the rest of Lua's surface, and gaps both languages share.**
- SOME/IP send, call and listen; `flash.program`.
- A received frame's timestamp, and stating a frame's format (a classic frame on a CAN-FD wire).
- Replay control and recording to a file; generator control (fire, start, stop, cycle).
- E2E verify on receive, and E2E declared in the DBC applied on send.
- Background cyclic senders and a session keep-alive (one owner thread per channel).
- Bus metrics: load, and dropped or error counters during a run.
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
