# Blobly Net scripting & test guide

Blobly Net runs **Lua 5.4** test scripts against a CAN setup — diagnostics (UDS),
raw frames, and DBC signal decode/encode. The same script runs two ways:

- **Headless** from the command line (`scripts/runtests.sh`) — for development and CI.
- **In the GUI**, against a live measurement (the **Script** panel).

You don't need anything installed: Lua is compiled into Blobly Net, and the headless
runner brings up a simulated bus + ECU for you (no hardware, no Python, no drivers).

To drive the engine from Python instead (`pip install blobly`), see
[scripting_python.md](scripting_python.md).

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
DoIP1: DoIP 127.0.0.1:13400 -> 127.0.0.1:30178 for this run
channel CAN1 (inproc:CAN1): simulating 2 node(s) + 2 UDS target(s)
channel DoIP1 (doip:127.0.0.1:30178): DoIP entity, logical address 0x1000
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

The runner **exits non-zero if any test fails**, so it drops straight into CI; its exit
statuses and its `--report` file are [below](#exit-status-and-the-run-report).

### Usage

```sh
scripts/runtests.sh [--project <file.blobnet>] [--project-ports] [--report <file.json>]
                    [--timeout <s>] <script.lua> [more.lua ...]
```

- `--project <file.blobnet>` (or `-p`) — the project that defines the bus setup.
  Defaults to `projects/sim-demo.blobnet`. See [§4](#4-projects-and-the-simulation).
- **A script may declare the project it needs** in its leading comment —
  `-- @project ../projects/doip-demo.blobnet`, resolved relative to the script (an absolute path is taken as written). The declaration
  wins: a `--project` that contradicts it, or two scripts in one invocation declaring different
  projects, is refused rather than run (one run brings up one project).
- **Simulated DoIP entities move to a free port for the run** (#411). Every entity the project
  hosts on a loopback address leaves the project's port (13400 in the demos) for the first port
  in 30000..31999 this run can bind, and every DoIP channel dialing that entity moves with it; the
  runner prints each move (`DoIP1: DoIP 127.0.0.1:13400 -> 127.0.0.1:30178 for this run`). So two
  runs on one machine do not collide. A channel dialing an entity this run does not host — a real
  ECU, or a loopback one something else serves — keeps its port, and so does an entity on a NIC
  address. `doip.listen` without `from` still listens on 13400, which no moved entity announces
  to: name the channel (`{ from = "DoIP1" }`). `--project-ports` keeps the project's ports, for
  a tool outside the run that dials the entity where the project says it is.
- `--report <file.json>` — write the run's result as JSON ([below](#exit-status-and-the-run-report)).
- `--timeout <s>` — end the run this many seconds after its scripts start (exit 4); up to 1000000.
- One or more `.lua` scripts, run in order. With none named, `scripts/runtests.sh` runs every
  file in `tests/`, one invocation per file — which is what CI does. Then `--report` names a
  directory, which gets one `<suite>.json` per file, and `--timeout` bounds each file.

Raw form (what the wrapper runs):

```sh
v -enable-globals run cmd/script/run.v \
    --project projects/sim-demo.blobnet tests/diag_basic.lua
```

### Exit status and the run report

| exit | `status` | meaning |
|---|---|---|
| 0 | `passed` | every test passed |
| 1 | `failed` | a test failed |
| 2 | `refused` | bad arguments, or a project that cannot be loaded or started; nothing ran |
| 3 | `error` | a script raised outside any `test()`, or could not be loaded |
| 4 | `timeout` | `--timeout` passed |

The first that applies wins, in the order refused, timeout, error, failed. `--report` writes the
same verdict and the detail behind it, schema 1 (a field is only ever added):

```json
{
  "schema": 1,
  "status": "failed",
  "exit_code": 1,
  "message": "",
  "project": "projects/sim-demo.blobnet",
  "duration_ms": 245.5,
  "counts": { "passed": 1, "failed": 1, "timed_out": 0, "script_errors": 0 },
  "tests": [
    { "name": "passes", "script": "tests/runner/fail.lua", "status": "passed",
      "message": "", "line": 0, "duration_ms": 0 },
    { "name": "fails", "script": "tests/runner/fail.lua", "status": "failed",
      "message": "tests/runner/fail.lua:7: one is two: got 1, want 2", "line": 7, "duration_ms": 0.1 }
  ],
  "script_errors": [],
  "diagnostics": {}
}
```

- `tests[]`: one per `test()`, in the order they ran. `status` is `passed`, `failed` or
  `timeout`; `line` is the line of the test's own script the failure was raised at (the
  innermost frame in that file, so a helper function's line when the helper raised), 0 when
  none is known; `duration_ms` is the test's wall time.
- `script_errors[]`: `{script, message}` for each script that raised outside a `test()`.
- `message`: why the run was refused, or that a timed-out run was exited by the watchdog (below);
  `""` otherwise.
- `timeout`, present only when the run timed out: `{after_s, script, test}`, the test that was
  running (`""` if the script was outside any test). The tests after it, and the scripts after
  that one, do not run.
- `diagnostics`: what each bus or connection the scripts held counted that no frame carried, by
  name, as the runner prints at exit — `{dropped, bus_errors, decode_errors}`; only the
  non-empty ones.

**How a timeout ends a run.** Lua code is stopped between instructions, so a loop that never
yields ends at the deadline, and `pcall` cannot catch it for good; no `test()` starts after it; a wait — `sleep_ms`, `bus.recv`, `expect`, `run()`, a `doip.listen`,
`someip.listen` or `uds.functional` window, a `someip.call` or `doip.discover` — is cut to what is left (a wait for ever included);
a UDS request, `flash.program` included, is abandoned in its carrier's wait or between its
answers. A DoIP connection being opened (at most 7 s) finishes its own bounded wait first. Then the project is stopped
and every bus closed as on any other exit, and the report is written. What the deadline cannot
reach — a Lua finalizer, a script that replaced the debug hook — is ended by a watchdog 10 s after
the deadline (longer than a DoIP open): exit 4 again, with a report that has no tests and says so in `message`.

### What the runner does for you

For every **enabled** channel that declares simulated ECUs it starts:

- the **simulated ECUs** (they transmit their cyclic messages and answer requests), and
- their **diagnostic responders** — one per node that configures `uds:`, on that node's own
  ids, or a single built-in server on `0x7E0` → `0x7E8` if none does.

and every **cyclic generator** (`senders:` with `trigger: cyclic`), sent as the GUI sends it
during a measurement. Every generator, cyclic or not, is then the script's to drive
([Generators](#generators)).

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
| `check.dtc(diag, name[, want])` | Expect the server to support DTC `name` (`"U0121-00"`) with each status bit `want` names at its value, e.g. `{ confirmedDTC = true, testFailed = false }`. Read with `0x19 0A`. Returns the record. |
| `check.snapshot(diag, name[, want])` | Expect DTC `name` to hold a snapshot (`0x19 04`) and each DID `want` names to have been captured with the value it gives (bytes; `true` = only present), e.g. `{ [0xF1A0] = fromhex("00 00 00 2A") }`. Returns the snapshot. |
| `check.extended(diag, name, want)` | Expect DTC `name`s extended data (`0x19 06`) to carry the counters `want` gives — `occurrence`, `aging`, `failed_cycles` — or, by record number, the bytes. Returns the answer. |
| `check.nrc(code, fn)` | Expect `fn` to raise a UDS **negative response** with NRC `code` (e.g. `0x31`). |
| `check.e2e(frame [, msg])` | Fail unless the received `frame` passed its E2E check (`frame.e2e == "ok"`), naming the verdict, or saying its message has no E2E. Returns the frame: `check.e2e(expect("CAN1", 0x301, 500))`. See [E2E on what a script reads and sends](#e2e-on-what-a-script-reads-and-sends). |

A failing `check` aborts only its own `test`; other tests still run. A Lua error
outside a `test` aborts the script (and the runner reports it).

### Diagnostics — UDS

```lua
local diag = uds.open(channel [, { tx = 0x7E0, rx = 0x7E8 }])   -- CAN / CAN-FD
local diag = uds.open(channel)                                   -- DoIP
local diag = uds.open(channel, { timeout_ms = 300 })            -- with its waits stated
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

**Timing and stale answers.** The first answer to a request is awaited for 1 s, or the
server's P2 plus 1 s if a session answer named a longer one. After a `0x78`
responsePending the next is awaited for the server's P2* plus 1 s (P2* is 5 s until a
session answer — through `diag:session()` or `diag:raw()` — names another; the extra second
covers reassembling a large multi-frame answer, since P2* bounds only its start), and no
request waits more than 120 s from its send in all. A response that answers a DIFFERENT request —
another service's refusal, another DID's data, typically a duplicate of the previous answer
received twice after a bus error — is discarded and the wait goes on, and on CAN and DoIP alike
whatever is already queued when a request goes out is drained first; an error that follows
says how many were discarded.

Those waits are the connection's, in ms: `timeout_ms` (the first answer), `p2_star_ms` (the
server's P2*), `margin_ms` (added to it) and `pending_budget_ms` (one request from its send).
`diag:timing()` reads them as they stand, a session answer's adoption included;
`diag:set_timing({ margin_ms = 200 })` states the ones the table names from the next request on,
and `uds.open` takes them among its options (checked before it opens anything). `timeout_ms` and `pending_budget_ms` are 1 to 3600000,
`p2_star_ms` and `margin_ms` 0 to 3600000; anything else raises and changes nothing. A session
answer still adopts its P2* over one stated, and lengthens `timeout_ms` where its P2 needs more. On
a DoIP channel `uds.open` hands back the channel's one connection, so its options and
`set_timing` apply to every handle of it; a reconnect keeps them (P2* only where it loosens the new
connection's).

On a DoIP channel the entity's ANNOUNCED identity is a separate value from the one
it serves at DID 0xF190, so both are observable:

```lua
local ann = doip.discover(channel)   -- { vin = "...", logical_address = 0x1000 }
```

A tester that discovers one ECU and reads a different VIN out of it has no way to
tell which is the lie, so a suite should check they agree.

A DoIP entity may be a gateway to nodes behind it (ISO 13400-2 routing). `diag:retarget(address)`
moves the connection's requests, and the answers it takes, to that node's logical address;
`diag:retarget()` goes back to the channel's `ecu_address`. One connection, so what the tester
unlocked on the gateway there holds for the node (blobly_emb's sysnode routes only for such a
tester): unlock the gateway, then retarget. Every handle of the channel's connection moves with it,
and a reconnect keeps the target but not the gateway's unlock. Another target is another ECU: the
connection's waits go back to what the script set, without what a session answer of the old target
adopted, and the snapshot DID sizes it learned are forgotten (`did_size`'s are kept). A retarget
inside a `security_access` keyfn sends no key (it raises), since the key answers the old target's
seed. On a CAN channel it raises.

The returned object has:

| Method | UDS service | Returns |
|---|---|---|
| `diag:session(sub)` | `0x10` DiagnosticSessionControl (`sub` defaults `0x01`) | session params (bytes) |
| `diag:read_did(did)` | `0x22` ReadDataByIdentifier | the data record (bytes) |
| `diag:write_did(did, data)` | `0x2E` WriteDataByIdentifier | — |
| `diag:security_access(level [, keyfn])` | `0x27` SecurityAccess (request seed at `level`, send key at `level+1`) | the seed (bytes) |
| `diag:read_dtcs([mask])` | `0x19` sub `0x02` reportDTCByStatusMask (`mask` defaults `0xFF`) | DTC record (bytes) |
| `diag:dtcs([mask])` | `0x19 02` decoded (`mask` defaults `0xFF`) | array of records: `code`, `name` (`"U0121-00"`), `status`, and one boolean per ISO 14229-1 status bit — `testFailed`, `testFailedThisOperationCycle`, `pendingDTC`, `confirmedDTC`, `testNotCompletedSinceLastClear`, `testFailedSinceLastClear`, `testNotCompletedThisOperationCycle`, `warningIndicatorRequested` |
| `diag:supported_dtcs()` | `0x19 0A` reportSupportedDTC — every DTC with its whole status | array of records, as `dtcs` |
| `diag:dtc_count([mask])` | `0x19 01` reportNumberOfDTCByStatusMask | integer |
| `diag:snapshot_ids()` | `0x19 03` reportDTCSnapshotIdentification | array of `{code, name, record}` |
| `diag:snapshot(dtc[, record])` | `0x19 04` reportDTCSnapshotRecordByDTCNumber — `dtc` a name or its code, `record` default `0xFF` (all). A snapshot DID whose size the tester does not know is read once (`0x22`) to learn it | `{code, name, status, <status bits>, records = { {number, dids = { {id, data} } } } }` |
| `diag:extended(dtc[, record])` | `0x19 06` reportDTCExtDataRecordByDTCNumber, sized by blobly_emb's records (`0x01` occurrences 2 B, `0x02` aging, `0x03` failed cycles) | `{code, name, status, <status bits>, occurrence, aging, failed_cycles, records = {[n] = bytes}}` |
| `diag:did_size(did, n)` / `diag:ext_record_size(record, n)` | the sizes a `0x19 04` / `06` answer does not carry: a snapshot DID the tester cannot read (or whose size varies), an extended data record other than blobly_emb's | — |
| `diag:tester_present()` | `0x3E` | — |
| `diag:reset([kind])` | `0x11` ECUReset (`1` hard — the default, `2` key-off-on, `3` soft) | the answer after its SID (bytes) |
| `diag:comm_control(control [, type])` | `0x28` CommunicationControl (`control` 0 enable rx+tx … 3 disable both; `type` defaults `1`, the normal messages) — the simulated ECUs refuse it (serviceNotSupported): they cannot gate their own traffic | — |
| `diag:dtc_setting(on)` | `0x85` ControlDTCSetting (`true` on, `false` off) | — |
| `diag:clear_dtcs([group])` | `0x14` ClearDiagnosticInformation (one DTC, or a group; defaults `0xFFFFFF`, all) | — |
| `diag:raw(req)` | send any request PDU | the response (bytes) |
| `diag:close()` | let the connection go: the handle refuses from then on, and the next `uds.open` on the channel opens a new one (a DoIP entity serves one connection at a time) | — |
| `diag:raw_suppressed(req)` | send a sub-function request with suppress-positive-response set: no positive answer is expected, a refusal raises, and a server that said `0x78` owes its final answer | `true` if a positive answer came anyway |
| `diag:timing()` / `diag:set_timing(t)` | the connection's waits (`timeout_ms`, `p2_star_ms`, `margin_ms`, `pending_budget_ms`), read as they stand / stated where `t` names them | a table / — |
| `diag:retarget([address])` | DoIP: the requests go to logical address `address`, a node behind the gateway (`nil`: the channel's `ecu_address`) | — |

A negative response **raises a Lua error** (so it aborts the `test`, or is caught by
`check.nrc` — e.g. `check.nrc(0x35, …)` for an invalid security key). Multi-frame
responses (e.g. the 17-byte VIN) are reassembled for you.

`security_access(level, keyfn)`: `keyfn(seed) -> key` defaults to the **simulated
server's** demo algorithm (key = seed XOR 0xFF) so it unlocks the sim out of the box;
pass your own `keyfn` for a real ECU's algorithm. An all-zero seed (already unlocked) is returned
without sending a key. `level` is the seed SUB-FUNCTION (`2L-1` for
level `L`). Levels, the reference key and the NRCs: [security_access.md](security_access.md).

**Functional addressing** — one request to several ECUs at once (CAN), or to the functional
address of a DoIP entity:

```lua
local dom = uds.open("compute", { tx = 0x7B0, rx = 0x7B8 })
local gw  = uds.open("compute", { tx = 0x7A0, rx = 0x7A8 })
local rs = uds.functional("compute", 0x7DF, { dom, gw }, "\x22\xF1\x90" [, window_ms])
-- rs[i] answers for the i-th connection: { outcome, resp, nrc, pended, err }
```

The request goes out **once**, as a Single Frame on the functional id (at most 7 bytes: a
functional request cannot be segmented). Each ECU answers on its own physical response id, and a
multi-frame answer is reassembled on that connection, its Flow Control going to that ECU's physical
request id. Several ECUs may answer multi-frame to one request; their transfers are reassembled one
after another, so a second ECU's Flow Control waits for the first transfer to end, which takes
milliseconds for an ordinary answer. `outcome` is one of:

- `"positive"` / `"negative"` (`nrc` set);
- `"silent"`: nothing within `window_ms` (default 1000). That is normal for a functional request,
  since ISO 14229-1 has servers suppress NRCs 0x11/0x12/0x31/0x7E/0x7F to one, and it is what a
  suppressed positive response (`"\x3E\x80"`) looks like;
- `"pending"`: `0x78`, then nothing within that ECU's P2*;
- `"failed"`: malformed, or the transfer broke (`err`).

`pended` says a `0x78` came first. What an ECU answers is reported, never raised. The call raises
when it cannot run at all: a request it cannot send, a bus that will not open or fails while
listening, or a target whose response id is flooding (the same refusal a physical request makes). Simulated ECUs answer it when their `uds:` block
names a `functional:` id (`docs/simulation.md`; `projects/sim-demo.blobnet`, `tests/diag_functional.lua`).
Bench-verified against blobly_emb's `system_full` too.

On a **DoIP** channel the id is a functional *logical address* (`nil` = 0xE400) and `diags` is the
channel's one connection — a TCP connection is routed to one entity, so there is one reply:

```lua
local diag = uds.open("DoIP1")
local rs = uds.functional("DoIP1", nil, { diag }, "\x22\xF1\x90" [, window_ms])
```

The request goes out on that connection with the functional address as its target, of any length
(DoIP frames it whole), and the entity's answer — from its own address — is read under the same
outcomes, `answer_to` and P2* rules as above (`uds.functional_addressed`). An address the entity
does not answer is `"failed"` (a DoIP negative ack), not `"silent"`; the connection lost under the
request raises, as a bus failing while listening does. A simulated DoIP entity
answers 0xE400 (`tests/diag_doip_functional.lua`); see `docs/doip.md`.

### Nodes — a target by name, its DIDs by name

A project described by blobly_emb's `system.toml` (beside the project, beside one of its
databases, or in its folder's parent — the one the Diagnostics panel and the simulated servers
read) names its **nodes**, and each node's `ecu.toml` lays out its DIDs. A script then names the
node and the DID, and the model supplies the rest:

```lua
local names = uds.nodes()                    -- { "zone_a" }: the system model's nodes, in order
local d = uds.node("zone_a" [, { channel = "edge" }])
d:session(0x03)
d:security_access(1)                         -- what SteerLimit's write gate needs
d:write("SteerLimit", 300)                   -- encoded by its layout: a u16, 0..360
check.equal(d:read("SteerLimit"), 300)
check.equal(d:read("parameter status").SteerLimit, 1)   -- coded
```

`uds.node(name [, opts])` opens a `uds.open` connection on the channel and at the ids the system
gives the node: a CAN channel **named after the bus its diagnostic server is on**, at its `diag =
{ req, rsp }` ids (else its ecu.toml's `[isotp]`), or a DoIP channel whose `ecu_address` is its
entity's logical address. `opts.channel` names the channel when the node is reached on several.
A node the project reaches nowhere is refused with how it is reached (`zone_a is reached on no
enabled row of the project: it is reached at 0x7C0/0x7C8 on a CAN row named edge`). Everything a
`uds.open` connection has is there, plus:

| Method | What | Returns |
|---|---|---|
| `d.node` | the node's name | string |
| `d:dids()` | its DIDs: those its ecu.toml declares, then the ISO identification DIDs it does not | array of `{id, name, kind, size, by_label, parts = { {label, kind, hint} }, read, write}` — `kind` `"ascii"`, `"bytes"`, `"signal"`, `"param"`, `"param_status"`, `"tx_saturations"` or `"unknown"` (no layout: bytes); `size` nil when not known; a part's `kind` `"int"`, `"bool"`, `"text"` or `"bytes"` and its `hint` what it accepts (`"u16 0..360"`); `read` / `write` the gate `{sessions, level}`, nil where none is declared (`write` nil: not writable) |
| `d:did(did)` | one DID: `did` its name (a string: `"SteerLimit"`, ISO's `"ECU serial number"`) or its identifier (a number: `0x0110`) | as `dids` |
| `d:read(did)` | `0x22`, decoded by the layout | its one part's value (an integer, a boolean, a string for a text, bytes), or a table by part label when `by_label` (several fields, or a parameter status, whose parts are its parameters) |
| `d:write(did, value)` | `0x2E`, encoded by the layout; `value` as `read` returns it | — |
| `d:dtcs()`, `d:supported_dtcs()`, `d:snapshot_ids()`, `d:snapshot(...)`, `d:extended(...)` | as on `uds.open`, each record also carrying `fault`, the name of its `[[fault]]` (nil for a DTC the description does not declare) | |

**A write is refused, nothing sent,** when the layout does not hold the value (`deg: 400 is
outside 0..360`), when the DID has no write gate (`not writable`), and when this connection has
not established what the gate needs — the session it is written in and the security level —
which **its own exchanges** say: a positive `0x10` sets the session and relocks, a granted `0x27`
unlocks its level, a `0x2E` refused with `0x7F` / `0x33` forgets them. The error says what is
missing (`... needs it to switch to the extended session (0x10 03), then unlock level 1 (0x27
01/02) first`); `d:session()` and `d:security_access()` establish it — nothing switches or
unlocks on its own. A snapshot DID's size is the description's, so `d:snapshot` does not read the
DID to learn it. `tests/diag_nodes.lua` runs all of it against the described zone_a of
`projects/described-ecu-demo`.

### Raw ISO-TP

```lua
local tp = isotp.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })
tp:send("\x22\xF1")                 -- a request the UDS helpers would never build
local answer = tp:recv(1000)         -- "\x7F\x22\x13", or nil when nothing came in time
tp:close()
```

Whole messages on a CAN channel's id pair, segmented and reassembled by the ISO-TP a `uds.open`
connection rides, with no UDS on top: a protocol of your own over ISO-TP, or a malformed UDS request
and the bytes that come back. Both ids are needed (there is no default pair), and either past
0x7FF makes both 29-bit; a DoIP or SOME/IP channel raises. A message is 1 to 4095 bytes in 8-byte
frames, sent FD on a channel the project declares CAN-FD. `tp:send(data)` returns once the message is on the wire, a long one after the
receiver's Flow Control (1000 ms each, N_Bs; it raises when none came). `tp:recv(timeout_ms)`
(default 1000; `0` only looks) returns the next whole message, or `nil` when none came in time; a
transfer begun is kept for the next `recv`, until 1000 ms pass with no Consecutive Frame, which
raises. A send on a listen-only channel raises. Open one per id pair: two on one `rx` (a `uds.open`
connection on it included) each answer a First Frame with a Flow Control of their own.
`tests/isotp_timing.lua` is the suite.

### E2E on what a script reads and sends

Every frame a script reads (`bus.recv`, `expect`, an `on_message` handler) carries **`e2e`**, its
E2E verdict, wherever its message has E2E on the channel: the channel's `verify:` entry for it,
else what its DBC declares (`E2ECounterSignal`, `E2ECrcSignal`, `E2EProfile`, `E2EDataId`:
[dbc_attributes.md](dbc_attributes.md)). The check is the one the trace's `verify:` runs
(`sim.Verifier`).

| `f.e2e` | the frame |
|---|---|
| `"ok"` | its CRC matches its bytes, and its counter is the next one |
| `"bad_crc"` | its CRC does not match its bytes |
| `"repeated"` | its counter repeated the previous frame's: no new data |
| `"skipped"` | its counter jumped (frames lost, or the sender restarted), or holds a value the profile never sends (Profile 1's 15) |
| `"truncated"` | it is shorter than its message, so its E2E fields are not all there |
| `"timeout"` | it came later than its message's `E2ETimeout` after the last valid frame (its CRC right, its counter new: not a repeat, nor a value the profile never sends) |
| `nil` | its message has no E2E here, or it is a remote frame |

- The counter is judged against the frame of that id the script's handle read before it (the
  first one read is judged on its CRC alone), so a frame lost before reaching the script makes
  the next one a skip, as it would for any receiver; so does the first good frame after a run of
  `bad_crc` ones, whose counters were not trusted.
- `"timeout"` is measured between the stamps the bus gave the frames (SocketCAN's kernel stamp,
  the CAN bridge's clock). A frame with no stamp, whose time is when it was read (`inproc:`,
  `udp:`, and the vendor adapters until they read their stamps), is never late, because a script
  that paused would read as a sender that stopped; and a valid one ends the gap being measured.
- **`bus.send_message` stamps the declared E2E**: the counter the next of this run's sends of that
  message, from 0, then the CRC — over whatever `sigs` gave those two signals — as a simulated
  sender stamps it. A declaration that cannot be applied (an unknown profile, a CRC signal that is
  not one byte) raises rather than go out unprotected, and a send that fails after its stamp has
  used its counter, as a frame lost on the wire does.
  `bus.send_message(channel, name, sigs, { e2e = false })` sends it as encoded, its counter and
  CRC as `sigs` gave them (raw 0 otherwise); `sim.fault` breaks a simulated sender's protection
  instead.
- A simulated node's `protect:` entry is that sender's own word, not a contract a receiver holds it
  to: a message only a `protect:` entry protects is not judged (a `verify:` entry judges it), and
  one that deviates from the declaration on purpose (a wrong Data ID, to test a receiver's
  rejection path) reads as a receiver would read it: `bad_crc`.

```lua
check.e2e(expect("CAN1", 0x301, 500))                    -- passes, or fails naming the verdict
sim.fault("CAN1", "Chassis", "BrakeStatus", "bad_crc")
local f = expect("CAN1", 0x301, 500)                     -- f.e2e == "bad_crc" once it lands
bus.send_message("CAN1", "BrakeCommand", { Demand = 300 })               -- stamped
bus.send_message("CAN1", "BrakeCommand", { Demand = 300 }, { e2e = false })  -- as encoded
```

`tests/e2e_verify.lua` runs this against `projects/e2e-demo.blobnet`, whose DBC declares two
protected messages.

### End-to-end protection for frames you build (AUTOSAR E2E Profile 1)

```lua
local f = e2e.p01_protect(fromhex("E8 03 5A 00 00 00"), 0x44, 4, 5, counter [, "alt"])
local crc = e2e.p01_crc(frame, 0x44, 4, 5 [, mode])   -- the CRC byte for a frame as it stands
```

For a script that builds a protected frame itself (a simulated sender stamps its own):
`p01_protect` writes the counter (0..14) into the low nibble of `counter_pos` and stamps the CRC.
The CRC is the simulation's own Profile 1 (`sim.p01_crc_bytes`), pinned to an independent
implementation. Positions are 0-based bytes, as blobly_emb's `[[frame]].e2e` writes them. `mode`
is `both` (default), `low` or `alt`. A counter of 15, a Data ID wider than 16 bits, or positions
outside the frame raise.

### Flashing through a bootloader

```lua
local r = flash.program("compute", { image = "../build/domain.img", tx = 0x7B0, rx = 0x7B8 })
-- or over the connection a handoff was made on:
local d = uds.open("edge", { tx = 0x7C0, rx = 0x7C8 })
d:session(0x02)                      -- the application hands over to its bootloader
flash.program(d, { image = "zone_a.img", progress = function(done, total) log(done .. "/" .. total) end })
```

The download session against a blobly_emb bootloader — 0x10 02, 0x29 challenge/response, 0x31
FF00 erase, 0x34 / 0x36 ... / 0x37, 0x31 FF01 check (the boot marks the image valid only after its
own CRC passes), 0x11 reset — run by `blobly/flash`, the same code as `cmd/flash` and the GUI's
Flash panel. The first argument is a channel name, opened on `tx`/`rx` (default 0x7B0/0x7B8, as
`cmd/flash`), or a `uds.open` connection, whose ids are used. The channel is reached exactly as
`uds.open` reaches it: on a channel the project declares CAN-FD, the frames go out FD with
classic-sized ISO-TP.

| option | meaning |
|---|---|
| `image` | the image path, **relative to the script** (an absolute path as written). A raw `.bin` gets its header here; a wrapped `.img` (starts `BLBT`) goes as it is |
| `base` | the slot address, default 0x08020000 |
| `sw_version` | written into a raw image's header, default 1 |
| `seed` / `seed_file` | the 0x29 tester seed: 64 hex characters, or a file holding them (relative to the script, like `examples/keys/tester.seed`). Default `$BLOBLY_FLASH_SEED`, else the dev seed — as `cmd/flash`. A malformed seed raises; it never falls back to the dev key |
| `auth` | `false` to skip 0x29 (a boot with no key baked) |
| `progress` | `function(done, total)` in blocks, called once per whole percent (at most 101 calls). Without it a `flash: transfer ...` line is logged per tenth |
| `quiet` | `true`: no `flash: ...` lines at all |

Returns `{ bytes, blocks, wrapped, auth, reset_acknowledged }` — `auth` is `"authenticated"`,
`"not required"` (the boot refused the challenge with 0x22/0x11: no key baked) or `"skipped"`;
`reset_acknowledged` is false when the 0x11 answer was lost to the reset, which is normal. A failed
step raises with the step named — `send proof: NRC 0x35` (wrong key; nothing was erased),
`erase: NRC 0x22`, `image check FAILED on the ECU — not marked valid`. A cut transfer is safe: the
boot refuses an unmarked image, and a re-run recovers. A progress callback that raises stops the
transfer there, before the check — the image is not marked valid — and `flash.program` raises with
its error. Flashing a channel by name twice on the same ids reuses the first call's connection.

### Replay and recording

```lua
local r = replay.start("REPLAY1", { speed = 4, loop = false })   -- the row's replay: block decides the rest
r:wait_done(5000)                                -- true once it ran out
local rec = record.start("CAN1", "capture.log")   -- relative to the script
-- ... traffic ...
local c = rec:stop()                              -- { frames, ours, theirs, missed, dropped }
```

`replay.start(channels, opts)` plays a recording onto one channel, or a list of them on one clock,
through `blobly/player` — the player, rest-bus subtraction and command protocol the GUI's Replay
panel uses. What `opts` leave out, the rows' `replay:` blocks say:

| option | meaning |
|---|---|
| `source` | the recording, a candump `.log` or an `.mf4`, **relative to the script** |
| `speed` | the rate, above 0 |
| `loop` | whether the end starts it again |
| `paused` | `true`: start paused at the beginning |
| `exclude` | a list of nodes subtracted by DBC sender, in place of each row's own |
| `bus` | the recorded bus, for one channel, where the recording holds several |

A request that would play something other than asked raises: no source, a recorded bus that does
not resolve, an exclusion no channel's database declares, two channels on one wire, nothing left
after the subtraction, rows disagreeing about a source, speed or loop the options do not settle.
`r.notes` says what the plan kept and withheld per channel. `r:pause()`, `r:resume()`, `r:seek(s)`
(seconds into the recording), `r:speed(x)` and `r:loop(on)` are applied before they return.
`r:status()` is `{ state, position, duration, speed, loop, passes, sent, failed, error, ended }`,
`state` one of `playing`, `paused` and `finished` (a non-looping replay ran out), `ended` true once
it is stopped. `r:wait_done(ms)` (default 10000, negative for ever) is true once it finished or was
stopped. `r:stop()` stops it and returns its last status; its controls then raise and `r:status()`
still says what it did. A replay sends through handles of its own, not the channel's: its frames
reach the channel's handle as any other node's do, so `bus.load` counts them as they are read. The end of each script stops whatever it left playing or recording. In the
GUI a script's replay is filed `TX-S` like Start's, and plays beside it: a row Start already
replays is then played twice.

`record.start(channels, path)` writes what the channels (one per wire, no two of one name) carry to
a candump `.log`, created or truncated once their buses are open, a line per frame: `(t) <channel>
<id>#<data> T`, `t` the host monotonic clock in seconds. The last token is the origin, as `candump
-x` and python-can write a direction: `T` for a frame this process sent (tester, simulated ECU or
replay alike: the format has no third value), `R` for the rest. The file replays as it is, and is
what the GUI's Record writes. `rec:counts()` and `rec:stop()` answer `{ frames, ours, theirs,
missed, dropped }` (`missed`: sent here but never seen back, so not written; `dropped`: lost by the
recorder's own handles, behind); `rec:stop()` writes what is queued, lets the sends in flight
settle (2 s at most) and raises when a write failed on the way, or that did not finish in time.

### Raw frames & signals

```lua
bus.send(channel, id, data [, { ext = false, format = "classic" }])   -- send a raw frame
local f = bus.recv(channel [, timeout_ms])          -- receive one frame, or nil on timeout
-- f = { id = <number>, ext = <bool>, data = <byte string>,
--       fd, brs, esi, rtr = <bool>, t_ms = <number>, e2e = <string or nil> }
local t = now_ms()                                  -- the clock f.t_ms is on

bus.send_message(channel, "MsgName", { Sig = value, ... } [, { e2e = false }])  -- DBC-encode + send
local sig = decode(channel, id, data [, ext [, as]])       -- DBC-decode -> { Name = value, ... }
```

- `data` is a **byte string** (see helpers below), not a list of numbers.
- `bus.send_message` / `decode` use the channel's **DBC** (its `databases:`), looking
  the message up by name (encode) or id (decode). `decode` returns physical values, one per
  signal the frame carries: a signal whose bits a frame shorter than its message does not all
  hold is left out (its key is `nil`), as is a multiplexed one its multiplexor does not select
  or whose multiplexor the frame does not hold — so `expect_signal` never matches a value that
  was not on the wire.
- `as` picks what `decode` reports for each signal the frame carries: `"physical"` (the
  default: raw × factor + offset), `"raw"` (the field's bits as a Lua integer, two's complement
  for a signed signal — the key `raw_labels` is keyed by) or `"label"` (the value table's text
  for the raw value; a signal with no text for its value is left out, like one the frame does
  not carry). Any other value raises. One argument rather than a helper per kind: a script
  asking for a label already holds the frame, and one call answers every signal at once.
- `bus.recv` defaults to a 1000 ms timeout.
- `f.e2e` is the frame's E2E verdict, and `bus.send_message` stamps a message's declared E2E: see
  [E2E on what a script reads and sends](#e2e-on-what-a-script-reads-and-sends).
- A received frame (from `bus.recv`, `expect` or an `on_message` handler) carries `fd`/`brs`
  (CAN-FD and its bit-rate switch), `esi` (CAN-FD's error-state indicator) and `rtr` (a remote
  frame) as the wire carried them, and **`t_ms`**, when it was received: milliseconds on the
  host's monotonic clock, the clock `now_ms()` reads, with an unspecified zero — compare it with
  other frame times or with `now_ms()`. Where the backend stamps a frame (SocketCAN's kernel
  stamp; a device clock mapped onto the host's) it is that stamp, unmoved by the script's own
  delay, so frames read off two wires order as the wires saw them, and it is the time the GUI's
  trace and Python's `Frame.t_ms` give the same frame. Elsewhere (`inproc:`, `udp:`, and the
  vendor adapters until they read their stamps) it is the receipt: when the script read it, so a
  frame left queued while the script was busy carries the time it was read.
- `format` states the frame's CAN format: `"classic"`, `"fd"` or `"fd_brs"`. Absent, the
  channel's declaration decides (`type: canfd` frames as FD). It is how a classic frame reaches
  a CAN-FD wire; a classic frame with more than 8 bytes, or an unknown name, raises.

### Bus metrics — bus.load / bus.diagnostics

```lua
local l = bus.load(channel)
-- l = { percent = <last whole second, or nil>, average = <since open, or nil>,
--       frames = <counted>, bits = <their bit-times>, nominal = <bit/s they are priced at> }
local d = bus.diagnostics(channel)
-- d = { dropped = <n>, bus_errors = <n>, decode_errors = <n> }
```

- Both are of the script's own handle on the channel, since it opened (its first use).
- `bus.load` is the GUI's bus load, computed by the same code: each frame's bit-times with
  worst-case stuffing over the wire's nominal rate — the rate of the first enabled row on the
  wire, 500 kbit/s when unset. `percent` is the last whole second and `average` the time since
  open, both `nil` until one second has passed.
- **Decoded frames only**: an error frame, a retransmission and a frame lost in an overrun
  occupied the wire and are not in it, so in an error storm it under-reads; `bus.health` and
  `bus.diagnostics` are what say so.
- **Both directions**: the script's own sends count once the driver took them (the GUI counts
  ours as wire load too); what it receives counts when it is READ (`bus.recv`, `expect`,
  `run()`). A channel the script never reads sees only its own sends, and a frame left queued
  lands in the second it is read.
- `bus.diagnostics` is what the backend counted that no frame carried: `dropped` frames lost
  before delivery (the handle's queue full, a driver overrun, a shared ring overwritten),
  `bus_errors` controller error records, `decode_errors` records it could not decode — on a wire shared through one driver handle (PCAN, CANsub, the CAN bridge) they are the wire's since it opened, its other handles' ring gaps included. The runner prints the non-empty ones at close, as before.

### The DBC catalog

What a channel's databases (its `databases:`) define, read from the same model `decode` and
`bus.send_message` use:

| Call | Returns |
|---|---|
| `dbc.messages(channel)` | every message, in the database's order: `{ name, id, ext, dlc, j1939, signals }` (`dlc` the length an encoding has, `j1939` whether the database declares it), `signals` in their order |
| `dbc.message(channel, name_or_id [, ext])` | one message, or `nil`. An integer is an id (0..0x1FFFFFFF, else it raises) of the kind `ext` names (default `false`, standard), matched exactly as the database defines it — not by J1939 PGN, as `decode` may match a received frame |
| `dbc.signal(channel, message, name [, ext])` | one signal of a message (a name, or an id with `ext` as for `dbc.message`), or `nil` |

A signal is:

| Field | Meaning |
|---|---|
| `name`, `unit` | as the DBC writes them (`unit` `""` where it states none) |
| `start_bit`, `length` | the DBC's numbering: the LSB for `"little"`, the MSB for `"big"` |
| `byte_order` | `"little"` (Intel) or `"big"` (Motorola) |
| `signed` | the raw value is two's complement |
| `factor`, `offset` | physical = raw × factor + offset |
| `minimum`, `maximum` | the DBC's range, both `0` where it states none; nothing applies it |
| `multiplexor`, `multiplexed`, `mux_value` | the mux role: the switch, or a signal present only when the switch reads `mux_value` (set on a multiplexed signal only) |
| `labels` | the value table by the physical value `decode` returns for each key: `labels[3] == "Third"`. Keyed by that computed value, so with a factor such as 0.1 a literal written in the script (`0.3`) can miss it (`0.30000000000000004`); look up what `decode` returned, or use `raw_labels` |
| `raw_labels` | the value table by raw key, the value `decode(..., "raw")` returns. Lossless where `labels` is not: two keys whose physical values one double cannot tell apart are one entry there, the first |

```lua
local gear = dbc.signal("CAN1", "Powertrain", "Gear")
local f = expect("CAN1", 0x100, 1000)
log(gear.labels[decode("CAN1", f.id, f.data).Gear])     -- "Third"
log(decode("CAN1", f.id, f.data, f.ext, "label").Gear)  -- the same, in one call
```

### J1939 — j1939.*

SAE J1939 read from a channel's frames ([j1939.md](j1939.md) is the protocol and the GUI's
reading of it): multi-packet messages rejoined from the transport protocol (BAM, and RTS/CTS
followed as a listener) and decoded through the channel's database by PGN, the transfers that went
wrong, and the address directory. The reading is fed by the frames the script reads on the channel
— `bus.recv`, `expect`, `run()` and the waits below — so a frame is consumed once, and the script's
own sends are never in it. Nothing decides a bus is J1939, so a channel reads it from its first
frame where its row says so (its `j1939:` tick, or a database declaring J1939 with `VFrameFormat`
`J1939PG`), and any other CAN channel from its first `j1939` call. Nothing is sent: no CTS, no
acknowledgement, no address claim — a script that is a node on the bench sends those itself.

| Call | Returns |
|---|---|
| `j1939.listen(channel)` | nothing: the channel is read as J1939 from now on |
| `j1939.messages(channel [, timeout_ms])` | every completed message waiting, oldest first; none waiting, the channel is read until one completes or `timeout_ms` (default 0: one look) has passed, `{}` then |
| `j1939.expect(channel, pgn [, timeout_ms [, sa]])` | the first completed message of `pgn` (from `sa`), waited for at most `timeout_ms` (default 1000); an error naming what came instead otherwise. Messages of other groups taken meanwhile are consumed |
| `j1939.faults(channel)` | the faults since the last call: `{ kind, sa, da, pgn, detail, text }` each (`pgn` nil where nothing was announced, `text` the line the GUI's Log writes); `kind` is `sequence` (a packet dropped or repeated), `aborted`, `timeout` (T1 750 ms for a BAM, T3 1250 ms for a connection, found once a read finds nothing queued), `malformed`, `orphan`, `restarted`, `overflow`, `padding`, `off_spec` or `truncated` |
| `j1939.addresses(channel [, window_ms])` | who holds which source address, by address, after reading the channel for `window_ms` (default 0: nothing read): `{ sa, t_ms, name = { raw, identity, manufacturer, ecu_instance, function_instance, function, function_name, vehicle_system, vehicle_system_instance, industry_group, arbitrary_address_capable } }`. The lower NAME keeps a contested address, a Cannot Claim releases one; `function_name` names the 32 global functions, nil for others; `raw` is the NAME's 64 bits as a Lua integer |

A message is `{ pgn, sa, da, priority, bam, data, packets, t_ms, t_start_ms, name, signals,
note }`: `da` 0xFF for a BAM, `data` exactly the announced size, `t_ms` its last packet and
`t_start_ms` its announcement (`now_ms()`'s clock). `name` and `signals` (physical values) are its
decode — the message defined at exactly that PGN and source address, else by PGN alone — and both
are nil where nothing defines the group, or where definitions disagree about its layout, when
`note` says why. A listener keeps 1024 messages and 1024 faults untaken; past that the oldest go.

```lua
-- projects/j1939-script.blobnet: Peer sends a 20-byte BAM of PGN 0xFF10, J1939 reads it
bus.send("Peer", 0x1CECFF21, string.char(32, 20, 0, 3, 0xFF, 0x10, 0xFF, 0x00), { ext = true })
-- ... the three TP.DT packets on 0x1CEBFF21
local m = j1939.expect("J1939", 0xFF10, 1000)
log(m.name, m.packets, m.signals.Odometer)      -- BodyStatus  3  12345.6
for _, a in ipairs(j1939.addresses("J1939", 200)) do log(a.sa, a.name.function_name) end
```

`tests/j1939.lua` is the suite: a BAM, an RTS/CTS connection played from both sides, a sequence
gap and a stall, address claims and a contested one.

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
| `expect(channel, id, timeout_ms)` | Wait for a frame with CAN `id`; returns the frame (`{id, ext, data, fd, brs, esi, rtr, t_ms, e2e}`, as `bus.recv`), or raises on timeout. |
| `expect_signal(channel, id, signal, want, timeout_ms)` | Wait until decoded `signal` of message `id` matches `want` (a value, or a `function(v)->bool` predicate); returns the matching value, or raises. |

### Reactive callbacks — on_message / on_health / on_timer / run

Register handlers, then `run()` an event loop. Handlers fire *during* `run()`, on the script's
own thread, which is also the only thread that ever touches the script's buses — so a handler may
call `bus.send`, `bus.recv`, `expect`, a `uds` exchange or even `run()` itself.

`run()` reads every channel an `on_message` handler names — and one an `on_health` handler names
where the backend's ladder only moves while the channel is read (SocketCAN, Vector) — from the same
handle `bus.recv` reads. What is already queued on that handle when `run()` starts — since the line that
opened it, which may be an earlier `bus.send` or `expect` — is dispatched by `run()`; how much a
backend keeps for a handle nobody has read yet differs (a socket's buffer; a shared PCAN, CANsub
or CAN-bridge wire keeps what arrived since the handle's open, up to its ring — except on a PCAN
wire nobody else reads, where a handle that has neither read nor sent for over a second keeps only what
arrives after its next read or send), so a test should not count on either. A frame it reads is **consumed** (a later
`expect` gets the next one), whether or not a handler matched it, and the script's own frames are
never heard back. With one channel listened it blocks in the driver, so a
handler runs within about 0.1 ms of the frame; with several it looks at each in turn every 0.1 ms
(1 ms on Windows), about 0.11 ms from frame to handler with two channels on a Linux bench, at
roughly a tenth of a core while it waits. A callback that runs past
the deadline ends `run()` when it returns, and what arrived meanwhile stays queued for the next
reader. The rule is per event — a frame, a timer, a health
sample: none is taken up once the deadline has passed, and a frame taken up before it reaches every
handler it matches, since a frame read off the bus cannot be read again. A handler may call `run()`
itself, directly or in a coroutine of its own: that inner `run()` first gives the frame being
handled to the handlers after the current one, then goes on, so every handler sees a channel's
frames in the order they arrived. A handler that yields leaves its frame to the next `run()` that begins a delivery
(a `run()` already part-way through an earlier frame finishes only what it began with). A handler that does not return — it raises (inside a coroutine too, resumed or wrapped), or yields
into a coroutine that is then closed — ends its frame for the handlers that have not had it yet,
whoever catches the error; a `run()` it
called before that (directly, in an `xpcall` handler or a `<close>` cleanup) may already have given
it to them.

| Call | Meaning |
|---|---|
| `on_message(channel, id, fn)` | `fn(frame)` fires for each matching frame received during `run()`. `id` may be `nil` to match every frame on the channel. |
| `on_health(channel, fn)` | On SocketCAN and Vector the ladder moves only while the channel is read, so `run()` reads it — and consumes its frames — as it does for `on_message`. `fn(state)` fires during `run()` when the controller's fault ladder has moved — `"ok"`, `"error warning"`, `"ERROR-PASSIVE"`, `"BUS-OFF"` — and at its first sample with the state then, however late the handler was registered. Sampled every 100 ms: a state held for less than that between two samples can be missed. A software bus (`inproc:`, `udp:`) has no ladder and never fires. |
| `on_timer(period_ms, fn)` | `fn()` fires every `period_ms` during `run()`, on its own grid: a late fire does not delay the next one, and periods missed while the script was busy are skipped, not sent in a burst. A timer is never fired again inside its own callback; one whose callback yields stays paused until that coroutine resumes or is closed. The period is a number of milliseconds, at least 1; a fraction is honoured to within a millisecond. |
| `run(duration_ms)` | Run the event loop for `duration_ms`. |
| `bus.health(channel)` | The ladder as the backend last saw it, as the strings above; `""` where it cannot say. PCAN, Kvaser and CANsub ask the driver, and the CAN bridge pushes it; on SocketCAN and Vector it is the state the channel's last read saw, so outside `run()` it can be stale. |

```lua
local hb = 0
on_message("CAN1", 0x700, function(f) hb = hb + 1 end)   -- Heartbeat
on_health("CAN1", function(s) log("CAN1 is", s) end)
on_timer(100, function() bus.send("CAN1", 0x123, string.char(0, 1)) end)  -- a cyclic frame
on_timer(500, function() log("tick, heartbeats so far:", hb) end)
run(3000)
```

A frame sent periodically from `on_timer` goes out only while `run()` runs; one that must keep
going while the script waits in `expect` or a diagnostic exchange belongs in the project's
generators (`senders:`, docs/simulation.md), which a script drives with [`gen.*`](#generators).

(Lua's own coroutines are available too if you want to hand-roll more elaborate
flows, but `expect` + `on_message`/`run` cover the common test shapes.)

### Generators

The project's generators (`senders:`, [simulation.md](simulation.md#interactive-senders)), in a
headless run: what the Generators panel lets a person do. Each is named by its name, or by
`"channel/name"` where two share one (a shared name alone is an error naming the forms that tell
them apart), or by its position in `gen.list()`, a number — the one way to reach two generators
of one name on two channels of one name. Every
CAN channel's generators are there, a disabled channel's included (its generator may send on an
enabled one); in the GUI's Script panel `gen.*` is an error, the generators being the panel's.

| Call | Meaning |
|---|---|
| `gen.list()` | every generator: `{ name, channel, message, id, ext, trigger, cycle_ms, running, sent, target, note }` — `message` `""` for a raw frame, `trigger` as the project writes it, `running` sending on its cycle now, `sent` the frames its bus took, `target` the interface it sends on, `note` why it cannot send (`""` when it can) |
| `gen.fire(name)` | send its current frame once, returning once the bus took it — a first fire of a non-cyclic one opens its bus — within 5 s and the run deadline, or an error; a frame the generator had not taken up when the wait ended is never sent |
| `gen.start(name [, cycle_ms])` | send it on its cycle from now (its own when omitted; an error when it has none) |
| `gen.stop(name)` | end its cycle; `gen.fire` still sends it |
| `gen.cycle(name, cycle_ms)` | a new cycle (1 .. 3600000 ms), from its next frame |
| `gen.set(name, signal, value)` | the signal at a static value from the next frame, its value source dropped; a signal the generator did not list is added; a multiplexed one is sent where the switch selects its branch |
| `gen.source(name, signal, src)` | the signal on a value source from the next frame: `src` is `{ type = "sine", offset = 50, amplitude = 10, freq = 1 }`, `type` one of `const`, `sine`, `sawtooth`, `counter`, `stepmod` with the parameters a project writes for it (`step` 1 when omitted, every other 0) |

A call that cannot take effect is an error saying why: a cycle out of range, a signal the message
does not have or its payload does not hold (or any signal of a raw frame), a value that is not finite, a source that cannot be
evaluated (a zero period or count, an unknown parameter), a generator with nothing to send on,
or a send its bus refused (a listen-only row). An edit lasts for the run: the next start brings
the generators up as the project writes them. `tests/generator_control.lua` is the suite.

```lua
gen.set("Heartbeat pulse", "Counter", 42)
gen.fire("Heartbeat pulse")
gen.fire(3)                                -- the third of gen.list()
gen.source("Ping ECU (Request)", "ReqCode", { type = "counter", start = 100, modulo = 256 })
gen.start("Ping ECU (Request)", 20)        -- a manual generator on a cycle of its own
gen.stop("Cyclic wake (0x123)")
```

### Logging & timing

| Call | Meaning |
|---|---|
| `log(...)` | Print a line to the output (tab-separated args). |
| `print(...)` | Same as `log` (routed to the Blobly Net output). |
| `sleep_ms(ms)` | Wait `ms` milliseconds. |
| `now_ms()` | The host's monotonic clock in milliseconds: the clock a received frame's `t_ms` is on, so `f.t_ms - sent_at` is a latency (on a wire that stamps frames, or one read while the answer arrives). |

Plus the full Lua 5.4 standard library (`string`, `table`, `math`, …).

---

### Also in the prelude

| Function | What it does |
|---|---|
| `sim.fault(channel, node, message, kind [, ms [, signal]])` | inject a fault into a simulated ECU's message — `drop`, `bad_crc`, `freeze_counter`, `out_of_range` (with `signal`), or `clear`; `ms` limits it in time. A fault that cannot take effect (no such node, no protection field for `bad_crc`) is refused, not silently armed. See [simulation.md](simulation.md). |
| `sim.clear_fault(channel, node, message)` | lift it |
| `doip.discover(channel)` | one identification request to the channel's configured endpoint |
| `doip.listen(window_ms [, {port=, ip6=, from=}])` | collect vehicle announcements for a window; each entry names the sender's endpoint. `from=` names a channel and listens on that channel's own port; a `port=` that contradicts it is an error |
| `someip.listen(window_ms [, {port=, group=, from=}])` | hear every SOME/IP message on a port for a window, decoded to its header (`service`, `method`, `event`, `type`, `iface`, `client`, `session`, `rc`), the payload raw, the sender in `from`; returns the list and a count of malformed datagrams. `group=` joins that multicast group, which is what hearing a service's multicast events or a SUT's SD offers takes (a plain bind hears unicast only). `from=` names a `someip` channel of the project and takes its bind host, port and group (a `port=`, or a `group=` differing from the channel's own, is an error). An endpoint another listener in this process already holds — a running channel row, or another window — is refused and names the holder, whichever started first: two sockets on one UDP port split the stream rather than share it (docs/bus_config_dialog.md). Port defaults to 30490. Nothing is sent or subscribed to: an event a service delivers only to subscribers is not heard (docs/ethernet_architecture.md) |
| `someip.send(to, msgs [, {port=30491, window_ms=1000}])` | send SOME/IP messages to `to` (`"host:port"`) FROM a local port, then hear that port for the window — one socket both ways, because a node with a static peer endpoint (a blobly_emb SOME/IP node) accepts datagrams only from its configured peer and answers that same endpoint. `msgs` is one message or a list: `{service=, method=, payload=, type="notification"\|"request", iface=1, client=, session=}` (the type defaults by the id's bit 15; a request defaults to client 0x1234 and a session reserved for the run, the tracker `someip.call` uses, so no session goes out twice). Returns what `someip.listen` returns. The port is claimed like a listener's: a running channel row or another window on it is refused |
| `someip.call(to, req [, opts])` | one request/response exchange (`blobly/someip` `call`, on `RpcClient` — the GUI's Shell over Ethernet uses the same): sends from `opts.port` (30491) and returns as soon as the RESPONSE or ERROR mirroring its Request ID arrives FROM `to` — `{type="response"\|"error", rc=, payload=, client=, session=}`, an ERROR being an answer with its return code. Events, other senders, an incompatible interface version and late replies to an earlier session are ignored; `nil, "no answer"` past `opts.timeout_ms` (1000). Client defaults to 0x1234 (0 is refused: a blobly_emb node rejects it); sessions advance within a run and are never reused. IPv4. Bench-verified 2026-10-02 against the H735's shell method (blobly_emb `examples/h735_someip`, since retired into system_full's `tcu` node, emb#348) |

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
and `blobly/project`.

To run against **real hardware** later, point a channel's `interface:` at a vendor
adapter (e.g. `pcan:PCAN_USBBUS1`) — the scripts don't change. See
[windows_can_hardware.md](windows_can_hardware.md).

---

## 5. Running from the GUI

The **Script** panel (toggle it from the left activity bar — **Lua** — or **View ▸ Script**)
runs scripts against the **live measurement**:

1. Press **▶ Start** first (the script talks to the running buses/sims).
2. The path field starts at `tests/diag_basic.lua`; type a path or **Browse…** for one, and
   press **Run**. **Edit** opens the script in the same edit box the Configuration panel's File
   tab uses: the file's name above it, **Save script**, **Discard edits** (or **Reload** when
   clean), **Open in editor** (the command from Settings ▸ Preferences…, else the system's
   own open; the editor is launched detached and shares nothing with the run), and a divider
   under the box to trade height
   with the output. Run is withheld while edits are unsaved; closing the editor keeps them,
   and the note under the toolbar says so. Every line the script
   emits — `log()`, `print()`, each test's verdict — lands in the panel's output; it is
   replaced per run, capped at the last 2000 lines, and **Copy all** copies it. What the
   script's own buses and connections counted (dropped, controller-error, undecodable records)
   is appended when it finishes. While the measurement is stopped the panel says so: nothing
   hosts the simulated ECUs then, and a diagnostic suite times out.

Output (per-test results + a pass/fail summary) appears in the panel. Because it uses
the live measurement, the ISO-TP request frames a script sends are visible in the
**Trace**, just like any other traffic.

### Recording a script in the Diagnostics panel — Copy as Lua

The **Diagnostics** panel logs every request it puts on the wire as one row of its response
table: time, target, the request (`22 F190 ReadDID VIN` — bytes and a short name, the DID named
by the target's description where it has one), the answer (`F190 = "BLOBLY…"`, or
`7F 22 31 requestOutOfRange`), the round trip in ms and how many `0x78` (responsePending) it
waited through. Connection events (an open with its connect and routing-activation times, a
let-go, a failed keep-alive) and the panel's own notes are rows of their own. **errors only**
and **this target only** filter it; a click selects a row and shows every byte of it below the
table, Ctrl+click adds to the selection; **Copy all** copies the rows shown as text.

**Copy as Lua** turns the selected rows — or every row shown, when none is selected — into a
script for `cmd/script`, on the clipboard. Each request becomes ONE test, calling the
higher-level helper where the request is one and `diag:raw` otherwise, and checking the answer
the operator saw — its data, or its NRC through `check.nrc` — so a recorded session is a
regression test of the ECU it was recorded against:

```lua
-- Recorded in the blobly_net Diagnostics panel: 4 request(s).
-- Each request is one test, checking the answer the operator saw.
-- @project /home/me/blobly_net/projects/sim-demo.blobnet

local diag  -- the connection the requests below go to

diag = uds.open("CAN1", { tx = 0x7E0, rx = 0x7E8 })  -- SUT  (0x7E0/0x7E8)

test("2: 10 03 Session extended", function()
  check.equal(tohex(diag:session(0x03)), "03 00 32 01 F4")
end)

test("3: 22 F190 ReadDID VIN", function()
  check.equal(diag:read_did(0xF190), "BLOBLYNETV0SUT001")
end)

test("4: 22 ABCD ReadDID", function()
  check.nrc(0x31, function() diag:read_did(0xABCD) end)
end)

test("5: 19 02 FF ReadDTC byMask", function()
  check.equal(tohex(diag:read_dtcs(0xFF)), "FF 12 34 56 09 AB CD EF 08")
end)
```

Paste it into a file and run it with `scripts/runtests.sh <file>`. The mapping:
`0x10` → `diag:session`, `0x11` → `diag:reset`, `0x14` → `diag:clear_dtcs`, `0x19 01` →
`diag:dtc_count`, `0x19 02` → `diag:read_dtcs`, `0x22` (one DID) → `diag:read_did`, `0x2E` →
`diag:write_did`, `0x28` → `diag:comm_control`, `0x3E 00` → `diag:tester_present`, `0x85` →
`diag:dtc_setting`, a seed request followed by its key — the next entry of the log, not merely the next row
selected — → `diag:security_access(level)` (the seed varies, so it is not compared; the key is
the reference algorithm the panel used; a seed on its own is sent uncompared, a key on its own
is a comment), a request
with suppress-positive-response set → `diag:raw_suppressed`, checked for whether a positive
answer came anyway, as it did or did not when recorded; anything else → `diag:raw` with its
whole answer compared. A request that went unanswered or unsent is written as a comment, not
replayed, and so are connection events and notes. Each target is opened by the project channel
that carries it (CAN with its ids, DoIP by the channel alone), at its first request, and closed
(`diag:close()`) when the requests move to another target — one connection at a time, as the
panel holds one, since a DoIP entity serves one connection and a second open of its endpoint
waits on the first; the `-- @project` line names the
project the panel had loaded. The generator is `script.lua_from_log` (`blobly/script/session_lua.v`).

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
`v -enable-globals run cmd/<tool>/<file>.v [args]`). The
hardware bench tools — `silentcheck`, `vectorcheck`, `kvasercheck`, `crosscheck` — are
described in [windows_can_hardware.md](windows_can_hardware.md); `cansub_smoke` has only its
own header comment:

| Tool | What it does |
|---|---|
| `cmd/script` | the script/test runner (this guide; usually via `scripts/runtests.sh`) |
| `cmd/flash` | flash an image through a blobly_emb bootloader over ISO-TP (`flash.program` from a script) |
| `cmd/doip_smoke` | drive UDS over DoIP against a local entity, no project needed |
| `cmd/restbus` | replay a recording onto live buses with the ECU under test subtracted |
| `cmd/lua_smoke` | minimal embedded-Lua check (script + host callback) |
| `cmd/uds_smoke` | drive the UDS client against an ECU (`vcan0` or `inproc:CAN1`) |
| `cmd/sim_smoke` | run the native simulated SUT ECU and verify end-to-end |
| `cmd/dbc_decode` | load a DBC and decode one frame |
| `cmd/mf4_dump` | read an ASAM MF4 recording (count / ids / frames) |

The GUI itself is `scripts/run_gui.sh` (see [CLAUDE.md](../CLAUDE.md)).
