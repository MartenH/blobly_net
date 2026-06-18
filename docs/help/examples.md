# Examples

Every example here is **driver-free** — no CAN hardware, no Python. Load one via
**File ▸ Open Example**, then press **▶ Start**.

## Simulation — `sim-demo`
Two virtual networks (CAN1 + CAN2) with several simulated ECUs sending decoded signals
live (Powertrain, Chassis, Body, Battery). **Try:**

- Press **Start**; expand a message in **Trace** to see its signals decode.
- Select a message → watch it scroll in **Graphics** (strip chart).
- **Send** `0x101` → the simulated SUT answers with `0x102`.
- **Script** (`ƒ`) → run `tests/diag_basic.lua` (UDS session, read VIN, …).

## Replay — `replay-demo`
Plays a recorded log back at its original cadence onto an in-process bus. **Try:**
Start, watch it loop; monitor the same interface on a second channel to see it arrive
like a real node on the wire.

## Diagnostics
UDS over the simulated bus works driver-free — the **Diagnostics** panel (one-click
Session / Read VIN / Tester Present / free-form RDBI) and the **Script** panel both
drive it.

## Hardware — `hw-crossvendor` (needs adapters)
Kvaser + PCAN on one physical bus. **Bus Config ▸ Discover** enumerates attached
channels (e.g. *Kvaser Leaf Light v2*, *PCAN_USBBUS1/2*); tick to add. Full setup +
the Linux/WSL paths are in `docs/can_hardware.md`.
