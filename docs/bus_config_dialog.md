# Bus Configuration dialog — design (network hardware configuration)

A GUI front-end for setting up channels by **discovering** the available interfaces,
ticking the ones you want, editing them inline, and adding them to the project — the
same idea as a network hardware configuration dialog. The GUI-free seam already
exists (`transport.list_interfaces()` / `channels_yaml()`, `modules/transport/
discover*.v`); this is the visual layer on top.

## Status

- ✅ **Incremental version shipped** — the Buses panel has **🔍 Discover** (scan →
  append new channels in-memory; review, then File ▸ Save) and **⚲ USB CAN** (attach
  bound Kvaser/PEAK adapters via `usbipd.exe`). Same `list_interfaces()` module
  underneath as the dialog will use.
- 🔜 **Full modal dialog** (below) — the richer grid with inline edit + Add-to-Project.
- 🔜 **Part B** — the DBC→generators scaffolder as a second section of the same dialog.

## The dialog

```
┌─ Bus / Channel Configuration ─────────────────────────────────┐
│  [ 🔍 Discover ]   (re-scan)                                    │
│                                                                │
│  ✓  Name   Interface            Type  Bitrate  Mode     DBC    │
│  ──────────────────────────────────────────────────────────── │
│  ☑  CAN1   vcan0                can   500000   monitor  cant…  │
│  ☑  CAN2   can0                 can   500000   monitor  —      │
│  ☐  —      udp:239.0.0.1:5000   can   —        monitor  —      │
│  ☐  —      inproc:SIM           can   —        monitor  —      │
│                                                                │
│                                   [ Add to Project ]  [Cancel] │
└────────────────────────────────────────────────────────────────┘
```

**Discover** calls `transport.list_interfaces()` — Linux parses `ip -details -json
link show` (finds vcan0/can0, reads the real bitrate), Windows returns the virtual
`udp:`/`inproc:` options — and fills the grid with candidates pre-filled (name from
the iface, bitrate read off a configured `can0`). Tick the ones you want, edit
name/mode/DBC inline, then **Add to Project**. Re-press to re-scan (e.g. after
`ip link add vcan1`).

**Where the YAML write happens:** the dialog only edits the in-memory `Project` →
the Buses panel updates live → it lands in the `.yml` on **File ▸ Save** (the project
file stays the single source of truth; discovery never clobbers the file behind your
back — you see it, then save).

**Entry points:** a **Bus ▸ Configure…** menu item, and/or the **🔍 Discover** button
already in the Buses panel header opens it.

## Part B — scaffold a simulated node from a DBC (same dialog, second section)

Once a channel has a DBC, the dialog gains a *Simulate node ▸ scaffold from DBC*
section: it lists the node's signals with auto-picked generators in an editable grid,
and **Add** writes the `nodes:`/`signals:` block. One dialog, two scaffolders, both on
the GUI-free core (`modules/sim` generators + the `Iface`/`channels_yaml` seam).

## gui reality check

The table + inline-edit + buttons are already validated (`data_grid`, `cmd/dock_demo`).
The one thing to confirm before building is whether gui offers a true **modal overlay**
or whether we render the dialog as a **floating/centered panel** (gui has no
MessageBox-style modal). Either is fine; just don't assume a blocking modal exists.
