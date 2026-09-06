# DBC editor — design

> Status: P1 SHIPPED (2026-07-20): the candb serializer (net#50) and the
> editor panel (this PR). System viewer/wizards are roadmap (§ below),
> deliberately NOT editors.
>
> An **ARXML-backed** database (a `databases:` entry ending in `.arxml`, #272) opens in the
> editor **read-only**: Save serialises DBC text to the selected path, and that path is the
> customer's system description. Export with `cmd/arxml2dbc` and edit the DBC it produces.

## The one idea

The editor's killer feature is live decode: **edit a signal next to the live
trace and watch real traffic re-decode instantly**. It opens as a floating
window (an editor wants room a dock tab beside small monitors cannot give);
drag it into the dock next to the Trace when you want the side-by-side loop,
or clean out of the app onto another monitor — both stick. CANdb++ and the
free alternatives all make DBC authoring a dead loop (edit → save → restart →
replay); blobly_net already has live decode against loaded `candb.Database`s
— the editor closes the loop by making those databases writable. Everything
else (forms, validation, the bit grid) is table stakes.

## The write half: canonical serialization (`candb.to_dbc`)

`candb` was parse-only; the editor needs the inverse. The serializer emits the
exact record subset the parser reads — `BU_`, `BO_`, `SG_` (incl. mux
markers), `CM_ SG_`, `VAL_`, `BA_ "GenMsgCycleTime"` (+ its `BA_DEF_`) and the
standard preamble — in **canonical order**: messages by id, signals by
start_bit then name, value-table keys ascending, nodes sorted. Two laws, both
tested (`dbc_write_test.v`):

- **round trip**: everything the parser models survives write→parse — ids
  (incl. the EFF high bit on extended ids), layout, order/sign, scaling,
  ranges, units, comments, value tables, multiplexing, senders, cycle times;
- **fixpoint**: `to_dbc(parse_dbc(to_dbc(db))) == to_dbc(db)` — an editor
  save/load cycle can never drift a file, and canonical order means a git
  diff shows real changes only (the file stays PR-reviewable — the same
  config-as-text discipline as everything else).

Embedded double quotes in units/comments/labels are sanitized to single
quotes: the DBC record format cannot carry them and a writer must never emit
a file its own parser rejects.

## P1 — the editor panel (shipped)

A dockable blobly_net panel, the Shell-panel precedent:

- message list → signal table → edit forms (name, id/ext, dlc, sender, cycle;
  start/length/order/sign, factor/offset, min/max, unit, desc);
- the **bit-matrix grid** — 8×DLC cells, each signal's span colored, Intel and
  Motorola sawtooth rendered honestly — with **overlap detection** and
  out-of-frame errors inline (this visual is 80% of why people tolerate
  CANdb++);
- save = `to_dbc` to the loaded path; the trace panel re-decodes against the
  edited database immediately (same in-memory `dbs` — no reload step);
- unsaved-changes marker + revert; no autosave (the file is git-tracked).

The editor is READ-ONLY while a measurement runs: rx/sim/generator workers
read the databases lock-free, and saving rebuilds runtime caches — both are
only safe stopped. Editing a stopped capture still re-decodes it live (the
trace decodes signal values at draw time), so the live loop survives.

Value-table and multiplexing editing have since landed. Out of P1 scope and still absent:
J1939 attributes, creating files from scratch (open-and-edit first), and RENAME REFACTORING —
renaming a message/signal does not retarget project generators that reference
the old name (they fail loud with "message not in any DBC"); a
rename-aware sweep over the sender model is its own rung.

## Roadmap: system VIEWER, not a system editor

`system.toml`/`ecu.toml` are the opposite file class from DBC: hand-written,
comment-rich, PR-reviewed — and their validation brain (ecucheck/sysmodel)
lives in blobly_emb. A round-tripping TOML editor would destroy comments and
duplicate schema knowledge, so:

- **viewer first — SHIPPED** (modules/sysview + the System panel): reads
  system.toml + node ecu.tomls, derives consumers from the FB reads, and
  renders the communication matrix (P/C, with undeclared writers flagged W?),
  node identities, and per-bus id allocation (DBC frames via candb + NM alive
  ids + diag pairs) with collision highlights. Read-only; no schema
  ownership; degrades gracefully on unreadable node files. Trace-manifest
  rows and a drawn topology graph await the fill_rect binding;
- **wizards second**: "add a signal/frame" generators that emit
  correctly-shaped TOML blocks to append — mutations that never rewrite the
  file, so comments survive and diffs stay clean;
- full graphical TOML editing only if the wizards prove insufficient.
