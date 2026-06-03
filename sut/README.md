# Virtual SUT (System Under Test)

A **Python** stand-in for the ECU the V tester tests. It speaks SocketCAN on `vcan0`, and serves two
roles:

1. **Virtual ECU** — emits traffic and answers requests, so the tester has something live to test
   against before real hardware exists.
2. **Reference oracle** — being an *independent* implementation (different language, hand-written),
   it cross-validates the V code. Verified: V `candb` decodes the SUT's `0x100` frame to the exact
   same physical values the SUT encoded.

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
