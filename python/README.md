# blobly

Blobly Net's CAN test engine from Python. `blobly` loads a Blobly Net project (`.blobnet`), brings
up its simulated ECUs, and gives you its channels — send, receive, the controller's health — and an
event loop with handlers for frames, health changes and timers.

```sh
pip install blobly
```

```python
import blobly

blobly.init()  # on the main thread
with blobly.Project("sim-demo.blobnet") as net:
    can1 = net.channels.CAN1
    net.on_message(can1, 0x102, print)
    net.on_timer(100, lambda: can1.send(0x101, b"\x05"))
    net.run(1000)
```

The wheel carries the engine (`libblobly`) for its platform: Linux x86_64 and Windows x64. No other
package is needed.

Documentation: [docs/scripting_python.md](https://github.com/MartenH/blobly_net/blob/main/docs/scripting_python.md)
in the Blobly Net repository.
