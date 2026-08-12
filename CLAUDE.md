# Blobly Net (V) — project guide for coding agents

> `AGENTS.md` is a symlink to this file: one guide for **any** agent (Claude Code reads
> `CLAUDE.md`, Codex and others read `AGENTS.md`). Edit only this file.
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
sudo ./scripts/setup_sudoers.sh   # optional: scoped passwordless sudo (apt-get/ip/modprobe)
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
- **CAN:** SocketCAN on Linux (`vcan0` virtual, or any adapter); **PCAN** and **Kvaser** on
  Windows (vendor DLLs loaded at runtime, both HW-verified). No Vector backend. All behind the
  `transport` interface, so backends are drop-in.
- **Engine stays GUI-free.** CAN/protocol logic lives in `modules/` with no GUI imports, so it is
  independently testable and the GUI stays replaceable. This is the one architectural rule.
- **Projects** are `.blobnet` files (YAML content) describing buses, channels and databases.

## Layout

```
cmd/blobly_net/     the GUI (Dear ImGui + ImPlot)   <- the app
cmd/*                CLI tools + smoke tests (flash, dbc_decode, mf4_dump, trace_dump, ...)
libs/vgui/           the V wrapper around Dear ImGui/ImPlot
modules/             engine (GUI-free, unit-tested)
scripts/             setup, run, test, packaging
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
| `transport` | Bus/Channel interface + SocketCAN, PCAN (Windows), UDP software bus |
| `candb` | DBC parse/decode/encode + canonical writer (`dbc_write.v`) |
| `isotp` | ISO-TP (ISO 15765-2) transport |
| `uds` | UDS diagnostic client over ISO-TP |
| `doip` | DoIP (ISO 13400) — UDS over TCP; same shape as `isotp.Channel`. Entity (server) side too: ▶ Start hosts one per configured channel, in the GUI and headless |
| `someip` | SOME/IP header codec, envelope validation, `RpcClient` |
| `flash` | UDS firmware-download session against a blobly_emb bootloader (0x29 auth) |
| `sim` | simulated ECUs — tests need no hardware; `doip_entity.v` decides what a DoIP channel hosts and `doip_host.v` is the served-side handler, both shared by the GUI and the headless runner |
| `player` | replay a recording at its recorded cadence |
| `canlog`, `mf4` | `candump -l` files; native ASAM MDF4 (`.mf4`) reader |
| `telem` | trace + telemetry capture control |
| `sysview` | read-only system model behind the System panel (reads blobly_emb `system.toml`) |
| `script`, `lua` | embedded Lua + the test-framework prelude |
| `project` | `.blobnet` project files |
| `sampledb` | hand-coded message catalog (superseded by DBC loading) |

## Build / run / test

```sh
./scripts/run_gui.sh                       # GUI
v -path "@vlib|@vmodules|modules" run cmd/<tool>/<file>.v   # any other target
v -enable-globals test modules/             # unit tests — the reliable backbone (32/32)
./scripts/runtests.sh tests/diag_basic.lua  # headless Lua integration tests (in-process sim)
```

CI (`.github/workflows/`) runs `v -enable-globals test modules/` plus `scripts/runtests.sh`. `windows.yml`
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
  <branch> origin/main` — WITH the start point, or it branches from whatever the shared checkout
  happens to be on, which is the state this rule exists to avoid. Sessions run concurrently, and a second one that finds the shared checkout on a
  foreign branch, or mid-rebase, loses work that was not its own. The main checkout stays on
  `main`, clean, for reading and for merges.
- **The order is: build → `/code-review high` → `@codex review`.** Not two of the three, and not
  a different order. Each codex round is a ~10-minute wait, so anything the self-review can find
  is found for free; codex then sees a branch that has already had its obvious problems removed.
  Every round is watched by a *tracked* background timer — see the note on watchers below.
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
- **PRs get `@codex review`**; iterate until clean before merging. Watch each round with a
  **tracked** background job, never a detached shell (`( ... & )`) — a detached watcher fires
  into nothing and the round sits unread. Two reviews were missed that way in one session, one
  of them for over an hour. Match the verdict by the head SHA codex names, not by its wording:
  phrase-matching missed "Didn't find any major issues" more than once.
- **Update this file in the PR that lands the work** — especially new modules/panels. The gap
  between 2026-07-06 and 07-21 (~30 PRs) had to be reconstructed from `git log`; don't repeat it.
- **Cross-repo:** the SUT side is **blobly_emb** — see
  [`docs/blobly_emb_synergies.md`](docs/blobly_emb_synergies.md). Wire formats (trace records,
  SOME/IP datagrams, telemetry) are pinned by golden vectors on both sides; change them together.

## Gotchas

**Read [`docs/known_issues.md`](docs/known_issues.md) first when something breaks** — it is the
categorised list (V / GUI / environment / CI). Two that bite newcomers:

- **WSLg + GL:** hardware GL works on Ubuntu 24.04 + Mesa 25.x; older Mesa crashed the GPU path.
- **Native Windows** is a separate toolchain (MSYS2/mingw). `.github/workflows/windows.yml` is
  the reproducible recipe — it builds the shipped bundle on every push; there is no hand-written
  walkthrough to drift from it.

## Docs

- [scripting.md](docs/scripting.md) · [dbc_editor.md](docs/dbc_editor.md) ·
  [project_editing.md](docs/project_editing.md) · [bus_config_dialog.md](docs/bus_config_dialog.md)
- **Fault injection** (`modules/sim/fault.v`): drop / bad_crc / freeze_counter / out_of_range
  per message, from the Simulation panel or `sim.fault(channel, node, message, kind, ms)` in
  Lua. Applied around protection, not after it — `out_of_range` goes on BEFORE the checksum is
  stamped (so the receiver reaches its range handling instead of rejecting a CRC error) and
  `bad_crc` after. One process-wide table (`sim.inject`), keyed by interface+node+message, so
  the panel and scripts cannot disagree. A fault that cannot take effect is refused loudly.
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
