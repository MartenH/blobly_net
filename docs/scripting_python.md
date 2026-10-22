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

    net.on_message(can1, 0x102, lambda f: print("answer", f))
    net.on_health(can1, lambda s: print("CAN1 is", s))          # a software bus never fires
    net.on_timer(100, lambda: can1.send(0x101, b"\x05"))        # a cyclic frame, inside run()
    net.run(1000)
```

## What is there

| | |
|---|---|
| `Project(path)` | A `.blobnet` project. `with` loads and starts it and stops it at the end; `load()`, `start()` and `stop()` do the same separately. One run per process, and one thread drives load, start and stop. The library holds one loaded project at a time: `start()` reloads its own if another was loaded since. A reload keeps each channel whose row is still at its place under its name, so variables, timer closures and handlers go on working. A row that went is dropped and its handlers named. A channel of another project's load refuses rather than reach whichever row now has its place. |
| `net.channels` | The project's enabled rows: `net.channels.CAN1`, `net.channels["CAN-1"]`, `net.channels[0]` by position, iteration in project order, `keys()`, and `dir()` for completion. A name two rows share is refused as ambiguous; reach those rows by position. |
| `ch.send(id, data, ext=False, fd=False, brs=False)` | Puts a frame on the wire. `fd`/`brs` left `False` let the wire's declared format decide. A frame no controller could send is refused by the transport, as for every sender in the app. |
| `ch.recv(timeout_ms=1000)` | The next frame other nodes sent, waiting at most `timeout_ms` (a fraction is rounded down), or `None` when nothing came; `None` as the timeout waits for ever. Returns a `Frame` (`id`, `data`, `length`, `ext`, `fd`, `brs`, `rtr`, `esi`); for a remote frame `data` is empty and `length` is the length it asks for. |
| `ch.health()` | The controller's fault ladder now: `"ok"`, `"error warning"`, `"ERROR-PASSIVE"`, `"BUS-OFF"`, or `""` where the backend cannot say (the software buses). On SocketCAN and Vector the ladder advances only on a channel that is being read (`recv`, or `run()` with a handler naming it): a channel that only sends keeps its last state. |
| `net.on_message(ch, id, fn)` | `fn(frame)` for each frame on `ch` with that `id` (`None`: every frame) received during `run()`. Your own sends are never heard back. |
| `net.on_health(ch, fn)` | `fn(state)` during `run()` when the ladder has moved, and at its first sample with the state then. Sampled every 100 ms, so a state held for less than that can be missed. |
| `net.on_timer(period_ms, fn)` | `fn()` every `period_ms` during `run()`, on its own grid: a late fire does not delay the next one, and points missed while the script was busy (or a long callback ran) are skipped, not sent in a burst. The period must be at least 1 ms. |
| `net.run(duration_ms)` | The event loop, for a finite number of milliseconds (zero or more). It reads every channel a handler names, and a frame it reads is consumed, whether or not a handler matched it. |
| `blobly.BloblyError` | Anything the library refused, with its message; `.code` is `bb.h`'s. |

`run()` works the way the Lua `run()` does (`docs/scripting.md`), on one thread with no
background readers:

- **Waiting.** With one channel it blocks in the driver. With several it looks at each in turn
  every 0.1 ms (1 ms on Windows).
- **The deadline is per event** (a frame, a timer, one health handler). None is taken up once
  the deadline has passed. A frame taken up before it reaches every handler it matches.
- **Nesting.** A handler may call `send`, `recv` or even `run()`. A timer is never fired again
  inside its own callback.

## What is not there yet

- **DBC messages and signals.** There is no encoding or decoding by name, so frames are ids and bytes. This needs a decode/encode call in the C ABI.
- **UDS / diagnostics.** No equivalent of the Lua `uds.open` yet.
- **Sends that keep going outside `run()`.** There are no cyclic senders and no `on_send`: a periodic frame is `on_timer` + `send`, inside `run()`. Background sends need one owner thread per channel in the engine, which is planned and not built.
- **The GUI.** A Python console beside a running GUI measurement is not built. This package brings a project up in your own process.
- **Other platforms.** Wheels exist for Linux x86_64 and Windows x64 only; elsewhere, build the library and use the source checkout.
- **Two rules of the Lua `run()` the ABI cannot carry yet.** A look that spent its bound skipping queued records (`transport.look_was_spent`) is answered as "nothing", so the loop sleeps a slice before looking again rather than at once (slower, never lossy). And a channel named only by `on_health` is always read, because the ABI does not say whether its ladder needs a reader.
- **Which kind of channel a row is.** The ABI does not say whether a row is CAN, DoIP or SOME/IP. A send on a DoIP row fails with the transport's error, not with "not a CAN bus".
