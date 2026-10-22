# Scripting Blobly Net from Python

`python/blobly` is a Python package over **libblobly**, the Blobly Net engine built as a shared
library with a C ABI (`cmd/libblobly`, `bb.h`). The engine runs inside your Python process: a
project's simulated ECUs, UDS servers, generators and DoIP entities come up exactly as the
headless Lua runner brings them up, and your script sends and receives on its buses directly.

This is a **first cut**. What it covers and what it does not are both listed below.

## Setting up

```sh
pip install blobly
```

The wheel carries the engine for its platform inside the package (`blobly/_native/`): Linux
x86_64 (a manylinux wheel built on the release floor, Ubuntu 22.04, so any glibc that new or
newer) and Windows x64 (with the MinGW runtime DLLs it loads, and their licences). The notices
of what is compiled into the engine — V's standard library, the Boehm GC, arxmodel and flatxml —
are in `blobly/_native/licenses/`. CPython 3.8
or later (not PyPy: the package detaches a thread from the library as CPython ends it); no other
packages are needed. Its version is the release's (`v.mod`'s, `2026.10.00`
installed as `2026.10.0`); `blobly.__version__` says which.

From a source checkout instead:

```sh
./scripts/build_libblobly.sh build        # build/libblobly.so (Linux) or build/blobly.dll (Windows)
export PYTHONPATH=$PWD/python             # or add python/ to sys.path
```

The package finds the library through `BLOBLY_LIB` if set, else the copy a wheel carries, else
beside the package, else in the repository's `build/`. A wheel built from a checkout
(`python scripts/build_wheel.py --native build/libblobly.so`) is versioned v.mod's version plus a
local label naming the commit (`2026.10.0+git.8027a81`), which PyPI refuses — only a release
build (`--release`, from the tagged commit) carries the plain version.

