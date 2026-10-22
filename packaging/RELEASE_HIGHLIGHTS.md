<!-- v2026.10.01 -->
This release brings Blobly Net to Python:

- 🐍 **New: `pip install blobly`** — the engine in your own Python process, with wheels for Linux x86_64 and Windows x64
- 💬 **DBC messages by name from Python** — `ch.messages.<Message>.send(**signals)` and `ch.decode(frame)`; channels and messages complete in a REPL
- ⏱️ **Event handlers in Python** — `on_message`, `on_timer` and `on_health` under `run()`, which follows the same rules as Lua's
- 🔌 **New: libblobly** — the engine as a shared library with a C ABI (`bb.h`), so any language that can call C can drive it
- 📜 **Lua `run()`** — it reads on the script's own thread, adds `on_health` and `bus.health`, and keeps every handler's frames in order through nested runs and coroutines
- 📁 **Projects open from any folder** — every shipped project names its files relative to itself
- 🐧 **Linux now needs Ubuntu 24.04 or newer** (or a glibc as new as 24.04's) — the tar.gz, the wheel and the WSL bridge are built there; 22.04 is no longer supported
- 📦 **No more AppImage** — on Linux take the tar.gz: `sudo apt install libglfw3 libfreetype6 libgl1`, then `./blobly_net`
