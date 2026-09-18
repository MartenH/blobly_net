# Bus Configuration dialog — design (network hardware configuration)

A GUI front-end for setting up channels by **discovering** the available interfaces,
ticking the ones you want and adding them to the project (editing them afterwards in the
Configuration editor; the inline grid edit sketched below did not ship) — the
same idea as a network hardware configuration dialog. The GUI-free seam already
exists (`transport.list_interfaces()` / `channels_yaml()`, `modules/transport/
discover*.v`); this is the visual layer on top.

## Status

- ✅ **Shipped** — the Configuration editor has **Discover…**, which opens a "Discover
  interfaces" window (Refresh, + vcan, + Sim net, tick rows, **Add ticked**, and a Vector
  application-channel assignment section). It is a floating window, not a modal. USB CAN
  pass-through into WSL is a script, `scripts/usbip.sh`, not a GUI button. Attached
  **CANsub** devices are listed too, a row per channel, found by an mDNS browse for
  `_cansub._tcp` (#235) — on both platforms, since a CANsub is a network device.
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

**Discover** calls `transport.list_interfaces()` — Linux parses `ip -details -json
link show` (finds vcan0/can0, reads the real bitrate), Windows queries the vendor DLLs
(Kvaser, PCAN, Vector) and appends the virtual `udp:`/`inproc:` options — and fills the grid;
CANsub devices come from a separate mDNS browse (`transport.discover_cansub()`, ~0.7 s) that
Refresh and opening the dialog start on their own thread, with "browsing…" shown until it lands
and the reason shown if it could not look
with candidates pre-filled (name from
the iface, bitrate read off a configured `can0`). Tick the ones you want and press
**Add ticked**; name, mode and DBC are then edited in the Configuration editor's rows.
**Refresh** re-scans (e.g. after `ip link add vcan1`).

**Where the YAML write happens:** the dialog only edits the in-memory `Project` →
the Buses panel updates live → it lands in the `.yml` on **File ▸ Save** (the project
file stays the single source of truth; discovery never clobbers the file behind your
back — you see it, then save).

**Entry points:** File ▸ Configure…, View ▸ Configuration, the activity bar's **Cfg**, or
**Configure…** on the Buses panel open the editor; **Discover…** is inside it.

## Part B — scaffold a simulated node from a DBC (same dialog, second section)

Once a channel has a DBC, the dialog gains a *Simulate node ▸ scaffold from DBC*
section: it lists the node's signals with auto-picked generators in an editable grid,
and **Add** writes the `nodes:`/`signals:` block. One dialog, two scaffolders, both on
the GUI-free core (`modules/sim` generators + the `Iface`/`channels_yaml` seam).

## Toolkit note

Shipped as a floating Dear ImGui window through `libs/vgui`, which exposes `table_*` rather
than a grid widget and has no modal wrapper — the old `vlang/gui` "data_grid / modal overlay"
question this section used to ask is settled.

## SOME/IP listener rows

Pick the `someip` adapter and put the **bind** `host:port` in the address field — `0.0.0.0:30491`
to hear an emb node that publishes to port 30491 on this host, or the port a foreign service
publishes on. The wildcard is the default because a listener wants every interface. Beside it,
Configure offers a **group**: a multicast address joined on that socket, which is what hearing a
service's multicast events or a SUT's SD offers takes; empty hears unicast to the address only.
No protocol, bitrate or listen-only tick: nothing is sent on this row, and it is not a CAN wire.
On ▶ Start the row goes green when its socket is bound.

**Which interface a group is joined on.** The join goes to the host's default-route interface,
and a group needs the wildcard bind address, so on a machine with more than one interface (a
bench NIC beside a WSL or VPN one) a service offering on the other NIC is not heard and the row
sits green and empty. Binding the specific address instead does not help and is refused: a socket
bound to one address receives no multicast at all. Selecting the interface per channel is not
built yet.

**A bound UDP port is not an owned one.** This V sets `SO_REUSEADDR` on every UDP socket before
it binds, and nothing in its public API turns that off, so a second listener on the same port
binds successfully and the kernel then delivers each unicast datagram to exactly ONE of the two
sockets. A green row therefore means "we are reading this endpoint", not "we are the only
reader". If a second blobly_net, a vsomeip tool or another copy of this project holds the same
port, each sees part of the stream and neither is told. The DoIP entity's "cannot bind" rule
does not carry over: that one listens on TCP, where a second listener really is refused.

Two consequences worth knowing. A script must not listen on a port a running row already holds —
`someip.listen({ from = … })` refuses that by name while the run is on, because splitting the
stream silently is worse than saying no. And messages on this row are shown in the trace but are
**not recorded**: a recording holds CAN frames, so the Log says so once when Record is on.
