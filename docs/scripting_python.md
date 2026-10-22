# Scripting Blobly Net from Python

`python/blobly` is a Python package over **libblobly**, the Blobly Net engine built as a shared
library with a C ABI (`cmd/libblobly`, `bb.h`). The engine runs inside your Python process: a
project's simulated ECUs, UDS servers, generators and DoIP entities come up exactly as the
headless Lua runner brings them up, and your script sends and receives on its buses directly.

This is a **first cut**. What it covers and what it does not are both listed below.

## Setting up

You need the library and the package:

```sh
./scripts/build_libblobly.sh build        # build/libblobly.so (Linux) or build/blobly.dll (Windows)
export PYTHONPATH=$PWD/python             # or add python/ to sys.path
```

The package finds the library through `BLOBLY_LIB` if set, else beside the package, else in the
repository's `build/`. Any CPython 3.8 or later; no other packages are needed.

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

    net.on_message(can1, 0x102, lambda f: print("answer", f))
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
| `net.on_message(ch, id, fn)` | `fn(frame)` for each frame on `ch` with that `id` (`None`: every frame) received during `run()`. Your own sends are never heard back. |
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

- **DBC messages and signals.** There is no encoding or decoding by name, so frames are ids and bytes. This needs a decode/encode call in the C ABI.
- **UDS / diagnostics.** No equivalent of the Lua `uds.open` yet.
- **Sends that keep going outside `run()`.** There are no cyclic senders and no `on_send`: a periodic frame is `on_timer` + `send`, inside `run()`. Background sends need one owner thread per channel in the engine, which is planned and not built.
- **The GUI.** A Python console beside a running GUI measurement is not built. This package brings a project up in your own process.
- **Packaging.** There is no `pip install` yet: the package is used from the repository (`PYTHONPATH`). How it is distributed is still to be decided.
