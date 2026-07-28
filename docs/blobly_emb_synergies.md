# blobly_net ↔ blobly_emb — synergies & shared-module assessment

Captured 2026-06-30. `blobly_net` is the **tester** half (analyzer-style:
trace, DBC, sim, diagnostics, DoIP, scripting). `blobly_emb` is the **ECU/SUT**
half — a no-dynamic-allocation V automotive stack (Function Blocks + Loom
scheduler + COM/UDS/ISO-TP/SecOC/E2E/NM, SocketCAN host → ST FDCAN target),
config-driven by `ecu.toml` + a DBC. Same author, same language, same vcan-first
philosophy. They are two halves of one world.

## Synergies, by how real they already are

1. **Already wired — blobly_net IS blobly_emb's integration-test driver.**
   `blobly_emb/scripts/integration-test.sh` runs the example ECU on (v)CAN, then
   drives + asserts it with `blobly_net/cmd/script/run.v --project test/vcan.yml
   test/*.lua`. emb's `diag.lua` uses blobly_net's Lua API (`test`, `check.equal`,
   `uds.open`, `bus.send_message`, `sleep_ms`); `test/vcan.yml` *is* a blobly_net
   project file. **The Lua prelude API + runner CLI are a versioned contract**
   between the repos — drift in blobly_net silently breaks emb's CI.
   → Action: document the contract in both; add a **drift-guard** CI job (blobly_net
   runs one emb example end-to-end) so an API change can't break emb unnoticed.

2. **emb examples = real SUTs for blobly_net.** `overspeed`/`gateway`/`minimal`/
   `scale` are genuine V ECUs — more realistic targets than `can_sut.py` or the
   native sim. Each is the other's oracle (real ECU ↔ real tester).

3. **Complementary diagnostics stacks (not redundant).** emb has the no-alloc
   **UDS + ISO-TP server** (on the ECU); blobly_net has the **client/tester** (+ its
   own sim server). `diag.lua` already proves net's client driving emb's server,
   multi-frame and all. Keep both — they validate each other.

4. **Features emb has that blobly_net could grow tester-side support for:**
   **SecOC** (freshness/MAC), **E2E** (CRC/counter protection), **NM** (network
   management states). blobly_net has none; emb is a ready oracle for each. Natural
   future tester capabilities.

5. **Config kinship.** `ecu.toml` (emb) and `project.blobnet` (net) are both
   config-driven; emb already authors blobly_net project files (`test/vcan.yml`).

## Split modules into shared vmodules?

Rule: extract only when **(a)** ≥2 repos share the *same* code **and** **(b)** the
drift/duplication cost exceeds the versioning overhead.

| Module | Split? | Why |
|--------|--------|-----|
| **`candb`** | **Yes — the one clear case** | emb's `tools/candb/candb.v` and net's `modules/candb/candb.v` are the **same module, forked** (identical `ByteOrder`/`Signal`/`label()`/`raw_value()`/`load_dbc_file()`). Both use it in alloc-OK contexts (net runtime+build; emb's `dbc2cfg` is BUILD-TIME — "heap is fine here, candb never ships to target"). One source of truth for DBC semantics (bit order, mux, value tables) removes a *correctness* drift risk across the very tester/ECU boundary under test. A shared `candb` also subsumes any "DBC cross-validation" test — same code, nothing to diverge. |
| `lua` | Maybe (low priority) | Clean, reusable V↔Lua 5.4 facade; only net consumes it today. Extract only if reuse is foreseen. |
| `uds`, `isotp` | **No** | emb's are **no-alloc runtime** (`[max_dids]Did`, `&u8`); net's are dynamic. Different implementations under different constraints — oracle pairs, not merge candidates. |
| `transport` | No | emb has `driver/can` (no-alloc, different abstraction). |
| `doip`, `canlog`, `mf4`, `player`, `sim`, `script` | No | net-only; no second consumer. |

**Mechanism / cost for `candb`:** a shared module repo (e.g. `blobly_candb`) pinned
via `v.mod` git dependency in both, or a git **subtree/submodule** (pragmatic middle
ground), or — lightest — keep the fork + a drift-alarm cross-validation test. The
release dance is real, but for `candb` the alternative (tester and ECU silently
disagreeing on what a signal *means*) is worse, so it's worth it. Everything else
stays in-repo.

**Status:** analysis only — no extraction performed (deferred by decision).
