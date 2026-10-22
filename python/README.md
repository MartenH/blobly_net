# blobly

Blobly Net's CAN test engine from Python. `blobly` loads a Blobly Net project (`.blobnet`), brings
up its simulated ECUs inside your process, and gives you its channels: send and receive frames,
encode and decode DBC messages by signal name, read the controller's health, react to traffic
with an event loop of frame, timer and health handlers, inject faults into the simulated ECUs,
and protect frames with AUTOSAR E2E Profile 1.

```sh
pip install blobly
```

The wheel carries the engine (`libblobly`) for its platform, Linux x86_64 or Windows x64, and
needs no other package. It supports CPython 3.11 and newer; CI tests 3.12 on both platforms and
3.11 on Linux.

This runs as it is after the install. It writes a two-row project whose rows share one in-process
bus, and hears on one row what the other sends:

```python
import os
import tempfile

import blobly

PROJECT = """\
project:
  name: two rows, one bus
  version: 8
channels:
  - name: A
    type: can
    interface: inproc:demo
  - name: B
    type: can
    interface: inproc:demo
"""

blobly.init()  # on the main thread
with tempfile.TemporaryDirectory() as folder:
    path = os.path.join(folder, "two_rows.blobnet")
    with open(path, "w") as f:
        f.write(PROJECT)
    with blobly.Project(path) as net:  # loaded and started; stopped when the block ends
        a, b = net.channels.A, net.channels.B
        net.on_message(b, 0x123, lambda frame: print("B heard", frame))
        net.on_timer(100, lambda: a.send(0x123, b"\x01\x02"))
        net.run(500)
```

The repository's `projects/sim-demo.blobnet` simulates a vehicle on two buses, with a database
and ECUs that answer requests. The examples run against it:

- [Examples](https://github.com/MartenH/blobly_net/tree/main/python/examples): raw CAN, DBC
  messages, the event loop, a signal monitor, fault injection, and a pytest suite.
- [The Python guide](https://github.com/MartenH/blobly_net/blob/main/docs/scripting_python.md):
  setting up, adapters per OS, frames, databases, the event loop, fault injection and E2E,
  threads, errors, the complete reference, and what is not there yet.
- [For AI agents](https://github.com/MartenH/blobly_net/blob/main/docs/agents.md): how an agent
  drives Blobly Net: running it, finding out what a project offers, bounded waits and errors.
- [Blobly Net](https://github.com/MartenH/blobly_net): the GUI, the Lua runner and the rest.
