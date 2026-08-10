# DoIP — diagnostics over Ethernet

How Blobly Net talks to a DoIP entity, what goes on the wire, and what is **supported today**
versus **planned**. The split matters: DoIP is further along in the modules than in the GUI,
so a feature you would expect to find in a panel may only exist headless.

For *why* DoIP came before SOME/IP and how the modules are laid out, see the design record in
`docs/ethernet_architecture.md`.

## What works today

| | Status |
|---|---|
| DoIP channel in a project (`doip:<host>:<port>`) | ✅ configuration |
| Discovery of an entity at a **known** address (DoIP panel) | ✅ |
| DoIP entity — discovery, routing activation, UDS | ✅ **headless only** (`cmd/doip_smoke`, the `doip` module) |
| UDS over DoIP end-to-end | ✅ **headless only** |
| **Starting a simulated DoIP entity from the GUI** | 🧭 planned |
| **UDS from the Diagnostics panel over a DoIP channel** | 🧭 planned |
| **Broadcast discovery — finding an entity you were not told about** | 🧭 planned |

Two gaps worth knowing before you plan a bench, both in the **app** rather than the protocol:

- The **Diagnostics panel does not drive a DoIP channel.** It selects a running *monitorable*
  channel, and DoIP channels are excluded from that set.
- The **GUI cannot start a DoIP entity.** `transport.open()` has no `doip:` backend, and a
  project's simulated nodes are driven as CAN, so pressing Start on a DoIP channel does not
  bring an entity up.

Both are app wiring, not protocol limits: `cmd/doip_smoke` runs the whole path — a V tester
against a V entity over real localhost TCP/UDP — and demonstrates the point of the design,
that the same `uds.Client` rides a `DoipClient` unchanged, because only the carrier swapped.

## The short version

| | |
|---|---|
| Port | **13400** by default, for both TCP and UDP — but a channel may use any port |
| TCP | diagnostics — routing activation, then UDS |
| UDP | discovery — vehicle identification and announcements |
| Protocol version | `0x02` (ISO 13400-2:2012) is what we send; `0x03` (2019) also parses |
| Interface string | `doip:<host>:<port>` — e.g. `doip:192.168.0.51:13400` |

## Configuring a channel

Pick the `doip` adapter and put **`host:port`** in the address field — just `192.168.0.51:13400`.
The scheme is added for you; `doip:192.168.0.51:13400` is what you will see in the saved project
file and in the channel list, not what you type.

Alongside it, Configure offers the **tester** and **ECU** logical addresses. That pair is what
actually routes: after routing activation, messages are addressed by logical address, not by IP.

The **VIN** field applies to a *simulated* entity hosted on that channel — it is the identity
your simulated ECU announces. Neither it nor the EID is validated against a real ECU on connect;
they are not client-side expectations.

## Discovering an entity

The DoIP panel takes a host (default `127.0.0.1:13400`), sends a vehicle identification request,
and lists what answers — VIN and logical address per entity.

**It is a unicast request to an address you type.** Nothing is broadcast: the request goes to
that one host, the first reply is taken, and the simulated entity likewise answers only the
sender. So discovery here **confirms an identity you already know**; it does not find entities
you have not been told about.

That asymmetry is worth stating because the ECU side is not the missing half. The companion
firmware (blobly_emb) broadcasts its vehicle announcement three times at boot, per ISO 13400,
and answers identification requests afterwards — precisely so a tester arriving late can still
find it. Blobly Net hears the second of those and not the first: it parses the `0x0004` the
entity sends *in answer to its own request*, which is what makes known-address Discover work at
all. What it misses is the **unsolicited** boot announcement, because it never listens on a
broadcast address, and any **further** replies, because it stops at the first.

The practical consequence: **on Ethernet you must know the address before you can see anything.**
On CAN you attach and observe, because the medium is broadcast. Plan for static addresses or a
DHCP lease you can read. Broadcast discovery is on the roadmap.

## What happens on the wire

Every message is an 8-byte generic header followed by a payload:

