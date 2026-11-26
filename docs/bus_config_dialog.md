# Bus Configuration dialog — design (network hardware configuration)

A GUI front-end for setting up channels by **discovering** the available interfaces,
ticking the ones you want and adding them to the project (editing them afterwards in the
Configuration editor; the inline grid edit sketched below did not ship) — the
same idea as a network hardware configuration dialog. The GUI-free seam already
exists (`transport.local_interfaces()`, `blobly/transport/interfaces.v`, over
`list_interfaces()` in `discover*.v`); this is the visual layer on top.

## Status

- ✅ **Shipped** — the Configuration editor has **Discover…**, which opens a "Discover
  interfaces" window (Refresh, + vcan, + Sim net, tick rows, **Add ticked**, and a Vector
  application-channel assignment section). It is a floating window, not a modal. USB CAN
  pass-through into WSL is a script, `scripts/usbip.sh`, not a GUI button. Attached
  **CANsub** devices are listed too, a row per channel, found by an mDNS browse for
  `_cansub._tcp` (#235) — on both platforms, since a CANsub is a network device. **DoIP
  entities** have their own section: a host field, **Ask host** (a vehicle identification
  request to that address) and **Find on network** (the same request to the IPv4 broadcast
  address); each entity that answers is a row (address, logical address, VIN) that **Add ticked**
  turns into a `doip` channel — named after the VIN, ECU address the found one, tester the one the
  project's `system.toml` lets in at that entity, else 0x0E80.
  A DoIP bus row has the same lookup as its **entity** picker. On WSL, answers to a broadcast may
  be dropped (they come from an address this host never sent to); asking the address works.
  On Windows with WSL, a **WSL (CAN bridge)** section starts `canbridge` in a distribution, and
  its CAN interfaces join the list as `bridge:<distro>/<iface>` rows ([wsl_bridge.md](wsl_bridge.md)).
  A **CAN bridges on the LAN** section says where the listener a bridge dials is (or that it is
  not listening — `BLOBLY_BRIDGE_LISTEN` / `BLOBLY_BRIDGE_TOKEN` set it), lists each connected
  bridge with its channel count, and each that dialled in to say why it could not start; their
  channels join the list too.
  **Add ticked** closes the dialog once it has added something.
  The dialog stays open across Start and can be opened mid-run (the Configuration editor offers
  only Discover… then): looking works, while the add buttons and Vector **Assign** wait for Stop.
- 🔶 **Partly shipped** — the dialog and Add-to-Project exist; inline per-row edit
  (name / mode / DBC) in the grid does not.
- 🔜 **Part B** — the DBC→generators scaffolder as a second section of the same dialog.

## The dialog

```
┌─ Bus / Channel Configuration ─────────────────────────────────┐
│  [ Refresh ] [ + vcan ] [ + Sim net ]        (design sketch)   │
│                                                                │
│  ✓  Name   Interface            Type  Bitrate  Mode     DBC    │
│  ──────────────────────────────────────────────────────────── │
│  ☑  CAN1   vcan0                can   500000   monitor  cant…  │
│  ☑  CAN2   can0                 can   500000   monitor  —      │
│  ☐  —      udp:239.0.0.1:5000   can   —        monitor  —      │
│  ☐  —      inproc:SIM           can   —        monitor  —      │
│                                                                │
│                                          [ Add ticked ]        │
└────────────────────────────────────────────────────────────────┘
```

**Discover** calls `transport.local_interfaces()` — on Linux every CAN link in
`/sys/class/net` (down ones too), merged with `list_interfaces()`, which parses `ip -details
-json link show` (reads the real bitrate); on Windows `list_interfaces()` queries the vendor
DLLs (Kvaser, PCAN, Vector); both append the virtual `udp:`/`inproc:` options — and fills the
grid, a connected bridge's channels with it. CANsub devices come from a separate mDNS browse
(`transport.discover_cansub()`, ~0.7 s) that Refresh and opening the dialog start on their own
thread, with "browsing…" shown until it lands and the reason shown if it could not look. Tick
the ones you want and press **Add ticked**: each becomes a row named from its address; name,
mode, bitrate and DBC are then edited in the Configuration editor's rows.
**Refresh** re-scans (e.g. after `ip link add vcan1`).

**Where the YAML write happens:** the dialog only edits the in-memory `Project` →
the Buses panel updates live → it lands in the `.blobnet` on **File ▸ Save** (the project
file stays the single source of truth; discovery never clobbers the file behind your
back — you see it, then save).

**Entry points:** File ▸ Configure…, View ▸ Configuration, the activity bar's **Cfg**, or
**Configure…** on the Buses panel open the editor; **Discover…** is inside it.

## Part B — scaffold a simulated node from a DBC (same dialog, second section)

Once a channel has a DBC, the dialog gains a *Simulate node ▸ scaffold from DBC*
section: it lists the node's signals with auto-picked generators in an editable grid,
and **Add** writes the `nodes:`/`signals:` block. One dialog, two scaffolders, both on
the GUI-free core (`blobly/sim` generators + the `Iface`/`channels_yaml` seam).

## Toolkit note

Shipped as a Dear ImGui dialog through `libs/vgui` (`vgui.begin_dialog`: not docked, and kept
inside the main window), which exposes `table_*` rather than a grid widget — the old `vlang/gui`
"data_grid / modal overlay" question this section used to ask is settled.

## SOME/IP listener rows

Pick the `someip` adapter and put the **bind** `host:port` in the address field — `0.0.0.0:30491`
to hear an emb node that publishes to port 30491 on this host, or the port a foreign service
publishes on. The wildcard is the default because a listener wants every interface. Beside it,
Configure offers a **group**: a multicast address joined on that socket, which is what hearing a
service's multicast events or a SUT's SD offers takes; empty hears unicast to the address only.
No protocol, bitrate or listen-only tick: nothing is sent on this row, and it is not a CAN wire.
On ▶ Start the row goes green when its socket is bound.

**Which interface a group is joined on** is **join on** (`group_iface:` in the file, schema
v15): the interface's name (`eth1`; on Windows its name as the network settings show it,
`Ethernet 2`, or its adapter GUID) or an address it holds (`192.168.10.2`). Empty joins on the
host's default-route interface, so on a machine with more than one interface (a bench NIC beside
a WSL or VPN one) a service offering on the other NIC is not heard until the row names it. An
interface this host does not have fails the row at ▶ Start, naming the interfaces it has, and so
does an address two interfaces hold. Binding the specific address instead does not select a NIC
and is refused: a socket bound to one address receives no multicast at all.

**A bound UDP port is not an owned one.** This V sets `SO_REUSEADDR` on every UDP socket before
it binds, and nothing in its public API turns that off, so a second listener on the same port
binds successfully and the kernel then delivers each unicast datagram to exactly ONE of the two
sockets. A green row therefore means "we are reading this endpoint", not "we are the only
reader". If a second blobly_net, a vsomeip tool or another copy of this project holds the same
port, each sees part of the stream and neither is told. The DoIP entity's "cannot bind" rule
does not carry over: that one listens on TCP, where a second listener really is refused.

Within one blobly_net, though, it IS settled: every listener claims its endpoint first, so a
script window and a channel row cannot end up on the same port whichever of the two starts
first. The second one is refused and told which holds it — the Log names the script, or the
script's error names the channel. Across processes nothing can do that, which is what the
paragraph above is about.

And messages on this row are shown in the trace but are **not recorded**: a recording holds CAN
frames, so the Log says so once when Record is on.
