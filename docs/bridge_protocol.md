# The CAN bridge protocol

A **bridge** is a program beside CAN interfaces that Blobly Net cannot open itself. It offers them
to the app over one TCP connection, and the app opens them as `bridge:<name>/<channel>`. Two
examples are `canbridge` in a WSL distribution ([wsl_bridge.md](wsl_bridge.md)) and a board on
the LAN that captures a bus. This page is for whoever writes a bridge: it describes the bytes,
the order they come in, and what each side does with them.

The format is version **3**. `blobly/transport/bridge_codec.v` implements it, and
`blobly/transport/bridge_codec_test.v` pins the exact bytes of every record. The reference bridge
is `cmd/canbridge`, over `blobly/transport/bridge_server.v`.

## The connection

- **The bridge dials the app.** The app listens and the bridge connects to it over TCP. That is
  the direction a firewall usually lets through: outbound from the board or the WSL
  distribution.
- By default the app listens on loopback, on a port that changes at every launch, so only a bridge
  the app starts itself can reach it. For a bridge on another machine, fix the address, port and
  token with `BLOBLY_BRIDGE_LISTEN` and `BLOBLY_BRIDGE_TOKEN`
  ([wsl_bridge.md](wsl_bridge.md#a-bridge-on-the-lan)).
- **One connection carries every channel** the bridge offers. TCP is ordered and reliable, so a
  record has a length and nothing else: no framing bytes and no CRC.
- **The bridge's name identifies it.** If a bridge connects under the name of one already
  connected, it replaces that session. This lets a bridge that lost its connection without a FIN
  (its host rebooted) reconnect at once. Every handle open on the old session fails.
- When the connection closes, every channel open on it closes too. A board should then reconnect.
  `canbridge` exits instead, because whatever started it will start it again.

## Encoding

Integers are little-endian. A connection is a stream of **records**:

```
record = u32 length, then that many bytes of body
body   = u8 kind, then the kind's fields
str    = u16 length, then that many bytes of UTF-8
```

The limits are:
- a body is at most 1 MiB;
- a string is at most 1024 bytes;
- a bridge offers at most 255 channels.

A record longer than 1 MiB ends the connection: a length-prefixed stream has no boundary to
resynchronise on.

## The handshake

1. The bridge connects and sends a **hello** within **5 s**, or it is dropped.
2. The app answers with a **welcome** if it accepts the hello, or with a **refused** carrying the
   reason, after which it closes the connection.
3. After the welcome, the app opens the channels it needs. A bridge sends nothing about a channel
   until the app opens it.

A bridge that cannot start can say why instead of offering channels: a hello with no channels
and the reason in `error`. The app shows the reason where the bridge's state is shown (the
Discover dialog for a WSL bridge) and closes the connection. Any other hello with no channels is
refused.

A refused hello names the reason, for example `wrong token` or
`protocol version 4 to 5; this app speaks 3`.

## Records

`gen` is the app's number for one **open** of a channel. Every record about that open carries
it, so a record still in the stream from an earlier open of the same channel is recognised by its
value, not by where it falls. A channel is named by its index in the hello's list.

| kind | name | direction | fields after the kind |
|---|---|---|---|
| 1 | hello | bridge → app | u16 newest version, u16 oldest version, str token, str name, u8 count, count × channel, str error |
| 10 | welcome | app → bridge | u16 version |
| 9 | refused | app → bridge | str reason |
| 2 | open | app → bridge | u8 channel, u32 gen |
| 3 | opened | bridge → app | u8 channel, u32 gen, str error |
| 4 | close | app → bridge | u8 channel |
| 5 | frame | both | u8 channel, u32 gen, u8 flags, u32 seq, u32 id, i64 stamp ns, u8 len, len bytes |
| 6 | senderr | bridge → app | u8 channel, u32 seq, u8 definite, str error |
| 7 | status | bridge → app | u8 channel, u32 gen, u8 health, u64 dropped, u64 bus errors, u64 decode errors |
| 8 | lost | bridge → app | u8 channel, u32 gen, str error |

A **channel** entry in the hello is `u16 length`, then `str name, u8 bus`. Bus 1 is CAN, which is
the only bus the app opens; other values are reserved. Names follow the address rules for
`bridge:<name>/<channel>`:
- 1 to 255 bytes;
- no `/` and no `@`;
- each channel offered once.

The bridge's name obeys the same rules.

### hello

`newest` and `oldest` are the range of versions the bridge speaks. A bridge that speaks only
version 3 sends `3, 3`. The token is the app's. `canbridge` takes it with `--token`, and a board
is configured with it.

### welcome

The version the session speaks: the app's version, which is inside the hello's range.

### open, opened, close

- `open` asks for a channel. The bridge answers `opened` with the same `gen`: `error` is `''` on
  success, else the reason, such as `cannot open can0: ...`.
- The app waits **3 s** for the answer.
- An `open` of a channel that is already open is answered `opened` too. From then on, its records
  carry the new `gen`.
- `close` has no answer; the bridge stops sending about the channel.

### frame

`flags` are bits:

| bit | meaning |
|---|---|
| 0x01 | extended (29-bit) id |
| 0x02 | remote frame; its payload is `len` zero bytes, the length it requests |
| 0x04 | CAN-FD |
| 0x08 | bit-rate switch |
| 0x10 | error-state indicator |
| 0x20 | tx: the bridge's acknowledgement of a frame the app sent |

`len` is the payload's length, at most 64.

`stamp` is in nanoseconds on the **bridge host's monotonic clock**. Every stamp of one session
comes from one clock and one epoch. The app maps that clock onto its own timeline from the stamps
it receives, so the clock needs no synchronisation. A clock that stepped (a new boot) belongs to a
new session.

**Received frames.** The bridge sends one `frame` per frame its channel receives, with
`seq` = 0, tx clear and the time of reception. Several records may go in one write.

**The app's frames.** The app sends a `frame` with a `seq` of its own, tx clear and stamp 0. The
bridge puts it on the interface and answers with exactly one of these:
- the same frame back, with `tx` set, the same `seq`, the channel's current `gen` and the time the
  interface took it. The app uses this to tell its own frames from the bus's.
- a `senderr` with that `seq` and the reason. `definite` is 1 when the frame certainly did not
  reach the wire (the driver refused it whole), 0 when it may have.

The app waits **2 s** for that answer; past that it ends the session, since a bridge that has
stopped answering has stopped. Frames the channel received before the app's frame went out should
be sent before its acknowledgement, so the trace keeps the wire's order.

The app never sends a remote frame, or one no controller could send. That rules out:
- bit-rate switch or error-state indicator without FD;
- an id wider than its kind;
- a payload past 8 bytes classic;
- an FD payload of a length no DLC expresses.

### status

A status carries the channel's controller state and running counts. The bridge sends one whenever
any of them changes; the app reads none of them any other way.

| health | meaning |
|---|---|
| 0 | unknown |
| 1 | ok |
| 2 | warning (error counters above 96) |
| 3 | error-passive (above 128) |
| 4 | bus-off |

All three counts run from the open:
- `dropped` is frames lost before they were sent to the app, for example a receive queue that
  overflowed;
- `bus errors` is error records the controller reported;
- `decode errors` is records from the interface the bridge could not read.

### lost

The channel failed on the bridge, for example because its interface went down. The bridge sends
nothing more about it; the app's handles on it fail with `error`.

## Growing the format

These four rules let a version add things that an older reader passes over unharmed. Both sides
keep them:

1. **A record kind the reader does not know is skipped.** Its length says how far.
2. **Bytes after the fields a reader knows are skipped**, at the end of a record and at the end of
   a channel entry. A new field goes at the end.
3. **An unknown flag bit is ignored, and an unknown health reads as unknown.**
4. **A channel on a bus the app does not know is never opened.** It is not listed either.

Anything else is a new version, for example a field that changes meaning, or one an older reader
must not ignore. The hello's range and the welcome agree on the version, so an app and a bridge of
different versions still work together where their ranges overlap.

A future bus gets its own bus number and record kinds. LIN, for instance, has a different frame,
checksum model and errors. Nothing about it is defined yet, because the app does not open LIN.

## Security

The token is sent in the clear, and nothing on the connection is encrypted. It keeps out a stray
connection, such as a second app's bridge or a port scanner, not an attacker on the network: one
who can read the traffic can take the token and connect as the bridge. Off loopback, the app
therefore needs a fixed token of at least 16 characters. Use a listener on the LAN only on a
network you trust, such as a bench network.

Two more limits apply to connections:
- The app drops a connection that has not sent its hello within 5 s.
- At most 16 connections may be waiting to say hello; one more is closed as soon as it is
  accepted.

## An example

A bridge `board` offering `can0`, version 3 only, with the token `0123456789abcdef`:

```
2a 00 00 00                     body of 42 bytes
01                              hello
03 00  03 00                    newest 3, oldest 3
10 00  30 31 … 66               token, 16 bytes
05 00  62 6f 61 72 64           name "board"
01                              one channel
07 00  04 00 63 61 6e 30  01    entry of 7 bytes: "can0", bus 1 (CAN)
00 00                           no error
```

The app's welcome, then its open of channel 0 as open number 1:

```
03 00 00 00  0a  03 00
06 00 00 00  02  00  01 00 00 00
```

The bridge's acknowledgement of the app's frame `seq` 9, extended id 0x123, payload `aa bb`,
taken by the interface at 1000 ns, for channel 1's open number 7:

```
1a 00 00 00  05  01  07 00 00 00  21  09 00 00 00  23 01 00 00
e8 03 00 00 00 00 00 00  02  aa bb
```

`flags` 0x21 is extended plus tx. The same frame received from the bus would carry flags 0x01
and seq 0.
