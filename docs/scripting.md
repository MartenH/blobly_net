# Blobly Net scripting & test guide

Blobly Net runs **Lua 5.4** test scripts against a CAN setup — diagnostics (UDS),
raw frames, and DBC signal decode/encode. The same script runs two ways:

- **Headless** from the command line (`scripts/runtests.sh`) — for development and CI.
- **In the GUI**, against a live measurement (the **Script** panel).

You don't need anything installed: Lua is compiled into Blobly Net, and the headless
runner brings up a simulated bus + ECU for you (no hardware, no Python, no drivers).

---

## 1. Running scripts from the command line

### Quick start

```sh
# Run the bundled example tests against the simulation demo project:
scripts/runtests.sh tests/diag_basic.lua tests/bus_signals.lua
```

You'll see per-test results and a summary:

```
project: Simulation demo — CAN1 + CAN2  (projects/sim-demo.blobnet)
channel CAN1 (inproc:CAN1): simulating 2 node(s) + 2 UDS target(s)
channel DoIP1 (doip:127.0.0.1:13400): DoIP entity, logical address 0x1000
...
=== tests/diag_basic.lua ===
  ok   default diagnostic session starts
  ok   VIN reads back over multi-frame ISO-TP
  ...
12 passed, 0 failed, 0 script error(s)
```

(the count grows with the suites)

(The runner also prints, on stderr at exit, what each bus or connection it held counted that no
frame carried — dropped, controller-error or undecodable records — and waits up to two seconds
for its bus loops, warning `N bus loop(s) still busy at exit` if one is stuck. Neither is a
failure.)

The runner **exits non-zero if any test fails**, so it drops straight into CI.

### Usage

```sh
scripts/runtests.sh [--project <file.blobnet>] <script.lua> [more.lua ...]
```

