# Python examples

Complete scripts for the `blobly` package, each runnable as it is. They default to the
repository's [`projects/sim-demo.blobnet`](../../projects/sim-demo.blobnet), whose simulated ECUs
run inside the script's own process, so no hardware and no drivers are needed. A project path on
the command line overrides it.

| example | what it shows |
|---|---|
| [raw_can.py](raw_can.py) | First steps: list the channels with their kind and interface, receive frames, send 0x101 and check that the SUT answers 0x102. |
| [dbc_messages.py](dbc_messages.py) | A channel's database: messages and signals with units, ranges and value labels; encode and decode; send a message by signal name and decode the answer. |
| [event_loop.py](event_loop.py) | `on_message` by id and by message, `on_timer` for a periodic send, `on_health`, and `run()`. |
| [signal_monitor.py](signal_monitor.py) | The decoded values of chosen messages, printed twice a second for N seconds. |
| [uds_diag.py](uds_diag.py) | UDS over CAN: the default session, the VIN (a multi-frame answer) and other DIDs with the exchange's timing, a negative response caught with its NRC, a security unlock with the reference key, and the DTCs with their status bits, a snapshot and extended data. |
| [doip_diag.py](doip_diag.py) | UDS over DoIP: the entity's announcements heard, the entity asked who it is, then over its connection the default session, the VIN it serves beside the one it announced, the DTCs, and a request to the functional address 0xE400. |
| [fault_injection.py](fault_injection.py) | Faults on sim-demo's simulated ECUs, seen on the bus: Powertrain dropped for a second and back by itself, BrakePedal forced past its declared range until cleared, and `bad_crc` refused where nothing is protected. |
| [test_sim_demo.py](test_sim_demo.py) | A pytest suite on blobly's plugin: the `project` fixture and one per channel (`can1`), `expect` and `expect_signal`, and `diag` over CAN and DoIP. [conftest.py](conftest.py) loads the plugin and [pytest.ini](pytest.ini) names the project, which is all a suite of your own needs. |

## Running them

From a source checkout, build the library once (`./scripts/build_libblobly.sh build`) and run an
example with any CPython from 3.11 on (`python` or `py` on Windows):

```sh
python3 python/examples/raw_can.py
python3 python/examples/signal_monitor.py --seconds 5 --message BrakeStatus
python3 python/examples/raw_can.py path/to/your.blobnet --channel CAN1
```

With `pip install blobly`, the same files run against the installed package. Copy them anywhere;
outside the repository, name the project on the command line. An example uses the installed
package when there is one, and the checkout's `python/blobly` otherwise. Its first line says which
it got: `blobly 0+source` is the checkout's.

The pytest example needs pytest, which `blobly` does not depend on:

```sh
pip install pytest
pytest python/examples/test_sim_demo.py
pytest python/examples/test_sim_demo.py --blobly-project=path/to/your.blobnet
pytest python/examples --junitxml=report.xml      # pytest's own JUnit report
```

## What they promise

- Every wait is bounded: no example can hang on a quiet bus.
- Exit status 0 means every check held. A failed check exits 1 with a `FAIL:` line on stderr
  saying what was expected. A bad argument exits 2 (argparse's usage error). An error from the
  library is a `blobly.BloblyError` traceback, exit 1.
- The engine writes its own lines (`project: ...`, `channel CAN1 ...`) to the same stdout. The
  examples make Python's output line-buffered, so the two stay in order when stdout is a pipe.

CI runs every example and the pytest example (`python/tests/test_examples.py`) under the runners'
own Python (3.12 today) on Linux and Windows, from the source tree and from the installed wheel,
and under 3.11 on Linux from the source tree.

The guide is [docs/scripting_python.md](../../docs/scripting_python.md). An AI agent should start
at [docs/agents.md](../../docs/agents.md).
