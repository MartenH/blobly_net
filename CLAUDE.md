# Blobly Net (V) — project guide for coding agents

> **This is the guide.** `AGENTS.md` is a pointer FILE here, real rather than a
> symlink: two agents look for two names — Claude Code reads `CLAUDE.md` and nothing else, Codex
> and others read `AGENTS.md` — and a symlink either way round becomes a 9-byte text file on a
> checkout without symlink support, so whichever tool follows it silently gets a one-word guide.
>
> **Keep this short and true.** Every claim here should be checkable against the repo in
> seconds. Historical narrative belongs in [`docs/history.md`](docs/history.md), not here —
> a long guide rots silently, and a stale guide is worse than none because the next session
> trusts it.

An automotive bus tester written in **V (vlang)**: exercise a SUT over **CAN**, and over
**Ethernet** via the automotive protocols on it (**DoIP**, **SOME/IP**) — run diagnostics, script
tests, simulate ECUs, read back logs. **Virtual first** (Linux `vcan0`); real hardware is a
drop-in. Ethernet here is ordinary TCP/UDP sockets: automotive PHYs (100BASE-T1) and TSN are NOT
supported. LIN is roadmap, not implemented.

## Fresh setup / new session — START HERE

This repo is the single source of truth — a new agent session has no prior memory (tool-local
memory such as `~/.claude` does not transfer). Everything needed is in git.

```sh
sudo ./scripts/setup_sudoers.sh   # optional: scoped passwordless sudo (apt-get/ip/modprobe/insmod)
./scripts/setup_env.sh            # V + native deps (GLFW/FreeType) + can-utils, builds the GUI,
                                  # brings up vcan0, runs the tests
./scripts/run_gui.sh             # build + run the GUI
```

For traffic with no hardware, open `projects/sim-demo.blobnet` — the simulated ECUs are native
(`modules/sim`) and run in-process. `sut/*.py` is NOT part of this path; see Layout.

## Decisions

- **Language:** V (vlang). Beta — expect compiler/runtime rough edges. Pin what works.
- **GUI:** **Dear ImGui + ImPlot**, wrapped as the native-V `vgui` module (`libs/vgui`); the app
  is `cmd/blobly_net`. *(Migrated 2026-07-06 from `vlang/gui`; the old `src/main.v` app is
  deleted. Rationale in [`docs/gui_toolkit_evaluation.md`](docs/gui_toolkit_evaluation.md).)*
- **CAN:** SocketCAN on Linux (`vcan0` virtual, or any adapter); **PCAN**, **Kvaser** and
  **Vector XL** on Windows (vendor DLLs loaded at runtime; all three HW-verified — Vector on a
  VN1630A, Channel 1 to Channel 3 at bus saturation. Vector additionally needs `vxlapi64.dll`,
  which is a SEPARATE download from the hardware drivers and does not install onto the search
  path; the backend looks in its install directory). All behind the `transport`
  interface, so backends are drop-in.
- **Engine stays GUI-free.** CAN/protocol logic lives in `modules/` with no GUI imports, so it is
  independently testable and the GUI stays replaceable. This is the one architectural rule.
- **Projects** are `.blobnet` files (YAML content) describing buses, channels and databases.

## Layout

```
cmd/blobly_net/     the GUI (Dear ImGui + ImPlot)   <- the app
cmd/*                CLI tools + smoke tests (flash, dbc_decode, mf4_dump, restbus, trace_dump, ...)
libs/vgui/           the V wrapper around Dear ImGui/ImPlot
libs/markdown/       vendored vlang/markdown (md4c) — renders the Help pages to HTML. Vendored,
                     not fetched, so a clone builds offline and the version is stated once
modules/             engine (GUI-free, unit-tested)
scripts/             setup, run, test, packaging. `setup_vcan.sh` is the ONE per-session command
                     (loads vcan, brings up vcan0/vcan1 at mtu 72); `build_vcan_module.sh` is the
                     rare one (once, and after a kernel upgrade). Both source `vcan_common.sh`
                     for the questions they share — one answer each, tested by
                     `vcan_common_test.sh`, because every place they were answered twice drifted
projects/            example `.blobnet` projects
sut/                 Python VERIFICATION ORACLES (dev-time only, not CI, not the sim path):
                     cantools/asammdf/udsoncan as INDEPENDENT implementations to diff V against.
                     Its virtual-ECU role is superseded by modules/sim (native, in-process).
tests/               Lua test scripts
docs/                design + platform docs; docs/history.md = archived status log
```

**Modules** (all covered by `v -enable-globals test modules/`; the flag is required —
`modules/transport/inproc.v` uses `__global`):

