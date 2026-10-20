<!-- v2026.10.00 -->
This release brings a Windows-to-WSL CAN bridge, a Diagnostics panel and native AUTOSAR ARXML:

🌉 **New: CAN bridge** (`canbridge`) — the Windows build reaches WSL's `vcan`s, started from the Discover dialog
🩺 **New: Diagnostics panel** — DTCs with snapshots and extended data, DIDs read and written by the ECU's description, security unlock, and the session copied out as a Lua script
📐 **New: AUTOSAR ARXML** read natively — import a system as channels, export a DBC with `arxml2dbc`
🚚 **New: J1939** — PGN/SA in the trace, transport-protocol messages rejoined, address claims
🛡️ **AUTOSAR E2E Profile 1**, stamped and verified
🔎 **DoIP discovery** and **functional UDS** on CAN and DoIP; **SOME/IP** send and call from Lua
⚡ **Flash from Lua**, and ISO-TP honours Flow Control
