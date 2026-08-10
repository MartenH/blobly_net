# DoIP — diagnostics over Ethernet

How Blobly Net talks to an ECU over Ethernet, what goes on the wire, and — just as
important — what this implementation deliberately does **not** do.

This is the user-facing guide. For *why* DoIP was built before SOME/IP, and how the module
is laid out internally, see [`ethernet_architecture.md`](ethernet_architecture.md).

## The short version

| | |
|---|---|
| Port | **13400**, for both TCP and UDP |
| TCP 13400 | diagnostics — routing activation, then UDS |
| UDP 13400 | discovery — vehicle identification and announcements |
| Protocol version | `0x02` (ISO 13400-2:2012) |
| Interface string | `doip:<host>:<port>` — e.g. `doip:192.168.0.51:13400` |

## Connecting to an ECU

Add a channel with the `doip` adapter and an address:

```
doip:192.168.0.51:13400
```

Then set the diagnostic identity in Configure — the **tester** (source) address, the **ECU**
(target) address, and optionally the expected VIN and EID. The pair of logical addresses is
what actually routes: everything after routing activation is addressed by them, not by IP.

Once started, the Diagnostics panel drives UDS over that channel exactly as it does over
CAN/ISO-TP. DoIP replaces the transport, not the diagnostics.

## What happens on the wire

Every message is an 8-byte generic header followed by a payload:

```
+--------+--------+--------+--------+--------+--------+--------+--------+
| ver    | ~ver   | payload type    | payload length (4 bytes)          |
+--------+--------+--------+--------+--------+--------+--------+--------+
```

`~ver` is the bitwise inverse of the version — a receiver that sees a header where the two
do not complement each other rejects it before parsing anything else. Useful when reading a
capture: if those first two bytes are not `02 FD`, you are not looking at DoIP.

The payload types this implementation uses:

| Type | Name | Transport | Direction |
|---|---|---|---|
| `0x0001` | vehicle identification request | UDP | tester → ECU |
| `0x0004` | vehicle announcement / identification response | UDP | ECU → tester |
| `0x0005` | routing activation request | TCP | tester → ECU |
| `0x0006` | routing activation response | TCP | ECU → tester |
| `0x8001` | diagnostic message (carries UDS) | TCP | both |

A session therefore looks like: **identify** (optional, UDP) → **connect** (TCP) →
**activate routing** (`0x0005`/`0x0006`) → **exchange UDS** inside `0x8001` messages.

Routing activation is **mandatory**: a diagnostic message that arrives before it is ignored,
not answered.

## Discovery: what is and is not broadcast

This is the part most likely to surprise you.

**Nothing is broadcast by Blobly Net.** `discover()` sends a vehicle identification request
as a **unicast UDP datagram to a host you name**, waits for one reply, and returns it. The
simulated entity likewise answers **only the sender**.

So discovery here **confirms an identity you already know** — it tells you the VIN, logical
address, EID and GID of the thing at that address. It does **not** find ECUs you have not
been told about.

That is a real limitation rather than a design principle, and it is asymmetric: a real ECU
*does* announce itself. The companion firmware (blobly_emb) broadcasts its vehicle
announcement three times at boot, per ISO 13400, and answers identification requests
afterwards — precisely so a tester arriving late can still find it. Blobly Net currently
hears neither, because it never listens on a broadcast address and stops at the first reply.

Until that changes, the practical consequence is: **on Ethernet you must know the address
before you can see anything.** On CAN you attach and observe, because the bus is broadcast;
on Ethernet the same tool sees nothing without being pointed at a host. Plan your bench
accordingly — static addresses, or a DHCP lease you can read.

## Identity fields

A vehicle announcement carries 32 bytes:

| Field | Size | Notes |
|---|---|---|
| VIN | 17 | ASCII, as configured on the ECU |
| Logical address | 2 | the diagnostic address you target |
| EID | 6 | entity id — commonly the MAC |
| GID | 6 | group id — often the same as EID |
| Further action | 1 | `0x00` = no further action required |

## Multiple entities on one machine

`projects/doip-network-demo.blobnet` runs several DoIP entities at once on loopback —
`127.0.0.1`, `127.0.0.2`, and so on. This works because the whole of `127.0.0.0/8` routes to
the loopback interface, so each entity gets a distinct address without any network setup,
and each carries its own VIN and logical address. It is the cheapest way to exercise
multi-ECU diagnostics, and it needs no hardware.

## Limits worth knowing

- **One tester at a time.** A DoIP entity serves one accepted TCP connection to completion
  before accepting the next, with a 60-second read timeout. A stale or idle peer therefore
  delays another tester's routing activation. This is deliberate: concurrent connections
  would drive a shared, non-thread-safe UDS server, so it needs per-connection handler state
  before it can be lifted.
- **Routing activation is single-source.** Once activated, a request from a *different*
  source address is denied rather than replacing the first, and a diagnostic message whose
  source does not match the activated tester is NACKed rather than dispatched. A second
  tester cannot quietly take over an active session.
- **No discovery by broadcast**, as described above.
- **No SOME/IP service discovery** — a separate protocol, tracked separately.

## Reading a capture

Filter on port 13400. Then:

- `02 FD 00 01` — someone is asking "who is out there"
- `02 FD 00 04` — an entity identifying itself
- `02 FD 00 05` / `00 06` — routing activation and its answer
- `02 FD 80 01` — diagnostics; the UDS service byte is the first payload byte after the two
  logical addresses

If you see `0x8001` traffic with no preceding `0x0006` success, the ECU is discarding it —
routing was never activated.
