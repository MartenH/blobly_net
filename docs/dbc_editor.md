# DBC editor — design

> Status: P1 SHIPPED (2026-07-20): the candb serializer (net#50) and the
> editor panel (this PR). System viewer/wizards are roadmap (§ below),
> deliberately NOT editors.

## The one idea

The editor's killer feature is the dock it lives in: **edit a signal next to
the live trace and watch real traffic re-decode instantly**. CANdb++ and the
free alternatives all make DBC authoring a dead loop (edit → save → restart →
replay); blobly_vgui already has live decode against loaded `candb.Database`s
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

## P1 — the editor panel (next PR)

A dockable blobly_vgui panel, the Shell-panel precedent:

- message list → signal table → edit forms (name, id/ext, dlc, sender, cycle;
  start/length/order/sign, factor/offset, min/max, unit, desc);
- the **bit-matrix grid** — 8×DLC cells, each signal's span colored, Intel and
  Motorola sawtooth rendered honestly — with **overlap detection** and
  out-of-frame errors inline (this visual is 80% of why people tolerate
  CANdb++);
- save = `to_dbc` to the loaded path; the trace panel re-decodes against the
  edited database immediately (same in-memory `dbs` — no reload step);
- unsaved-changes marker + revert; no autosave (the file is git-tracked).

Out of P1 scope: value-table editing UI, multiplexing UI, J1939 attributes,
creating files from scratch (open-and-edit first) — each lands as its own
rung when wanted.

## Roadmap: system VIEWER, not a system editor

`system.toml`/`ecu.toml` are the opposite file class from DBC: hand-written,
comment-rich, PR-reviewed — and their validation brain (ecucheck/sysmodel)
lives in blobly_emb. A round-tripping TOML editor would destroy comments and
duplicate schema knowledge, so:

- **viewer first**: read system.toml + node ecu.tomls + trace-manifests (which
  now carry the eth/SOME/IP rows) and render what text is bad at — the
  topology graph (nodes ↔ buses ↔ gateway), the communication matrix
  (signals × nodes, producer/consumer), id allocation with collision
  highlights. Read-only; no schema ownership;
- **wizards second**: "add a signal/frame" generators that emit
  correctly-shaped TOML blocks to append — mutations that never rewrite the
  file, so comments survive and diffs stay clean;
- full graphical TOML editing only if the wizards prove insufficient.
