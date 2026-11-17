<!-- v2026.11.00 -->
This release builds the rest bus from your database as the database declares it, adds LIN, and opens almost the whole engine to Python and Lua:

- 🚗 **Rest bus from the DBC, as declared** — simulated nodes start each signal at its `GenSigStartValue`, send event and mixed messages on change, keep start delays and each message's CAN-FD format, announce their CanNm PDU, and send long J1939 messages (BAM and RTS/CTS). The new guide `docs/rest_bus.md` comes with a runnable `projects/restbus-db.blobnet`
- 🐍 **Python reaches nearly everything** — UDS over CAN and DoIP (DTCs, functional addressing, routines, I/O control, memory, raw ISO-TP, keep-alive), flash, SOME/IP, J1939, NM, replay and recording, generators, background cyclic senders, fault injection, E2E, and ECU nodes and DIDs by name. Most of it is in Lua too
- 🧪 **pytest plugin** — `pytest_plugins = ["blobly.pytest_plugin"]` gives you a started project and a fixture per channel; `expect` / `expect_signal` wait with one deadline, and Ctrl-C ends any wait
- 🔗 **New: LIN** — LDF files, LIN buses as project rows, serial adapters and ptys on Linux, View ▸ LIN, LIN frames in the trace, and `lin.*` from Lua, C and Python
- 🔐 **UDS 0x29 authentication** from Lua, C and Python, plus 29-bit diagnostic addressing as blobly_emb uses it
- 📖 **Diagnostic nodes from ODX / PDX** — name a CAN node by its ODX description, then read and write its DIDs (scaled values included) and its DTCs by name
- 🛡️ **E2E Profile 5 and protection windows** — signal groups in one frame, each with its own CRC, counter and Data ID
- 📶 **Network Management panel** — who reports in on each CAN NM cluster, and who keeps the network awake
- 🌐 **CAN bridge on the LAN** — another host or a board can dial in (`BLOBLY_BRIDGE_LISTEN`), using a documented protocol; `canbridge` is now static, so it also runs on older WSL distributions
- 📂 **ExtractEditor (E3) projects** — open an `.e3proj` and its ARXML files become your channels
- 🎞️ **Large `.mf4` recordings stream from disk** when you replay them, from the GUI, `restbus` and scripts
- 🧾 **Misspelt keys get reported** — every load names unknown project keys and DBC records it skips; `--strict` / `Project(..., strict=True)` refuses them. A run can also attach a row to another interface at load, by row name (`--interface CAN1=vcan0`, `Project(..., interfaces=...)`, the pytest plugin's `--blobly-interface`)
- ⚡ **Faster release binaries** — built with C optimisation (`-O2`); macOS on Apple Silicon now builds from source (no bundle yet)
- ⚠️ **Project files: schema v9 → v14.** A project that uses a new feature (LIN rows, `fill:`, NM announcements, generator `format:`, Profile 5, E2E windows, ODX `diagnostics:`, a data-phase sample point…) is saved at the version that feature needs. An older build opens it with a "file format is newer than this app" warning and ignores what it does not know (it reads a LIN row as a CAN channel), and a structured Save from that build drops those settings. Projects that use none of these keep their old version
- ⚠️ **CAN bridge protocol v3.** A bridge that speaks only v2 (the `canbridge` of v2026.10.01 or earlier) cannot connect; use the `canbridge` from this release. No wire format shared with blobly_emb changed
