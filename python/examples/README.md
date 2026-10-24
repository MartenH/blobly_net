# Python examples

Complete scripts for the `blobly` package, each runnable as it is. They default to the
repository's [`projects/sim-demo.blobnet`](../../projects/sim-demo.blobnet), whose simulated ECUs
run inside the script's own process, so no hardware and no drivers are needed. A project path on
the command line overrides it. `replay_record.py` defaults to
[`projects/replay-demo.blobnet`](../../projects/replay-demo.blobnet), `e2e_check.py` to
[`projects/e2e-demo.blobnet`](../../projects/e2e-demo.blobnet) for its E2E declarations, `described_node.py` to
[`projects/described-ecu-demo`](../../projects/described-ecu-demo), a simulated ECU its system
model describes, `j1939_listen.py` to [`projects/j1939-script.blobnet`](../../projects/j1939-script.blobnet), and `someip_node.py` needs no project (it talks to a SOME/IP node), and neither does `interfaces.py`, which opens buses by address.

| example | what it shows |
|---|---|
| [raw_can.py](raw_can.py) | First steps: list the channels with their kind and interface, receive frames, send 0x101 and check that the SUT answers 0x102. |
| [dbc_messages.py](dbc_messages.py) | A channel's database: messages and signals with units, ranges and value labels; encode and decode; send a message by signal name and decode the answer. |
| [event_loop.py](event_loop.py) | `on_message` by id and by message, `on_timer` for a periodic send, `on_health`, and `run()`. |
| [signal_monitor.py](signal_monitor.py) | The decoded values of chosen messages, printed twice a second for N seconds. |
| [background_send.py](background_send.py) | Background sends: a Request sent every 100 ms by a sender of the engine's while the script waits, the SUT's answers following it through an update, and the SUT's extended session held by a UDS keep-alive meanwhile. |
| [bus_metrics.py](bus_metrics.py) | A channel's bus load and its dropped / error / undecodable counts, once a second for N seconds. |
| [uds_diag.py](uds_diag.py) | UDS over CAN: the default session, the VIN (a multi-frame answer) and other DIDs with the exchange's timing, a negative response caught with its NRC, a security unlock with the reference key, and the DTCs with their status bits, a snapshot and extended data. |
| [doip_diag.py](doip_diag.py) | UDS over DoIP: the entity's announcements heard, the entity asked who it is, then over its connection the default session, the VIN it serves beside the one it announced, the DTCs, and a request to the functional address 0xE400. |
| [described_node.py](described_node.py) | A node of the system model by its name (`projects/described-ecu-demo`'s zone_a): its DIDs listed with their layout and gates, read by name and decoded, a gated parameter refused with what it needs (`WriteGated`), then written once the session and level are established, and the DTCs named by the node's faults. |

| [isotp_raw.py](isotp_raw.py) | Raw ISO-TP on the SUT's id pair with no UDS on top: a multi-frame answer reassembled, a request no UDS helper builds and its refusal as bytes; then a UDS client's waits, a short first wait on ids nothing answers and the timing a session answer adopted. |
| [fault_injection.py](fault_injection.py) | Faults on sim-demo's simulated ECUs, seen on the bus: Powertrain dropped for a second and back by itself, BrakePedal forced past its declared range until cleared, and `bad_crc` refused where nothing is protected. |
| [e2e_check.py](e2e_check.py) | E2E Profile 1 as a DBC declares it, on [`projects/e2e-demo.blobnet`](../../projects/e2e-demo.blobnet): each received frame's verdict (`Frame.e2e`), a broken checksum and a frozen counter caught by `expect(..., e2e=True)`, and a message sent by name stamped with its declared counter and CRC, beside the same message sent unstamped. |
| [flash_ecu.py](flash_ecu.py) | Flashing a blobly_emb bootloader with a progress bar and the session's report, against a simulated bootloader on CAN1 that verifies the 0x29 proof and the image's CRC; `--board` for a real one. |
| [replay_record.py](replay_record.py) | Replay and recording, on `projects/replay-demo.blobnet`: the wire recorded to a candump `.log` while a recording is replayed onto it — started paused, moved to 1.5 s, played at 4x to its end — and the file read back, every line ending in `T` (sent by this process). |
| [j1939_listen.py](j1939_listen.py) | J1939 on [`projects/j1939-script.blobnet`](../../projects/j1939-script.blobnet), the script playing every node: a BAM rejoined and decoded by PGN, an RTS/CTS connection followed as a listener, a dropped packet seen as a `sequence` fault, and the address directory after a contested claim. |
| [someip_node.py](someip_node.py) | SOME/IP against a node with a static peer endpoint (blobly_emb's `host_someip` by default): a method called and answered, a request sent with everything heard after it, and the node's events. CI runs it against a stand-in node on loopback. |
| [interfaces.py](interfaces.py) | No project: the interfaces present with their kind and CAN-FD support (`--cansub` adds an mDNS browse), the Vector channels and their assignments, then a frame exchanged between two buses opened by address (`--open vcan0` for a real wire). |
| [test_sim_demo.py](test_sim_demo.py) | A pytest suite on blobly's plugin: the `project` fixture and one per channel (`can1`), `expect` and `expect_signal`, `diag` over CAN and DoIP, and a project generator fired and answered. [conftest.py](conftest.py) loads the plugin and [pytest.ini](pytest.ini) names the project, which is all a suite of your own needs. |

## Running them

From a source checkout, build the library once (`./scripts/build_libblobly.sh build`) and run an
example with any CPython from 3.11 on (`python` or `py` on Windows):

```sh
python3 python/examples/raw_can.py
python3 python/examples/signal_monitor.py --seconds 5 --message BrakeStatus
python3 python/examples/raw_can.py path/to/your.blobnet --channel CAN1
```

Opened as a folder in VS Code, this one's [`.vscode/`](.vscode) runs and debugs the examples and
the tests ([docs/vscode.md](../../docs/vscode.md)).

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