```
+--------+--------+--------+--------+--------+--------+--------+--------+
| ver    | ~ver   | payload type    | payload length (4 bytes)          |
+--------+--------+--------+--------+--------+--------+--------+--------+
```

`~ver` is the bitwise inverse of the version, and the parser rejects a header whose two bytes do
not complement each other. We send `02 FD` (2012); `03 FC` (2019) is equally valid and parses,
so treat "a version byte followed by its inverse" as the marker rather than `02 FD` specifically.

| Type | Name | Transport |
|---|---|---|
| `0x0001` | vehicle identification request | UDP |
| `0x0004` | vehicle announcement / identification response | UDP |
| `0x0005` | routing activation request | TCP |
| `0x0006` | routing activation response | TCP |
| `0x8001` | diagnostic message (carries UDS) | TCP |
| `0x8002` | diagnostic message positive ACK | TCP |
| `0x8003` | diagnostic message negative ACK | TCP |

A session: **identify** (optional, UDP) → **connect** (TCP) → **activate routing**
(`0x0005`/`0x0006`) → **exchange UDS** inside `0x8001`.

The acknowledgement runs one way. Each **tester → entity** request draws a `0x8002` (or a
`0x8003` refusing it) from the entity *before* the UDS response follows in its own `0x8001`.
The entity's response is not acknowledged in return — the tester consumes it directly. So in a
capture you see ack-then-response per request, not an ack after every `0x8001`.

Routing activation is **mandatory** — a diagnostic message arriving before it is ignored rather
than answered.

## Identity fields

A vehicle announcement carries 32 bytes:

| Field | Size | Notes |
|---|---|---|
| VIN | 17 | ASCII, as configured on the entity |
| Logical address | 2 | the diagnostic address you target |
| EID | 6 | entity id — commonly the MAC |
| GID | 6 | group id — often the same as EID |
| Further action | 1 | `0x00` = no further action required |

## Several entities on one machine

`projects/doip-network-demo.blobnet` describes several DoIP entities on loopback —
`127.0.0.1`, `127.0.0.2`, and so on — each with its own VIN and logical address. The addressing
trick is worth knowing: all of `127.0.0.0/8` routes to the loopback interface, so every entity
gets a distinct address with no network setup and no hardware.

**It is a configuration example, not a runnable demo yet.** Opening it and pressing Start does
not bring those entities up: the GUI has no `doip:` transport backend, so its simulated nodes
are driven as CAN. Until entity simulation is wired into the app, use `cmd/doip_smoke` to run
an entity and a tester headless; the project file shows the shape the configuration will take.

## Limits worth knowing

- **One tester at a time.** An entity serves one accepted TCP connection to completion before
  accepting the next, with a 60-second read timeout, so a stale peer delays another tester's
  routing activation. Deliberate: concurrent connections would drive a shared, non-thread-safe
  UDS server, so it needs per-connection handler state first.
- **Routing activation is single-source.** Once activated, a request from a different source is
  denied rather than replacing the first, and a diagnostic message whose source does not match
  the activated tester is NACKed rather than dispatched. A second tester cannot quietly take over.
- **No broadcast discovery**, **no Diagnostics-panel support**, and **no entity simulation from
  the GUI**, as above — all three planned.
- **No SOME/IP service discovery** — a separate protocol, tracked separately.

## Reading a capture

Filter on **the port your channel uses** — 13400 unless you configured another; both the client
and the entity honour whatever you set, so a custom port makes a 13400-only filter show nothing.

Then, by payload type:

- `0001` — someone asking who is out there
- `0004` — an entity identifying itself
- `0005` / `0006` — routing activation and its answer
- `8001` — diagnostics; the UDS service byte follows the two logical addresses
- `8002` / `8003` — the per-message ACK / NACK

If you see `8001` traffic with no `0006` before it, check whether your capture simply started
mid-session: routing activation happens once, at the beginning of the TCP connection, so a
capture begun later will legitimately show diagnostics without it.
