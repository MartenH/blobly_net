# Virtual SUT (System Under Test)

**Python reference implementations, kept for one reason: they are not V.**

> **These are oracles, not the simulator.** Running an ECU for day-to-day use is
> [`modules/sim`](../modules/sim) — native, in-process, no interpreter, and what `sim-demo` and
> `scripts/runtests.sh` actually use. You do **not** need Python to build, run or test blobly_net.
> Nothing here is on that path.

The value of these files is precisely that they are an **independent implementation** in another
language: checking a V decoder against a V encoder proves only that they agree with each other.
So each one pins a V module to something written by someone else:

| oracle | pins | how |
|---|---|---|
| `can_sut.py` | `modules/sim` | `encode_powertrain()` output is frozen as golden vectors in `sim_test.v`; the native engine must reproduce them byte-for-byte |
| `dbc_oracle.py` | `modules/candb` | cantools decodes the same frame; physical values must match |
| `mf4_bridge.py` | `modules/mf4` | asammdf parses the same `.mf4`; frame counts/ids must match |
| `uds_server.py` | `modules/uds` | the behaviour `modules/uds/server.v` was written to mirror |
| `doip_server.py` | `modules/doip` | an independent DoIP peer to talk to |
| `arxml_oracle.py` | `modules/candb` (`arxml.v`) | cantools reads the same AUTOSAR system description; `diff` against `cmd/arxml2dbc --dump`. The known differences (E2E offsets, ranges, receivers of signal-less frames) are in its docstring |

They run **at development time**, by hand, when a decoder changes — not in CI, which is V-only.
`can_sut.py` is stdlib-only; the rest need [`requirements.txt`](requirements.txt).

The boundary is only the **wire** (CAN frames, sockets, files) — no FFI, fully process-separated.

Python is used here deliberately for its mature automotive stack (python-can, cantools, udsoncan,
can-isotp, scapy) which we'll lean on as references in later phases. The boundary with the V tester
is only the **wire** (CAN frames) — no FFI, fully process-separated.

## What `can_sut.py` does (stdlib only)

| Frame | Dir | Meaning |
|-------|-----|---------|
| `0x100` Powertrain | TX @10Hz | EngineSpeed/VehicleSpeed/CoolantTemp/ThrottlePos/Gear/CruiseOn, encoded with the same bit layout the V `candb` module decodes |
| `0x700` Heartbeat | TX @10Hz | rolling 1-byte counter |
| `0x101 → 0x102` | RX→TX | request/response (echoes payload, first byte +1) |

## Run

```sh
./scripts/setup_vcan.sh                 # bring up vcan0 (once)
python3 sut/can_sut.py                  # start the virtual ECU
# in another terminal, watch with our tester or can-utils:
./build/can_smoke dump vcan0            # or: candump vcan0
./build/can_smoke send vcan0 101 AABB   # poke the request → see 0x102 response
```

## Later (oracle libs, optional)

`requirements.txt` lists the reference libraries used in future phases (DBC, UDS, ISO-TP). The SUT
above needs none of them — install only when those phases start:

```sh
python3 -m venv .venv && . .venv/bin/activate && pip install -r sut/requirements.txt
```