- `--project <file.blobnet>` (or `-p`) — the project that defines the bus setup.
  Defaults to `projects/sim-demo.blobnet`. See [§4](#4-projects-and-the-simulation).
- **A script may declare the project it needs** in its leading comment —
  `-- @project ../projects/doip-demo.blobnet`, resolved relative to the script. The declaration
  wins: a `--project` that contradicts it, or two scripts in one invocation declaring different
  projects, is refused rather than run (one run brings up one project).
- One or more `.lua` scripts, run in order. With none named, `scripts/runtests.sh` runs every
  file in `tests/`, one invocation per file — which is what CI does.

Raw form (what the wrapper runs):

```sh
v -enable-globals -path "@vlib|@vmodules|modules" run cmd/script/run.v \
    --project projects/sim-demo.blobnet tests/diag_basic.lua
```

### What the runner does for you

For every **enabled** channel that declares simulated ECUs it starts:

- the **simulated ECUs** (they transmit their cyclic messages and answer requests), and
- their **diagnostic responders** — one per node that configures `uds:`, on that node's own
  ids, or a single built-in server on `0x7E0` → `0x7E8` if none does.

A `type: doip` channel with simulated nodes gets a real DoIP entity bound on its host:port
instead of a bus. A channel without simulated nodes is monitor-only: nothing is started for it,
and it exists for the scripts to open.

So your script has a live bus to talk to — driver-free, entirely in-process. Against
real hardware later, the same scripts run unchanged; only the project's `interface:`
changes.

---

## 2. Writing a Lua script

A script is plain Lua. The Blobly Net API (below) is already loaded — just call it.
The smallest useful script:

```lua
-- hello.lua
local diag = uds.open("CAN1")            -- tester on 0x7E0 / ECU on 0x7E8

test("ECU returns its VIN", function()
  local vin = diag:read_did(0xF190)      -- 0x22 ReadDataByIdentifier
  check.equal(vin, "BLOBLYNETV0SUT001")
  log("VIN =", vin)
end)
```

```sh
scripts/runtests.sh hello.lua
```

`"CAN1"` is a **channel name from the project** — it must match a `name:` under
`channels:` in the project file (see [§4](#4-projects-and-the-simulation)).

---

## 3. API reference

### Tests & assertions

| Call | Meaning |
|---|---|
| `test(name, fn)` | Run `fn` as one test; records pass/fail. Wrap each check in its own `test`. |
| `check.equal(got, want [, msg])` | Fail unless `got == want`. |
| `check.truthy(v [, msg])` | Fail unless `v` is truthy. |
| `check.between(v, lo, hi [, msg])` | Fail unless `lo <= v <= hi`. |
| `check.nrc(code, fn)` | Expect `fn` to raise a UDS **negative response** with NRC `code` (e.g. `0x31`). |

A failing `check` aborts only its own `test`; other tests still run. A Lua error
outside a `test` aborts the script (and the runner reports it).

### Diagnostics — UDS

```lua
local diag = uds.open(channel [, { tx = 0x7E0, rx = 0x7E8 }])   -- CAN / CAN-FD
local diag = uds.open(channel)                                   -- DoIP
```

Opens a UDS tester on `channel`. **The carrier follows the channel**, so the same
script body works over either.

On a **CAN** channel, `tx`/`rx` are the ISO-TP ids (defaults shown). `0` is a valid
arbitration id and is honoured as one — omit the option to get the default, don't
pass zero.

On a **DoIP** channel there are no CAN ids: addressing is the logical pair
configured on the channel (`tester_address` / `ecu_address`). Passing `tx`/`rx`
there is an **error**, not an ignored argument — they cannot be honoured, and
silently dropping them would let a test believe it had addressed something it had
not. A second `uds.open` on the same DoIP channel returns the live connection: an
entity serves one tester connection at a time.

On a DoIP channel the entity's ANNOUNCED identity is a separate value from the one
it serves at DID 0xF190, so both are observable:

```lua
local ann = doip.discover(channel)   -- { vin = "...", logical_address = 0x1000 }
```

A tester that discovers one ECU and reads a different VIN out of it has no way to
tell which is the lie, so a suite should check they agree.

The returned object has:

| Method | UDS service | Returns |
|---|---|---|
| `diag:session(sub)` | `0x10` DiagnosticSessionControl (`sub` defaults `0x01`) | session params (bytes) |
| `diag:read_did(did)` | `0x22` ReadDataByIdentifier | the data record (bytes) |
| `diag:write_did(did, data)` | `0x2E` WriteDataByIdentifier | — |
| `diag:security_access(level [, keyfn])` | `0x27` SecurityAccess (request seed at `level`, send key at `level+1`) | the seed (bytes) |
| `diag:read_dtcs([mask])` | `0x19` sub `0x02` reportDTCByStatusMask (`mask` defaults `0xFF`) | DTC record (bytes) |
| `diag:tester_present()` | `0x3E` | — |
| `diag:raw(req)` | send any request PDU | the response (bytes) |

A negative response **raises a Lua error** (so it aborts the `test`, or is caught by
`check.nrc` — e.g. `check.nrc(0x35, …)` for an invalid security key). Multi-frame
responses (e.g. the 17-byte VIN) are reassembled for you.

`security_access(level, keyfn)`: `keyfn(seed) -> key` defaults to the **simulated
server's** demo algorithm (key = seed XOR 0xFF) so it unlocks the sim out of the box;
pass your own `keyfn` for a real ECU's algorithm.

### Raw frames & signals

```lua
bus.send(channel, id, data [, { ext = false }])   -- send a raw frame
local f = bus.recv(channel [, timeout_ms])          -- receive one frame, or nil on timeout
-- f = { id = <number>, ext = <bool>, data = <byte string> }

bus.send_message(channel, "MsgName", { Sig = value, ... })  -- DBC-encode + send
local sig = decode(channel, id, data [, ext])               -- DBC-decode -> { Name = value, ... }
```

- `data` is a **byte string** (see helpers below), not a list of numbers.
- `bus.send_message` / `decode` use the channel's **DBC** (its `databases:`), looking
  the message up by name (encode) or id (decode). `decode` returns physical values.
- `bus.recv` defaults to a 1000 ms timeout.

### Byte payloads & helpers

CAN/UDS payloads are Lua **byte strings** (8-bit clean). Helpers:

| Helper | Example | Result |
|---|---|---|
| `tohex(s)` | `tohex(vin)` | `"43 41 4E ..."` (space-separated hex) |
| `fromhex(h)` | `fromhex("DE AD BE EF")` | 4-byte string |
| `frombytes(t)` | `frombytes({0xDE, 0xAD})` | 2-byte string |
| `u16be(s [, i])` | `u16be(raw)` | big-endian u16 at byte `i` (default 1) |
| `ascii(s)` | `ascii(vin)` | the string itself (payloads already are strings) |

### Sequences — wait / expect

Linear "wait for an event with a timeout" (a blocking wait-for-event style). These block
the script until the condition or the timeout, then return or raise.

| Call | Meaning |
|---|---|
| `expect(channel, id, timeout_ms)` | Wait for a frame with CAN `id`; returns the frame `{id,ext,data}`, or raises on timeout. |
| `expect_signal(channel, id, signal, want, timeout_ms)` | Wait until decoded `signal` of message `id` matches `want` (a value, or a `function(v)->bool` predicate); returns the matching value, or raises. |

### Reactive callbacks — on_message / on_timer / run

Register handlers, then `run()` a cooperative event loop that pumps the listened
channels and fires due timers. Handlers fire *during* `run()`.

| Call | Meaning |
|---|---|
| `on_message(channel, id, fn)` | `fn(frame)` fires for each matching frame during `run()`. `id` may be `nil` to match every frame on the channel. |
| `on_timer(period_ms, fn)` | `fn()` fires roughly every `period_ms` during `run()`. |
| `run(duration_ms)` | Run the event loop for `duration_ms`, dispatching messages + timers. |

```lua
local hb = 0
on_message("CAN1", 0x700, function(f) hb = hb + 1 end)   -- Heartbeat
on_timer(500, function() log("tick, heartbeats so far:", hb) end)
run(3000)
```

(Lua's own coroutines are available too if you want to hand-roll more elaborate
flows, but `expect` + `on_message`/`run` cover the common test shapes.)

### Logging & timing

| Call | Meaning |
|---|---|
| `log(...)` | Print a line to the output (tab-separated args). |
| `print(...)` | Same as `log` (routed to the Blobly Net output). |
| `sleep_ms(ms)` | Wait `ms` milliseconds. |

Plus the full Lua 5.4 standard library (`string`, `table`, `math`, …).

---

### Also in the prelude

| Function | What it does |
|---|---|
| `sim.fault(channel, node, message, kind [, ms [, signal]])` | inject a fault into a simulated ECU's message — `drop`, `bad_crc`, `freeze_counter`, `out_of_range` (with `signal`), or `clear`; `ms` limits it in time. A fault that cannot take effect (no such node, no protection field for `bad_crc`) is refused, not silently armed. See [simulation.md](simulation.md). |
| `sim.clear_fault(channel, node, message)` | lift it |
| `doip.discover(channel)` | one identification request to the channel's configured endpoint |
| `doip.listen(window_ms [, {port=, ip6=, from=}])` | collect vehicle announcements for a window; each entry names the sender's endpoint. `from=` (listen on that channel's own port) is accepted but currently ignored — [#233](https://github.com/MartenH/blobly_net/issues/233) |

`uds.open` validates its ids (negative or above `0x1FFFFFFF` is an error) and uses 29-bit
addressing for any id above `0x7FF`. The handle it returns exposes `handle` and `channel`.

## 4. Projects and the simulation

Scripts run against a **project** file (`.blobnet`, YAML), which defines the channels. The shipped
`projects/sim-demo.blobnet` declares `CAN1` (and `CAN2`) on a driver-free in-process bus,
each with the `dbc/blobly_net.dbc` database and simulated ECUs, and `DoIP1`, a DoIP endpoint on
127.0.0.1:13400 serving the same identity as `SUT` (which is what `uds.open` over DoIP and
`tests/mixed_carriers.lua` use). That's why the example scripts can read a VIN and decode
`Powertrain` with no hardware.

The channel `name:` in the project is the string you pass to `uds.open` / `bus.*` /
`decode` (e.g. `"CAN1"`). The channel `databases:` provide the DBC used by
`send_message` and `decode`. Full project schema: [project_editing.md](project_editing.md)
and `modules/project`.

To run against **real hardware** later, point a channel's `interface:` at a vendor
adapter (e.g. `pcan:PCAN_USBBUS1`) — the scripts don't change. See
[windows_can_hardware.md](windows_can_hardware.md).

---

## 5. Running from the GUI

The **Script** panel (toggle it from the left activity bar — **Lua** — or **View ▸ Script**)
runs scripts against the **live measurement**:

1. Press **▶ Start** first (the script talks to the running buses/sims).
2. The `.lua` field starts at `tests/diag_basic.lua`; edit it and press **Run**. Output is
   replaced per run; **Copy all** copies it. What the script's own buses and connections
   counted (dropped, controller-error, undecodable records) is appended when it finishes.

Output (per-test results + a pass/fail summary) appears in the panel. Because it uses
the live measurement, the ISO-TP request frames a script sends are visible in the
**Trace**, just like any other traffic.

---

## 6. Worked example

```lua
-- powertrain.lua — runs against projects/sim-demo.blobnet (CAN1)

-- wait up to timeout_ms for a frame with a given id
local function wait_for(channel, want, timeout_ms)
  local left = timeout_ms
  while left > 0 do
    local f = bus.recv(channel, 200)
    if f and f.id == want then return f end
    left = left - 200
  end
end

test("SUT streams Powertrain (0x100)", function()
  local f = wait_for("CAN1", 0x100, 2000)
  check.truthy(f, "no Powertrain frame in 2s")
  local sig = decode("CAN1", f.id, f.data)
  log("EngineSpeed =", sig.EngineSpeed, "rpm")
  check.between(sig.EngineSpeed, 0, 8000)
end)

test("encode round-trips through the DBC", function()
  local m = bus.send_message("CAN1", "Powertrain", { EngineSpeed = 1600, Gear = 4 })
  local sig = decode("CAN1", m.id, m.data)
  check.between(sig.EngineSpeed, 1599, 1601)
  check.equal(sig.Gear, 4)
end)

test("unknown DID is rejected", function()
  local diag = uds.open("CAN1")
  check.nrc(0x31, function() diag:read_did(0xABCD) end)  -- requestOutOfRange
end)
```

```sh
scripts/runtests.sh powertrain.lua
```

---

## 7. Gotchas

- **Payloads are byte strings**, not number arrays — build them with `fromhex` /
  `frombytes`, read them with `string.byte` / `u16be` / `tohex`.
- **Channel names must match the project** file (`.blobnet`); an unknown name is an error.
- **In the GUI, press ▶ Start before Run** — the panel will happily run a script while the
  measurement is stopped, but nothing is hosted: on a CAN channel no simulated ECU transmits or
  answers, so every wait times out; on a DoIP channel no entity is bound, so `uds.open` fails
  at connect.
- Numbers are Lua numbers (`4.0 == 4` is true), so `check.equal(sig.Gear, 4)` works.
- A negative UDS response raises an error — wrap it in `check.nrc`, or let it fail the
  test deliberately.

---

## Appendix — other command-line tools

A selection of the `cmd/` tools (run with
`v -enable-globals -path "@vlib|@vmodules|modules" run cmd/<tool>/<file>.v [args]`). The
hardware bench tools — `silentcheck`, `vectorcheck`, `kvasercheck`, `crosscheck` — are
described in [windows_can_hardware.md](windows_can_hardware.md); `cansub_smoke` has only its
own header comment:

| Tool | What it does |
|---|---|
| `cmd/script` | the script/test runner (this guide; usually via `scripts/runtests.sh`) |
| `cmd/doip_smoke` | drive UDS over DoIP against a local entity, no project needed |
| `cmd/restbus` | replay a recording onto live buses with the ECU under test subtracted |
| `cmd/lua_smoke` | minimal embedded-Lua check (script + host callback) |
| `cmd/uds_smoke` | drive the UDS client against an ECU (`vcan0` or `inproc:CAN1`) |
| `cmd/sim_smoke` | run the native simulated SUT ECU and verify end-to-end |
| `cmd/dbc_decode` | load a DBC and decode one frame |
| `cmd/mf4_dump` | read an ASAM MF4 recording (count / ids / frames) |

The GUI itself is `scripts/run_gui.sh` (see [CLAUDE.md](../CLAUDE.md)).
