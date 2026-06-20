# CANTester — Quick Start

CANTester is a **conventional** bus tester for automotive **CAN** (Ethernet/LIN later).
It runs **driver-free** out of the box: a built-in simulation, no hardware or Python.

## 60-second tour
1. Press **▶ Start** (top-left). The default project simulates a few ECUs.
2. The **Trace** panel fills with frames, decoded against the DBC.
3. Click a message — it drives the **Signals** and **Graphics** panels.
4. **Send** — pick a DBC message or raw id/data and fire it on the bus.
5. **Generators** — declarative cyclic / key-triggered senders.
6. **Script** (`ƒ`) — run a Lua test against the live bus.

## Panels
Toggle any panel from the **left activity bar** or the **View** menu:

- **Trace / Trace (filter)** — live frames; group by id, expand to signals.
- **Signals / Graphics** — decoded values + strip-chart plots of the selected message.
- **Send / Generators** — manual + automated transmit.
- **Diagnostics / Script** — UDS + Lua scripting.
- **Bus Config** — **Discover** real adapters (Kvaser/PCAN) or add virtual buses.
- **Symbol Browser** — searchable DBC message/signal tree.

## Projects
The whole bus setup lives in a project `.yml` (channels, databases, simulation,
senders). **File ▸ Open Example** loads ready-made ones; **File ▸ New Project** starts
empty — build it up in **Bus Config** (Discover / ＋ Sim net), attach DBCs in **Buses**,
then **Save**.

## Real hardware (Windows)
Install the vendor driver (Kvaser / PEAK), open **Bus Config ▸ Discover**, and tick your
adapter to add it as a channel. Details on the [Examples](examples) page and in
`docs/can_hardware.md`.