**Call `blobly.init()` on the main thread first** (any first call on the main thread does the
same: importing does not load the library). The library must be loaded on the process's main
thread (`bb.h`), and the package refuses to load it anywhere else. After that, any thread may
call in: a thread is attached to the library on its first call and detached when it ends,
without you doing anything. Loading, starting and stopping a project, and opening or closing a
channel, are serialised by the package, so threads may share a project. **Use a channel from one
thread at a time**, though. Some drivers forbid two threads on one handle (Kvaser's canlib), and
others keep state that a receive updates and a send or a health check reads (SocketCAN).

## An example

```python
import blobly

with blobly.Project("projects/sim-demo.blobnet") as net:      # loaded and started; stopped at the end
    can1 = net.channels.CAN1                                    # channels complete in a REPL
    print(can1.recv(1000))                                      # Frame(0x300 [E4 17 ...]) or None
    can1.send(0x101, b"\x05")                                   # sim-demo's SUT answers 0x102, 0x06

    msgs = can1.messages                                        # CAN1's database: messages complete too
    msgs.Request.send(ReqCode=5)                                # encoded by signal name, then sent
    print(can1.decode(msgs.Powertrain.encode(EngineSpeed=1500)))  # {'EngineSpeed': 1500.0, ...}

    net.on_message(can1, 0x102, lambda f: print("answer", f))
    net.on_message(can1, msgs.Response, lambda f: print(can1.decode(f)))  # {'RespCode': 6.0}
    net.on_health(can1, lambda s: print("CAN1 is", s))          # a software bus never fires
    net.on_timer(100, lambda: can1.send(0x101, b"\x05"))        # a cyclic frame, inside run()
    net.run(1000)
```

## What is there

| | |
|---|---|
| `Project(path)` | A `.blobnet` project. `with` loads and starts it and stops it at the end; `load()`, `start()` and `stop()` do the same separately. One run per process, and one thread drives load, start and stop. The library holds one loaded project at a time: `start()` reloads its own if another was loaded since. A reload keeps each channel whose row is still at its place under its name, so variables, timer closures and handlers go on working. A row that went is dropped and its handlers named. A channel of another project's load refuses rather than reach whichever row now has its place. |
| `net.stop()` | Ends the run. `True` when the process is free for the next start; `False` when a loop outlived the stop's bound (a driver call that will not return), and `blobly.wait_released(timeout_ms=None)` waits for it — a start refuses until then. |
| `net.channels` | The project's enabled rows: `net.channels.CAN1`, `net.channels["CAN-1"]`, `net.channels[0]` by position, iteration in project order, `keys()`, and `dir()` for completion. A name two rows share is refused as ambiguous; reach those rows by position. |
| `ch.kind` | `"can"`, `"doip"` or `"someip"`. Only a CAN row has frames: `send`/`recv` on another kind is refused by name. |
| `ch.send(id, data, ext=False, fd=False, brs=False)` | Puts a frame on the wire. `fd`/`brs` left `False` let the wire's declared format decide. A frame no controller could send is refused by the transport, as for every sender in the app. |
| `ch.recv(timeout_ms=1000)` | The next frame other nodes sent, waiting at most `timeout_ms` (a fraction is rounded down), or `None` when nothing came; `None` as the timeout waits for ever. Returns a `Frame` (`id`, `data`, `length`, `ext`, `fd`, `brs`, `rtr`, `esi`); for a remote frame `data` is empty and `length` is the length it asks for. |
| `ch.health()` | The controller's fault ladder now: `"ok"`, `"error warning"`, `"ERROR-PASSIVE"`, `"BUS-OFF"`, or `""` where the backend cannot say (the software buses). On SocketCAN and Vector the ladder advances only on a channel that is being read (`recv`, or `run()` with a handler naming it): a channel that only sends keeps its last state. |
| `ch.messages` | The messages of the row's databases, as the run loaded them (the merge of its `databases:`, the one its simulated ECUs encode by): `ch.messages.Powertrain`, `ch.messages["X"]`, by position, iteration in the database's order, `keys()`, and `dir()` for completion. Only while the project is started. A message stays usable across a stop and a start while the database still has it at its place under its name and id. A name two messages share is refused as ambiguous; reach those by position. |
| `msg.encode(**signals)` | The `Frame` the message sends with the named signals at these physical values and every other signal at raw 0, as the Lua `bus.send_message` encodes it. A name the message does not have is refused. A value is not held to the DBC's range, only to what the signal's width can carry (past that it is clamped to the nearer end), so a test can send an out-of-range value on purpose. `fd`/`brs` are left unset, so a send takes the wire's declared format. |
| `msg.send(**signals)` | Encodes the message and sends it on its channel; returns the encoded `Frame`, whose `fd`/`brs` are unset (what goes out takes the wire's declared format). |
| `msg.id`, `ext`, `dlc`, `j1939`, `signals` | The message as its database defines it. `j1939` is whether the database declares it J1939. `msg.signals` is its signals by name, each a `Signal`: `start_bit` (as the DBC numbers it), `length`, `byte_order` (`"little"` Intel, `"big"` Motorola), `signed`, `factor`, `offset`, `minimum`, `maximum` (both 0 where the DBC states no range), `unit`, `multiplexor`, `multiplexed`, `mux_value`, and the value table twice: `labels` as `{physical value: text}`, the values `decode()` returns, and `raw_labels` as `{raw key: text}`, the keys the database gives (two's complement for a signed signal) — every entry, where two keys a double cannot tell apart (past 2^53) are one entry of `labels`. |
| `ch.decode(frame)` | `{signal: physical value}` for what the frame says in the row's databases, as the Lua `decode()` reads it: the message of its id and kind (else, for an extended frame, one of its J1939 PGN), and each signal the frame carries — a multiplexed signal its switch does not select is left out. `None` for a frame of no message, or a remote frame. |
| `net.on_message(ch, id, fn)` | `fn(frame)` for each frame on `ch` with that `id` (`None`: every frame) received during `run()`. `id` may be a message from `ch.messages`, which matches its id and its kind as they were when the handler was registered (an int matches either kind). A J1939 message's frames from another source address do not have its id; `decode()` reads those. Your own sends are never heard back. |
| `net.on_health(ch, fn)` | `fn(state)` during `run()` when the ladder has moved, and at its first sample with the state then. Sampled every 100 ms, so a state held for less than that can be missed. `run()` reads the channel for it only on SocketCAN and Vector, where the ladder needs that. |
| `net.on_timer(period_ms, fn)` | `fn()` every `period_ms` during `run()`, on its own grid: a late fire does not delay the next one, and points missed while the script was busy (or a long callback ran) are skipped, not sent in a burst. The period must be at least 1 ms. |
| `net.run(duration_ms)` | The event loop, for a finite number of milliseconds (zero or more). It reads every channel a handler names, and a frame it reads is consumed, whether or not a handler matched it. |
| `blobly.BloblyError` | Anything the library refused, with its message; `.code` is `bb.h`'s. |

`run()` works the way the Lua `run()` does (`docs/scripting.md`), on one thread with no
background readers:

- **Waiting.** With one channel it blocks in the driver. With several it looks at each in turn
  every 0.1 ms (1 ms on Windows), and at once again when a look stopped at its bound with
  records still queued behind it (`Channel.look()`).
- **Health.** `on_health` reads its channel only where the ladder moves while it is read
  (SocketCAN, Vector); where it is polled (PCAN, Kvaser, CANsub, the software buses) the
  channel's frames are left for `recv`.
- **The deadline is per event** (a frame, a timer, one health handler). None is taken up once
  the deadline has passed. A frame taken up before it reaches every handler it matches.
- **Nesting.** A handler may call `send`, `recv` or even `run()`. A timer is never fired again
  inside its own callback.

## What is not there yet

- **UDS / diagnostics.** No equivalent of the Lua `uds.open` yet.
- **Sends that keep going outside `run()`.** There are no cyclic senders and no `on_send`: a periodic frame is `on_timer` + `send`, inside `run()`. Background sends need one owner thread per channel in the engine, which is planned and not built.
- **The GUI.** A Python console beside a running GUI measurement is not built. This package brings a project up in your own process.
- **Other platforms.** Wheels exist for Linux x86_64 and Windows x64 only; elsewhere, build the library and use the source checkout.