| module | what |
|---|---|
| `transport` | Bus/Channel interface + SocketCAN, PCAN and Vector XL (Windows), UDP software bus. **Bus health** (warning/error-passive/**BUS-OFF**) decoded per backend (`health.v`, pinned to vendor headers by tests) — the Buses panel colors it, the Log narrates transitions, and the toolbar carries the worst running wire's verdict, because a fault reported only in a panel nobody has open is not reported (#156). **CAN-FD** (`fd`/`brs`, 64-byte payloads) on SocketCAN, the software buses and **Vector** (`vector:1@500000/2000000` — the data rate in the address is what asks for FD, so nothing can contradict it; opens the port at XL interface V4, where the event layout differs, so the protocol is pinned by the open ports like the rate is. HW-verified on a VN1630A to an 8 Mbit/s data phase). **Kvaser** (`kvaser:0@500000/2000000` — same rule: the data rate in the address asks for FD, `canOpenChannel(canOPEN_CAN_FD)` + `canSetBusParamsFd`, and the FD/BRS flags are read back PER FRAME because an FD channel carries classic frames too. HW-verified on a USBcan Pro 5xHS, ch1<->ch2 with two 120 Ω terminators: lengths 8/12/16/24/32/48/64 at data rates 500k/1M/2M/4M/8M, via `cmd/kvasercheck --ladder`. Lengths 0..7 and 20 are covered by the length rule only, not on copper. FD arbitration is 500k or 1M — the 80% sample-point family, because canlib's classic constants sample at 62.5% and a loopback bench cannot tell). **PCAN** (`pcan:PCAN_USBBUS1@500000/2000000` — same rule again, `CAN_InitializeFD` with a bit-timing STRING the 80 MHz clock is solved into rather than a rate constant, so it takes any rate that divides where canlib offers five fixed ones. `CAN_Write` is REFUSED on an FD-opened channel, so a classic frame there goes out through `CAN_WriteFD` with the FD flag clear — found on the bench when every FD leg passed and every classic one failed. HW-verified cross-vendor, Kvaser CH3 to PCAN-USB Pro FD, 18/18 at 1/2/4/8 Mbit/s. The solver is in `pcan_names.v` for the same reason Kvaser's map is). The Kvaser address and rate maps live in `kvaser_names.v`, not beside the driver, for the reason `vector_names.v` does: a `_windows.v` file compiles only where CI runs nothing. **One wire, one handle** where the driver demands it (`shared.v`): PCANBasic permits a single `CAN_Initialize` per channel per process, and the app opens each wire several times per Start, so `pcan:` opens share one physical bus keyed on the wire (the destination WITHOUT its bitrate) — and since #221 a second open is a second SUBSCRIBER with its own receive cursor over one ingress ring, not a competitor for the same frames (#212). Not applied to `inproc:`/`udp:`/SocketCAN/Vector/Kvaser, which fan out natively. The hub's one lock, `send_mu`, guards write order for acknowledgement matching and nothing else: the reader, `health()`, `reconcile_silence()` and `close()` never wait on a writer, because a stalled socket write must cost its sender and nobody else. **Listen-only is enforced in `open`** (`listen.v`): a process-wide table of silenced wires. Every bus `open` returns is wrapped and the table is consulted PER SEND, not cached into the handle: marks move (a row toggled mid-run, a project replaced) and a Lua script may outlive Stop still holding its bus, so an answer frozen at open time is one that goes stale while a wire transmits. So every emitter in a process that has applied a project — Quick Send, generators, simulated ECUs, replay, diagnostics, the shell, Lua — gets a bus that refuses rather than each of them remembering to check. `project.apply_listen_only()` is what fills the table, and only the GUI and the headless Lua runner call it; `cmd/restbus` takes an interface on the command line and never loads a project, so it has nothing to be silenced by. **And software refusal is only half of listen-only on real CAN**: an ACK is generated by the CONTROLLER on every frame it accepts, so a wire this process declined to transmit on went on acknowledging — which on a bus with one other node is the difference between its frames succeeding and it going error-passive. All four vendor backends now silence the transceiver too (Vector `,silent`, CANsub's PHY object, PCAN `PCAN_LISTEN_ONLY` and Kvaser `canSetBusOutputControl(canDRIVER_SILENT)`, the last two in #219), each reading the same table rather than keeping its own answer; the software buses have no ACK to suppress, so refusal is complete there by construction. PCAN, Kvaser and CANsub re-ask PER RECEIVE so a row toggled mid-run reaches the controller within one poll, and what was APPLIED is recorded per WIRE, not per bus (`silence.v`) — the mode belongs to the CONTROLLER, so every handle open on that channel shares one answer: held per bus it was written once per handle (a bus bounce each, on Kvaser) and never at all by a transmit tap nobody reads from. That table is EMPTY at process start and the controller is not, which is what makes the first claim on every wire write unconditionally: a run that ended while a wire was marked leaves the next opener silent, with no mark to say so (measured — Kvaser's `canClose` does not reset it, PCAN's `CAN_Uninitialize` does). Vector alone cannot follow a mid-run toggle, because its mode is pinned by the open ports — see `pinned.v` below. **On Kvaser the mode is set through EVERY handle on the wire** (`kvaser_handles` / `ct_kvaser_set_silent_all`), because only the one holding canlib's initialisation access is obeyed and no call reports which that is — asked through any other, the driver returns success and does nothing, so a wire the app had recorded as silenced went on acknowledging. Measured; `cmd/silentcheck --handles` is the bench that covers it, defaulting to the several-handles-per-wire shape a Start actually opens. `cmd/silentcheck` is the bench proof, vendor-agnostic on purpose so the pairing can be cross-vendor. **CAN-FD framing rides the same seam** (`framing.v`, #185): every frame this app CONSTRUCTS was built classic, so a channel configured as CAN-FD could be exercised by nothing but replay — and stamping at each front end's apparent choke point missed most of the emitters, because the simulated ECUs, the ISO-TP servers, flash, Lua and the headless UDS nodes each hold their own bus. So `WirePolicy` carries silence AND format in ONE entry, published together by `project.apply_listen_only()` and read ONCE per send, and `SilentBus` stamps what the wire declared. Stamping is UPWARD ONLY, and a bus may be `verbatim` — its caller owns the format — which is how REPLAY reproduces a recording rather than having its classic frames promoted, and how the GUI's tap frames before it records (wiretap's identity includes `fd`/`brs`). The rule is `project.Channel.origination_framing()`: declared, never inferred from payload size, `brs` following a data rate distinct from the arbitration one. Two enabled rows that disagree about one wire leave it undeclared — the table is keyed by wire, the disagreement is between rows, and two formats on one wire wants the per-frame answer #203 tracks. Kept OUT of the address on purpose: `,silent` in an interface string would change the wire identity `destination_key` derives and split a PCAN channel into two. **What the ports already fixed** (`pinned.v`): a Vector channel's mode, bitrate AND protocol (classic/FD, plus the FD data rate) belong to the PORTS open on it, so `,silent` is the one listen-only answer software cannot revise — a port that disagrees is refused (-1004/-1005 for mode and rate, -1011/-1012 for the protocol and its data phase), or, if the port holding initialisation access has closed while siblings stayed open, reconfigures the channel under them — `transport.wire_pin_clash` reports what an address is about to contradict, and the Buses panel asks BEFORE it opens. Only Vector pins; everywhere else `open` is free to change its mind per send, and asking would buy a refusal nobody needs. The case it exists for is a DISABLED row, whose transmit taps stay open on purpose and so hold a channel no enabled row mentions (#165) — verified on a VN1630A with `cmd/vectorcheck --modecheck`, since no CI runner has one. **Which hardware is `vector:<n>`?** The XL library addresses APPLICATION channels, so a physical channel must be mapped to one before it can be opened, and the Discover dialog does it (#186) rather than sending you to Vector Hardware Manager. What the driver says about one of OUR channels is four states, not three (`AppSlot`): `taken` and `unreadable` refuse a write, `empty` and `absent` permit it — `absent` being "the driver has no such channel", where writing CREATES it, which is the documented way to extend an application and the state ~57 of 64 channels are in on an ordinary bench. Splitting `absent` from `unreadable` is what ended six review rounds in `assign_refusal`: they were one state with two meanings, so no rule over it could be right for both, and the shim was collapsing "driver unreachable" and "no such channel" into one return code. Only ONE measured status (255) means absent — and because that is XL's GENERIC error, "this channel is not registered" and "this one call failed" are literally the same bytes. Nothing separates them: retrying does not (a persistent failure repeats) and no other XL call exposes an application's channel count. So the code stops deciding — `absent` is REFUSED by default, and creating it is an explicit checkbox in the dialog. Four review rounds demanded opposite defaults for that one state, each right about its own case (refuse it and a fresh bench cannot bootstrap; permit it silently and one dropped read retargets a mapping that survives reboots), which is the signature of a rule being asked to know something unknowable. `vector_assignment` errors on it for the same reason — `cmd/vectorcheck`'s borrow reads that to snapshot what it would overwrite. The rules are pure and tested in `vector_names.v`, deliberately: written beside the driver they compile only on Windows, where CI runs nothing |
| `transport` (cont.) | **CANsub** (`cansub.v`, `cansub_codec.v`, `cansub_http.v`, `cansub_timing.v`) — `cansub:<device-id>/<channel>[@<arb>[/<data>]]`. The ONE hardware backend that is not a vendor DLL and not platform-gated: a CSS Electronics CANsub enumerates as a USB **network** adapter, so `list_interfaces()` never sees it and the same code reaches it from Linux and Windows. Configuration is REST, frames are HDLC over one WebSocket per channel, and the vendor's **20 published test vectors** are pinned in `cansub_codec_test.v` — which is what lets CI cover a format no runner has hardware for. **By device id through mDNS, never an IP**: a firmware update clears persistent data and the device returns on a different subnet (seen going 10.63.38.1 → 10.215.129.1), while `<id>-usb.local` follows it. Through `shared_open` like `pcan:`, because the vendor permits **one client per channel WebSocket** and the app opens each wire several times per Start. It **echoes its own sends** — TX acknowledgements carry a start-of-frame hardware timestamp, so they are delivered and `wiretap` claims them, or every transmitted frame is filed twice as the ECU's (#139's lesson). Three things only the device could tell us, all found by trying: `net.http` **cannot talk to it at all** (its status line has no reason phrase, V demands three tokens — hence `cansub_http.v`); a PHY PUT is refused unless the object is **complete**, `timing_data` included, on a channel that will never send an FD frame; and the **data-phase registers are far narrower than the nominal ones**, so a nominal solution copied across is answered with a bare HTTP 500. HW-verified on a CANsub.4 (02.04.00) with channels 1 and 2 wired together: classic, extended, 64-byte FD with BRS at a 2 Mbit/s data phase, a payload of `7E 7D 7E 7D` whose bytes collide with the framing, listen-only reaching the controller register, and a second open sharing the first connection. **Frame shape is decided once** (`frame_rules.v`), and the reasons come in THREE kinds that must not be confused. **Frames no controller could send** — brs-without-fd, esi-without-fd, and an id that does not fit its DECLARED width — are refused by every backend, software buses included: carrying one makes a simulation a model of something that cannot happen, and a test that passes on `inproc:` and fails on a bench. **A remote frame is refused too, but for a different reason**: a classic controller can send one perfectly well and this app has chosen not to (#215), so `frame_send_refusal` is named for what it does rather than for a law it does not describe — read that decision as a CAN constraint and the next backend will get it wrong. Receiving one is unaffected; a wire and a recording can both carry one, and a trace showing it as data would be lying about the bus. **Lengths are per tier** and deliberately not unified: SocketCAN CLAMPS and `wire_frame` records the clamp so record and wire agree, the software buses PAD an FD payload up to a length a DLC can express (9 bytes go out as 12, which is what a controller does), and the vendor backends REFUSE. `clamps_to_classic` states that split; #208 is about removing the per-backend duplication, NOT about making the tiers agree. Written per backend, these are the rules the NEXT backend does not get: Vector refused most, Kvaser fewer, CANsub landed refusing one — masking an oversized id and dropping BRS silently — and PCAN accepted brs on a classic frame for as long as it has existed (codex on #204). Each puts a different frame on the wire from the one `wiretap` recorded, so our own frame comes back unmatchable and is filed as the ECU's |
| `candb` | DBC parse/decode/encode + canonical writer (`dbc_write.v`) |
| `isotp` | ISO-TP (ISO 15765-2) transport |
| `uds` | UDS diagnostic client over ISO-TP |
| `doip` | DoIP (ISO 13400) — UDS over TCP; same shape as `isotp.Channel`. Entity (server) side too: ▶ Start hosts one per channel that configures **simulated nodes**, in the GUI and headless. A channel without them is tester-only — it addresses somebody else's ECU and nothing is hosted for it |
| `someip` | SOME/IP header codec, envelope validation, `RpcClient` |
| `flash` | UDS firmware-download session against a blobly_emb bootloader (0x29 auth) |
| `wiretap` | whose frame is this? — the record of what we put on the wire, matched against what comes back, so the trace's `origin` column can separate our tester (`TX`) and our simulation (`TX-S`) from the real ECU (`RX`) |
| `sim` | simulated ECUs — tests need no hardware; `doip_entity.v` decides what a DoIP channel hosts and `doip_host.v` is the served-side handler, both shared by the GUI and the headless runner |
| `player` | replay a recording at its recorded cadence — the GUI's **Replay panel** is its transport face (pause/seek/speed via `set_speed`, position-preserving; `set_repeat` arms looping, a PASSIVE flag read only at the end of a pass, so it never acts when you set it). **The panel/worker command protocol is `control.v`**, here rather than in the GUI so a test can reach it: a TARGET state rather than a toggle, a tri-state loop sentinel (a bool has no value spare for "no request", so loop could never stay on), `take()` reading and clearing together, and the ordering `apply_latched` -> `status` -> `apply_timed` -- loop must be applied BEFORE the status that acknowledges it, or the panel's latch clears on a value the worker has not applied yet. Two of #160's four findings landed in this path and the second was a defect of the first one's fix, because `cmd/blobly_net` has no tests and CI runs `v test modules/` only (#161). And decide what NOT to replay — `restbus.v` subtracts the ECU under test by DBC sender so a capture can drive a rest bus without the SUT arguing with a recording of itself; `multibus.v` maps SEVERAL recorded buses onto several live ones from ONE clock, because the SUT gateways between them and the timing across buses is what it polices |
| `canlog`, `mf4` | `candump -l` files; native ASAM MDF4 (`.mf4`) reader |
| `telem` | trace + telemetry capture control |
| `sysview` | read-only system model behind the System panel (reads blobly_emb `system.toml`) |
| `script`, `lua` | embedded Lua + the test-framework prelude. **A test declares the project it needs** (`project_decl.v`): a `-- @project ../projects/x.blobnet` line in the script's leading comment, resolved relative to the SCRIPT so it holds from any working directory. Run against the wrong project, a suite does not report a configuration mistake — it reports failing tests, one of them "unknown channel", which reads as a broken feature; both DoIP suites looked broken on `main` that way (#115). So the runner reads the declaration, and REFUSES a `--project` that contradicts it, or two scripts in one invocation that need different projects — one run brings up one project, and a refusal naming both beats a pass nobody can account for |
| `project` | `.blobnet` project files. `destination_conflicts()` is the ONE place a project is refused for asking a wire to be two things — one mode, one rate, one protocol (a `canfd` row and a `can` row on one **Vector, Kvaser, CANsub or PCAN** wire is refused from the file, not as a channel that fails halfway through a Start — those four are the backends that configure a data phase, and `transport.adapter_configures_data_phase` is the one place to say so. It is NOT every CAN backend: SocketCAN and the software buses answer `false`, because there the data phase is the link's or nobody's, so a mixture there is a warning and not a refusal), and (#167) one physical channel: two Vector *application* channels assigned to one *physical* channel are two wires here and one to the driver, so the comparison is pure and testable (`alias_conflicts`) while the resolution behind it (`transport.physical_wire_key`) is per-platform and answers `none` wherever no driver can say |
| `sampledb` | hand-coded message catalog (superseded by DBC loading) |
| `testports` | which port may a test bind? Test-support, and the one module the engine does not use. A FIXED port fails once, on somebody else's machine, and passes on every re-run (#112) — worst of all in `doip/net_test.v`, where two sites read a failed bind as "no IPv6 loopback here" and skipped, so a collision dropped coverage while printing a plausible reason. Deriving the port from the pid is not the fix on its own: any formula over a finite band aliases. So **TCP verifies** — `candidates()` proposes, starting where the pid points, and the caller takes the first it actually BINDS, which also settles two sites in one process and makes "every candidate refused" a real environment fact. **UDP cannot be verified at all** from this V: `listen_udp` sets SO_REUSEADDR with no opt-out, so a second bind on a held port succeeds and the later binder wins delivery — a probe that checks whether the token comes back is therefore the squatter's successor and always says yes (tried; CI caught it). So UDP predicts instead, and `slot_for` gives each process a disjoint BLOCK, the original defect being `base + pid + slot` making process N's slot 1 into process N+1's slot 0 while a runner spawns its files pids apart. Each file gets its own BAND, declared together because disjointness is a property of the set; all below 32768, clear of the ephemeral range. Where a test owns its listener, none of this applies — bind port 0 and read back what the OS gave (`free_listener`), which cannot collide at all |

## Build / run / test

```sh
./scripts/run_gui.sh                       # GUI
v -path "@vlib|@vmodules|modules" run cmd/<tool>/<file>.v   # any other target
v -enable-globals test modules/             # unit tests — the reliable backbone (63/63)
./scripts/runtests.sh                       # ALL headless Lua suites (in-process sim) — CI's command
./scripts/runtests.sh tests/diag_basic.lua  # or name them: one invocation, one environment
```

Releases: push a `v0.1.0`-style tag matching the version in `v.mod` (the ONE version
statement — the binary decodes it for `--version` and the title bar) on a commit reachable
from `main`; `release.yml` verifies both, then publishes the Linux tar.gz and the Windows zip
(via `windows.yml`, which publishes for a tag only when called with `publish_bundle=true` from
behind that guard). Bundle payload list: `scripts/stage_bundle.sh`, once, for both. Notes =
`packaging/RELEASE_NOTES_HEADER.md` + generated changelog. Never bundle a vendor CAN DLL
(ROADMAP has the list and the reason). The maintainer walkthrough is
[docs/releasing.md](docs/releasing.md).

CI (`.github/workflows/`) runs `v -enable-globals test modules/`, `scripts/runtests.sh` and
`scripts/vcan_common_test.sh` (the shared setup-script answers — whose home under sudo, is vcan
available — driven through stubbed `getent`/`id`/`ip`/`sudo`, so it runs unprivileged). `windows.yml`
additionally downloads a prebuilt V toolchain from this repo's **`v-toolchain` release** — if that
release or its `v-ddc9c99-windows.zip` asset disappears, the Windows job breaks.

## Conventions

- **Every module GUI-free and unit-tested.** New protocol work starts in `modules/` with tests.
  This is the one architectural rule, and it cuts both ways: anything that decides what a wire
  format *means* belongs in `modules/`, not in a front end. If the GUI and a CLI tool would each
  have to interpret the same bytes, the interpretation is in the wrong place.
- **Commit identity is enforced, not trusted.** Every commit must be **authored** by
  `marten.hildell@gmail.com`; the committer may also be `noreply@github.com` (GitHub rewrites it
  when you squash-merge in the web UI). CI checks this in
  [`.github/workflows/guard.yml`](.github/workflows/guard.yml) and **fails the build** otherwise —
  a work address once reached this history and had to be rewritten out of every commit. Install
  the local hook so it fails in a second instead of after a push:
  `git config core.hooksPath .githooks`.
- **Commit MESSAGES may not carry email addresses either.** The identity rule above covers
  who commits; the message body is checked separately, because an address written into one is
  permanent — it survives branch deletion and removing it costs a rewrite of every branch that
  carries it. Only the maintainer address and bot trailers (`Co-Authored-By: … <noreply@
  anthropic.com>`, `noreply@github.com`) are allowed; anything else fails the same guard
  workflow. Describe an address instead of quoting it ("a non-maintainer work address"). The
  local hooks cover both the ordinary commit path (`commit-msg`) and cherry-pick/rebase
  (`pre-push`), which git does not route through `commit-msg`.

> **Known non-finding — commit author identity.** A review-tool identity (`codex@openai.com`
> and the like) shows up as the author of a *synthetic* commit that some analysis checkouts
> create locally; it is not in this repository's history. Before reporting one, run both tests:
>
> 1. **Is it real?** `git merge-base --is-ancestor <sha> origin/<branch>` — reachability from
>    the authoritative remote ref, not `git cat-file -e`. Object *existence* proves nothing:
>    in the very checkout that fabricated the commit, `cat-file` succeeds by construction, so
>    that test would confirm the artifact instead of exposing it.
> 2. **What does the guard say?** The `commit-identity` job scans every introduced commit on
>    the real push.
>
> Unreachable **and** the check is green → artifact, drop it. Reachable, or the check is
> failing, pending or absent → a real merge blocker, report it: that is precisely the case
> the guard exists for, and this note must never talk you out of it.
- **External PRs are auto-closed** (design phase — see [`CONTRIBUTING.md`](CONTRIBUTING.md)); the
  same workflow posts a comment pointing at issues. Nothing to do by hand.
- **Work in a worktree, never the main checkout.** `git worktree add .claude/worktrees/<name> -b
  <branch> origin/main` — **fetch first** (`git fetch -q origin`): naming a remote-tracking ref
  does not contact the remote, so a checkout that has not fetched since `main` advanced branches
  from a stale local value and silently omits landed work. And WITH the start point, or it
  branches from whatever the shared checkout happens to be on — the state this rule exists to
  avoid. Sessions run concurrently, and a second one that finds the shared checkout on a
  foreign branch, or mid-rebase, loses work that was not its own. The main checkout stays on
  `main`, clean, for reading and for merges.
- **The order is: build → `/code-review high` → `@codex review`.** Not two of the three, and not
  a different order. Each codex round is a ~10-minute wait, so anything the self-review can find
  is found for free; codex then sees a branch that has already had its obvious problems removed.
  Every round is watched by `scripts/codex_review_watch.sh` in a *tracked* background timer —
  see the note on watchers below.
- **Run `/code-review high` on the branch BEFORE asking codex.** Self-run, high effort; not the
  billed cloud `/code-review ultra`, which only the maintainer triggers. Precedent:
  `docs/history.md` 2026-06-21, where a self-run high review of gui#65 found a real bug the
  change had introduced and led to a rework — that is the standard this repo already set.
  Codex is a second opinion, not the first one. A round trip costs ~10 minutes and the same
  defect found late costs a rewrite: #84 ran to nine rounds and 34 findings, and its repeats —
  an interface string standing in for a channel identity, four separate times; a handler moved
  into a shared module and then duplicated in the GUI a round later; an unlocked read of an
  array another thread replaces — were all visible in the diff without running anything.
  Look for exactly those: shared state touched from more than one thread, a lookup substituting
  for an identity, a policy that now lives in two places, and a claim in a doc the change just
  made false.
- **This file is not loaded for you automatically.** Sessions usually start in `blobly_emb`,
  which makes this repo an *additional* working directory — its `CLAUDE.md` never enters context
  on its own. Read it before the first change here. An entire session (PRs #79–#84) ran without
  it and broke two of the rules below in silence.
- **And read the CURRENT one — `git fetch -q origin && git show origin/main:CLAUDE.md`.** The
  main checkout is a shared working copy that other sessions leave behind; the copy sitting in
  it can be many commits old, and nothing about reading it says so. This guide is where the
  hard-won operational detail lives, so a stale copy is not a stale summary — it is a *confident
  wrong answer* about the thing you are least able to verify from the outside.
  Concretely, in the session that added this bullet: the checkout was four commits behind, the
  polling section it served predated net#110/#116, and the watcher built from it read only
  `pulls/N/reviews`. Findings arrive there, so it looked like it worked for four rounds — but a
  **clean** verdict lands in `issues/N/comments`, so it could never have reported one, and
  "iterate until clean" had no way to terminate. Every fact needed was already written down, one
  `git show` away. Re-read it the same way whenever you pick work back up after a gap; other
  sessions land PRs into this file while you are working.
- **PRs get `@codex review`**; iterate until clean before merging. Before the first request,
  run `scripts/review_preflight.sh`. Start each round with
  `scripts/request_codex_review.sh <pr> --post`, then run the printed
  `scripts/codex_review_watch.sh --state ...` command as a
  **tracked** background job, never a detached shell (`( ... & )`) — a detached watcher fires
  into nothing and the round sits unread. Two reviews were missed that way in one session, one
  of them for over an hour. Match the verdict by the head SHA codex names, not by its wording:
  phrase-matching missed "Didn't find any major issues" more than once.
- **When findings repeat in one path, write the test — do not stop the review.** "Iterate
  until clean" is right; what it lacks is a response to rounds that keep landing in the same
  uncovered place. When consecutive rounds find defects introduced by the previous round's fix,
  and they cluster, the loop is designing an untested path one repair at a time: cover that path
  with a test, which ends the repeats at their source. A round count is the wrong instrument —
  #84's nine rounds were nine rounds of real findings and were worth every one.
  On net#114, rounds 5–7 were three consecutive regressions-of-fixes in mid-run channel
  enable/disable, which looked exactly like a loop feeding on itself; the session drafted this
  very rule to end it. **Round 8 then found a listen-only channel that transmits — a safety
  promise the GUI made and the backend could not keep, in the original work, not in any fix.**
  Stopping one round earlier would have shipped it. Judge each finding on its merits; let
  repetition tell you what to test, not when to quit.
- **React 👍/👎 on every finding.** Codex's footer asks "Useful? React with 👍 / 👎", and that is
  the only channel the review has for learning what it got right; leaving it empty tells it
  nothing, round after round. `gh api -X POST repos/<o>/<r>/pulls/comments/<id>/reactions -f
  content='+1'` (or `'-1'`). **What the reaction rates is whether the FINDING is true, not
  whether you liked the remedy and not whether you are going to act on it here:**

  | the finding is… | react | and |
  |---|---|---|
  | a real defect you reproduced, or one plainly derivable from the code | 👍 | fix it |
  | real, but **pre-existing** — it is not this PR's doing | 👍 | file an issue; say which, so it is not lost when the branch is |
  | real, but the suggested **fix** is wrong or too narrow | 👍 | fix it your way and say why the shape differs |
  | real, and caused by **your own previous round's fix** | 👍 | the strongest signal you get — see the repeat rule above, and go after the class |
  | a claim you **checked and it does not hold** | 👎 | one line of evidence; never a silent dismissal |
  | an artifact of the review's own checkout (see the commit-identity note above) | 👎 | run both of that note's tests first |
  | style with no defect behind it | 👎 | say so plainly |
  | something you **cannot yet tell** | *wait* | investigate, then react — a reaction you have to take back is worse than a late one |

  Then reply once with a table of the round's disposition (finding · reaction · what happened),
  so the maintainer can read it without opening every thread. A 👎 costs a sentence of reasoning;
  "judge each finding on its merits" cuts both ways, and a round where every row is 👍 is worth
  noticing rather than assuming.

  **This is the opposite direction from the reaction rule below.** WRITING a reaction is feedback
  to codex and is expected of you. READING codex's 👍 as the verdict is what cannot be made to
  work — the payload carries no reviewed SHA, and GitHub will not re-create an identical
  reaction, so it can never look fresh. Write them; never read them.
- **Update this file in the PR that lands the work** — especially new modules/panels. The gap
  between 2026-07-06 and 07-21 (~30 PRs) had to be reconstructed from `git log`; don't repeat it.
- **Cross-repo:** the SUT side is **blobly_emb** — see
  [`docs/blobly_emb_synergies.md`](docs/blobly_emb_synergies.md). Wire formats (trace records,
  SOME/IP datagrams, telemetry) are pinned by golden vectors on both sides; change them together.

### Polling a codex review

A watcher that reports "nothing" when something is waiting is worse than no watcher. Every rule
here exists because a silent version of it lost a review; the incidents are in
[`docs/history.md`](docs/history.md).

Do not hand-roll the polling in a shell fragment. `scripts/request_codex_review.sh <pr> --post`
is a thin wrapper over `scripts/codex_review.py`: it posts the request, records the PR head SHA,
records the request comment marker and fresh baselines for the GitHub id spaces, and
`scripts/codex_review_watch.sh --state .claude/reviews/pr-<pr>.env` reads the verdict channels
as GitHub JSON rather than shell-scraped text. Its fixtures are in
`scripts/codex_review_watch_test.sh` and run in CI; update those fixtures when the GitHub/Codex
response shape changes.

- **`--paginate` everything**, but for two different reasons. Comments come back **ascending**,
  30 per page, so an un-paginated read drops the **newest** — the ones you are waiting for.
  `commits/<sha>/check-runs` is ordered by id **descending**, so there an un-paginated read keeps
  the newest page and drops **older** runs — a long-running job from an earlier workflow can be
  the one still pending. Either way the first page is not the answer. `--paginate` emits one
  page per line, so sum with `| awk '{s+=$1} END{print s+0}'` — not `bc` (absent in some agent
  environments), and not `--slurp` (gh refuses it alongside `--jq`). **Capture gh's exit status
  before the pipe**: on an auth or API failure gh returns 1 or 4 and prints nothing, `awk` then
  prints `0` and exits 0, and the result reads exactly like "nothing is waiting". Assign first,
  check `$?`, report the failure instead of a count. And `commits/<sha>/check-runs` pages are
  **objects**, not arrays — use `.check_runs | length` (or `.check_runs[]` to list); the array
  recipe would count an object's keys.
- **`gh api --jq` takes exactly one argument.** jq's own flags (`--arg`) make it exit 1 with no
  stdout, so the filter returns nothing and the channel looks empty. Interpolate instead.
- **Do NOT use the 👍 reaction as the verdict**, despite codex's footer saying "otherwise it
  will react with 👍". It cannot be made reliable: the reaction payload carries **no reviewed
  SHA**, so a fresh `+1` may belong to the previous head if the head moved while the review ran;
  and GitHub will not create a second identical reaction from the same actor, so on a later
  clean round the existing one keeps its ORIGINAL timestamp and no freshness test can ever pass.
  Both directions are broken, in opposite ways. Observed on net#84: the clean result arrived as
  a 👍 **and** as a comment naming the head, one second apart — the comment is the signal.
- **Flatten a comment body before matching it.** `Reviewed commit:` sits in the MIDDLE of a
  multi-line body, so piping it through `tail -1` matches against the footer and never fires.
  `gsub("\n";" ")` it into one line, id-prefixed, and take the highest id.
- **Never edit a watcher script while an instance is running.** bash reads a script
  incrementally, so the running copy executes half of the new file and dies on a comment.
  Write a new file instead.
- **The verdict channel depends on the OUTCOME. Read both, or you see half the answers:**

  | outcome | where | match on |
  |---|---|---|
  | findings | `pulls/N/reviews` | `**Reviewed commit:** \`<sha>\`` in the body |
  | **clean** | `issues/N/comments` or `pulls/N/reviews` | `**Reviewed commit:** \`<sha>\`` in the body |
  | failed | `issues/N/comments` | "Something went wrong" — re-request, do not wait |

  Watching either endpoint alone is silent about the other's outcomes, and both failures look
  identical from outside: nothing arrives. `pulls/N/comments` holds the findings themselves
  (review-attached comments appear there too, so summing with `pulls/N/reviews/<id>/comments`
  double-counts).
- **Match the SHA with a plain `grep -F`** on the flattened body. It sits inside markdown
  (`**Reviewed commit:** \`abc…\``), so a regex expecting `Reviewed commit: <sha>` finds nothing.
- **Findings can arrive in the review BODY, not only as inline comments.** A body carrying a
  `P1`/`P2` badge or a `/blob/<sha>/file#L…` link is NOT clean, whatever the comment count says.
- **Review-comment ids and issue-comment ids are different id spaces.** A baseline taken from one
  and compared against the other never matches, so the count sits at 0 forever.
- **A "review failed" scan needs its own baseline too**, or one historical failure fires on every
  later run.
- **Give a crash and a real failure different exit codes.** bash exits 2 on a syntax error; a
  watcher using 2 for "review FAILED" cannot tell the two apart, and reports a failure that never
  happened.
- **Identify a result by head SHA prefix AND a freshness baseline.** Codex names a 10-char
  abbreviated SHA, so a 40-char compare never matches; but a retry after a failed review names
  the *same* SHA as the failure, so record the highest comment/review id first and require the
  match to beat it. Never match on wording.
- **A force-push during a pending review gets you a verdict for the OLD commit.** Codex answers
  for the SHA it started on, so after an amend or rebase its "no major issues" names a commit
  that is no longer on the branch. Observed on emb#255: clean on `a1d3c667` while the head was
  `d052f77`. This is exactly why the verdict is matched by head SHA — re-request after any push
  rather than accepting it.
- **Test the watcher against a state whose answer you already know**, and print per-channel
  counts. These failures are invisible from the outside — a command that succeeds and returns
  nothing looks exactly like no news.
- Run it as a **tracked** background job, never a detached shell (`( ... & )`). A cron sweep
  over every open PR is the backstop for when the watcher itself is wrong.

## Gotchas

**Read [`docs/known_issues.md`](docs/known_issues.md) first when something breaks** — it is the
categorised list (V / GUI / environment / CI). Two that bite newcomers:

- **WSLg + GL:** hardware GL works on Ubuntu 24.04 + Mesa 25.x; older Mesa crashed the GPU path.
- **Native Windows** is a separate toolchain (MSYS2/mingw). `.github/workflows/windows.yml` is
  the reproducible recipe — it builds the shipped bundle on every push; there is no hand-written
  walkthrough to drift from it.
- **Working from Windows, type-check the OTHER platform before you push:**
  `v -os linux -enable-globals -path "@vlib|@vmodules|modules|libs" -check cmd/blobly_net`.
  The per-platform backends (`vector_windows.v` / `vector_linux.v`, and the `discover_*` pair)
  are two files that must offer the SAME symbols, and a Windows bench compiles only one of them —
  so a helper added beside the driver and called from the cross-platform GUI builds perfectly
  here and fails the Linux job ten minutes later. That is a ~10-minute round trip for something
  `-check` finds in seconds without GLFW, FreeType or a linker. It caught `vector_borrow_lock_now`
  exactly this way (#192), after CI did.
  **It catches missing SYMBOLS, not different BEHAVIOUR** — and the difference has its own trap.
  `vendor_iface` is `$if windows`, so `vector:1` and `vector:ch1` are one wire here and two
  ordinary SocketCAN names on Linux; a test asserting the Windows answer compiles and passes on
  this bench and fails the Linux job (#202). Anything keyed through `wire_key`,
  `destination_key` or `vendor_iface` needs a `$if windows` guard in the test, or an assertion
  that holds on both — `inproc:` buses behave the same everywhere and are the safe way to pin the
  rule itself.

## Docs

- [scripting.md](docs/scripting.md) · [dbc_editor.md](docs/dbc_editor.md) ·
  [project_editing.md](docs/project_editing.md) · [bus_config_dialog.md](docs/bus_config_dialog.md)
- **Fault injection** (`modules/sim/fault.v`): drop / bad_crc / freeze_counter / out_of_range
  per message, from the Simulation panel or `sim.fault(channel, node, message, kind, ms)` in
  Lua. Applied around protection, not after it — `out_of_range` goes on BEFORE the checksum is
  stamped (so the receiver reaches its range handling instead of rejecting a CRC error) and
  `bad_crc` after. One process-wide table (`sim.inject`), keyed by interface+node+message, so
  the panel and scripts cannot disagree. A fault that cannot take effect is refused loudly.
- **Silence** (`cmd/blobly_net/stale.v`): CAN has no link detection, so a *receiver* cannot tell
  a disconnected bus from an idle one — on any vendor. The only honest signal is that traffic
  which was arriving has stopped — so each wire reports `last RX 45s` (dim, in the toolbar and on
  its Buses row) from its own last RECEIVED frame. Our own sends do not count, or anything this
  host transmits would keep a dead wire looking alive; it is folded per DESTINATION like `health`
  is, and handed to the successor when a reader moves, because only the reader-owning alias
  records it. **It states a fact and makes no judgement**, deliberately: three attempts to decide
  whether silence was a FAULT were each taken apart by the same counter-example (five diagnostic
  requests a second apart), because "traffic that stopped" and "traffic that finished" are
  identical on the wire and no amount of observing separates them. Only a declaration can — a
  DBC's `GenMsgCycleTime` — and that alarm is not built yet. The controller's fault ladder is the
  other half and IS a judgement, because the driver made it: that one stays coloured.
- [simulation.md](docs/simulation.md) — the simulation user manual (rest-bus, generators,
  senders, replay, end-to-end protection) ·
  [doip.md](docs/doip.md) — the DoIP user manual (supported vs planned) ·
  [ethernet_architecture.md](docs/ethernet_architecture.md) ·
  [simulation_architecture.md](docs/simulation_architecture.md) ·
  [blobly_emb_synergies.md](docs/blobly_emb_synergies.md)
- [can_hardware.md](docs/can_hardware.md) · [windows_can_hardware.md](docs/windows_can_hardware.md) ·
  [known_issues.md](docs/known_issues.md)
- [../ROADMAP.md](ROADMAP.md) — what's next and planned (shipped list kept last)
- [history.md](docs/history.md) — archived status log (not maintained)
