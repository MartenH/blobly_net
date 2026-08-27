# CAN hardware on Windows

Windows has no OS-level CAN standard, so each vendor is its own backend. This is what
Blobly Net supports there, how it is addressed, and how far the support has actually been
verified. (On Linux the kernel owns the adapter and everything is SocketCAN — see
[can_hardware.md](can_hardware.md).)

## What is supported

| vendor | interface string | library | status |
|---|---|---|---|
| **PEAK PCAN** | `pcan:PCAN_USBBUS1@500000` | `PCANBasic.dll` | ✅ verified on hardware |
| **Kvaser** | `kvaser:0@500000` | `canlib32.dll` | ✅ verified on hardware |
| **Vector XL** | `vector:1@500000` | `vxlapi64.dll` | ✅ verified on hardware |
| slcan (USB-serial) | `slcan:COM5@500000` | none — serial | ❌ not implemented |

**CAN-FD on Vector** (`vector:1@500000/2000000`) **and Kvaser** (`kvaser:0@500000/2000000`) — in
both, the data rate in the address is what asks for it — and classic CAN on all three. On **PCAN**
CAN-FD is still **refused, not truncated**: a bench that silently dropped 56 of 64 payload bytes
is worse than one that says no. A *classic* Vector or Kvaser channel refuses an FD frame for the
same reason — the channel decides, not the frame, because a handle opened classic would put a
classic frame on the wire and report success.

Software buses (`inproc:`, `udp:`) work on Windows exactly as on Linux and need no driver.

### What "verified" means here

By hand, on one bench, on the date given — **not** by CI. Nothing in CI opens a CAN channel;
no runner has an adapter, and for Vector no runner may even hold `vxlapi64.dll`, which cannot
be redistributed. The Windows job proves the code **compiles and links**: enough to catch a
signature that drifted, not enough to catch a bitrate that never reaches the transceiver.

- **PCAN + Kvaser, 2026-06-18** — cross-vendor on one 500 kbit/s bus (Kvaser Leaf Light v2 ↔
  PCAN-USB Pro FD): Kvaser TX `0x123#DEADBEEF` → PCAN RX byte-identical, and PCAN TX
  `0x456#CAFE` → Kvaser RX, via `cmd/can_smoke`. Two vendor stacks agreeing on the wire is
  itself the oracle.
- **Vector, 2026-08-19** — VN1630A (serial 545980), Channel 1 → Channel 3 over real
  transceivers (CANpiggy 1057Gcap → on-board 1051cap) at 500 kbit/s: **43,773 frames sent and
  received, none malformed**, sequence-checked end to end. That is ~4,400 frames/s, a
  saturated wire for eight data bytes — 111 bits per frame caps 500 kbit/s at ~4,504/s.
  One adapter, one bitrate, two channels of one device wired to each other; not a vehicle bus.

The **ABI is the exception**: 14 `_Static_assert`s pin every struct size and offset used by
the Vector backend, and those are compile-time, so the mingw job checks them on every push.
`vxlapi.h` (25.20.14) was read for each typedef and signature — `XLstatus` is `short`,
`XLportHandle` is `long` (32-bit here), `XLevent` is 48 bytes, `XLchannelConfig` 227,
`XLdriverConfig` 14576 — but the header is **not** included at build time, because we cannot
depend on a library we may not redistribute.

## Interface strings

```
pcan:PCAN_USBBUS1      # PEAK channel handle name (or pcan:usb1)
kvaser:0               # Kvaser channel number
kvaser:5               # a Kvaser SOFTWARE virtual channel (no hardware needed). Its NUMBER
                       # depends on the machine -- canlib numbers virtual channels alongside
                       # physical ones -- so read it off `kvasercheck --list`, which marks them.
vector:1               # Vector APPLICATION channel, as Vector Hardware Manager numbers them
vector:1@250000        # …at 250 kbit/s
vector:1@500000,silent # …listen-only: the transceiver never acknowledges
```

A channel added through Discover starts silent on purpose: the 500 kbit/s default is a guess
until somebody confirms it, and a node joining a live bus at the wrong bitrate floods error
frames. There is no Vector software-virtual bus in Blobly Net — use `inproc:` for driver-free
work. (Vector's own virtual channels exist and `cmd/vectorcheck --selftest` uses them.)

A project `Channel` already carries `bitrate`, `fd`, `data_bitrate`, `sample_point`,
`timing{brp,tseg1,tseg2,sjw}` and `listen_only`; each backend maps those onto its vendor init
call — PCAN's `TPCANBaudrate` enum for standard rates, or raw `timing{}` for a custom BTR.

## Why a backend per vendor

On **Linux**, CAN is an OS service: SocketCAN lives in the kernel behind one standard API
(`AF_CAN`), which is why `transport/socketcan_linux.v` is thin. On **Windows** a vendor's
driver package makes the device work and ships the vendor's user-mode DLL, but each exposes
its own proprietary API.

| | Linux | Windows |
|---|---|---|
| CAN API | one kernel standard (`AF_CAN`) | none — per-vendor DLLs |
| What the user installs | (kernel has it) | vendor driver package |
| What Blobly Net needs | one SocketCAN backend | one backend **per vendor** |

## The seam

Callers depend only on `transport.Bus` (`send`/`recv`/`close`) and `transport.open(iface) !Bus`.
The dispatcher is per-OS: `open_linux.v` handles `inproc:` / `udp:` / SocketCAN;
`open_windows.v` handles `inproc:` / `udp:` / `pcan:` / `kvaser:` / `vector:` and errors
otherwise. Each backend is one `transport/<vendor>_windows.v` file — V gates it to Windows by
the `_windows.v` suffix, as with `socketcan_linux.v` — so a new vendor is additive and never
compiles off-Windows.

## No SDK, no MSVC: the DLL is loaded at runtime

Each backend declares the function prototypes it needs from the vendor's documented ABI and
resolves them with `LoadLibraryW`/`GetProcAddress` through a small `*_shim.h`. So:

- no import `.lib`, so mingw/MSYS2 is enough and MSVC is never required;
- nothing of the vendor's is redistributed — the user installs the driver, we bind to it if
  present and give a clean error if not;
- all three vendor APIs are plain C, so there is no C++ ABI to match.

## Per-vendor notes

**PCAN (PEAK)** — `PCANBasic.dll`; about six calls (`CAN_Initialize`, `CAN_Uninitialize`,
`CAN_Read`, `CAN_Write`, `CAN_GetStatus`, `CAN_GetErrorText`). Frames are
`TPCANMsg{ID u32; MSGTYPE u8; LEN u8; DATA [8]u8}`, with extended/RTR carried in the
MSGTYPE flags. The free driver has no software virtual channel, so testing needs the adapter.

**Kvaser (CANlib)** — `canlib32.dll` (`canInitializeLibrary`, `canOpenChannel`,
`canSetBusParams`, `canBusOn`, `canWrite`, `canReadWait`, `canBusOff`, `canClose`).
`canSetBusParams` takes bitrate plus segment timing, so `timing{}` maps straight onto it.
**Software virtual channels** exercise the backend with no bus at all. They are ordinary canlib
channel numbers — on a bench with a 5-channel adapter fitted they are 5 and 6, on a machine with
no Kvaser hardware they are 0 and 1 — so `kvasercheck --list` is what tells you which. (`kvaser:virtual0`
was once documented here and never worked as advertised: it parsed as channel 0, which is physical
wherever an adapter is present.)

**Vector (XL Driver Library)** — `vxlapi64.dll`, the most verbose of the three
(`xlOpenDriver`, `xlGetApplConfig`, `xlGetChannelMask`, `xlOpenPort`, `xlCanSetChannelBitrate`,
`xlCanSetChannelOutput`, `xlActivateChannel`, `xlCanTransmit`, `xlReceive`, `xlClosePort`,
`xlCloseDriver`). Several things are specific to it:

- **Addressed by application channel**, because that is what `xlGetApplConfig` and
  `xlGetChannelMask` take and what Vector Hardware Manager numbers. `vector:1` is the channel
  the operator sees in that dialog.
- **An application channel is not a physical channel**, and the dialog will let two of them
  point at one piece of hardware. To this app those are two wires — `destination_key` resolves
  the application channel and nothing else — and to the driver they are one, which means the
  rate check, the listen-only check, the one-monitor rule, the transmit lock and the pin guard
  each reason about half a wire. Refused at Start rather than run that way (#167): a project
  whose enabled rows resolve to one physical channel under two different names is told so and
  does not start. `cmd/vectorcheck --list` prints the assignment triple beside each channel and
  warns if two share one, so the configuration can be seen before a project is written against
  it. Nothing without the XL driver can answer the question, and there the check says nothing at
  all rather than guessing.
- **`vxlapi64.dll` is a separate download from the hardware drivers** and does not install
  onto the search path: its installer puts it under
  `C:\Users\Public\Documents\Vector\XL Driver Library <version>\bin`. The loader tries the
  bare name first, then that directory. A bench can have a healthy VN device and Vector
  Hardware Manager installed with no XL library present at all.
- **`,silent` reaches the transceiver** — ACK-free output is set *before* the channel is
  activated, the only ordering that is safe against a running vehicle. A project's
  `listen_only:` is translated to it, and `cmd/vectorcheck --channel N` defaults to silent.
  On every other backend `listen_only` does not reach the transceiver, so the adapter still
  ACKs what it hears. What it DOES do everywhere, since #117, is stop this process
  transmitting: `transport.open` hands back a bus that refuses to send on a silenced wire, so
  no emitter can route around it. Two tiers, and the tooltip states both.
- **An open port PINS the channel** — its mode, its bitrate, and (since CAN-FD) its PROTOCOL and
  data phase. A second port asking for the other mode is refused (`-1004`), a second bitrate
  likewise (`-1005`), classic-versus-FD `-1011` and a second data rate `-1012`; no software
  policy can talk the driver out of any of them: the configuration belongs to the ports, not to
  the project. The protocol is the strictest of the four, because it is not merely a setting —
  the XL interface version a port is opened with (V3 classic, V4 FD) decides the layout of the
  events on that port's receive queue, so a sibling that disagreed would decode every frame
  through the wrong struct rather than simply running at the wrong speed. Not quite "until the last port closes", and the exception is worse rather than
  better — initialisation access belongs to one PORT, so when that port closes while siblings
  stay open XL releases it, and the next port to win it reconfigures the channel under those
  siblings, which go on running against a mode they never asked for. This is why the front ends ask
  `transport.wire_pin_clash` before they open anything (`modules/transport/pinned.v`), and it
  is the one rule here a disabled channel can still break — a disabled row keeps its transmit
  taps open on purpose, so its ports go on holding a channel the project no longer mentions
  (issue #165).

**slcan** — not implemented. CANable / CANtact / USBtin appear as a COM port speaking an
ASCII line protocol (`O` open, `S6` 500k, `t<id><len><data>`, `T…` for 29-bit); no DLL and no
SDK, and it would work identically on Linux and Windows.

## Setting up a Vector bench — the application-channel model

The thing that surprises everyone first: **you cannot address Vector hardware directly.** The XL
library only takes an *application channel*, so a channel has to be MAPPED to a physical one
before `vector:1` opens anything. On a fresh bench that mapping does not exist yet.

**Why the indirection is there** — it is Vector's design, not ours, and it earns its keep. Every
XL program registers a name and gets its own 1..64 numbering:

```
"blobly_net"  channel 1 ─┐
"CANoe"       channel 1 ─┼─→  all three may point at VN1630A Channel 1
"CANalyzer"   channel 1 ─┘
```

Three tools share one device without arguing about channel numbers, and each keeps its own map.
The alternative — addressing hardware directly — means reproducing `XLdriverConfig`, a large
packed struct whose exact size decides where the channel array starts; an error there reads out
of bounds rather than failing.

The backend does both, and which one applies depends on the question:

- **Opening a bus never touches that struct.** `vector:<n>` is an application channel, resolved
  through `xlGetChannelMask`, so the path that carries traffic does not depend on the layout.
- **Discovering hardware does.** Listing what is physically plugged in has no other source, so
  `ct_vector_channel_info` calls `xlGetDriverConfig` and the shim reproduces the struct, with the
  `_Static_assert`s the ABI note above describes (`XLdriverConfig` is 14576 bytes) checked by the
  mingw CI job on every push.

Be clear about what those assertions are worth, because it is easy to read them as more than they
are. `vxlapi.h` is deliberately not included at build time, so each one compares the transcribed
struct against a **hardcoded constant transcribed from the same reading of the header**. They catch
a field added, reordered or mis-sized locally — real drift, and the reason they exist. They cannot
catch a value transcribed wrongly in the first place, and they cannot notice that an installed
`vxlapi64.dll` has a different ABI from 25.20.14: both sides of the comparison are ours. A genuine
mismatch there still reads the wrong fields, or past the end of the channel array, at runtime.

So the risk is real, confined to discovery, and only *partly* covered. Local drift introduced later
fails the build; a wrong transcription or a mismatched installed DLL does not, and shows up as bad
data or an out-of-bounds read at runtime. It is not avoided altogether, and an earlier version of
this page claimed it was.

The mapping is stored **by the driver**, per application, and survives reboots. That is why a
tool that borrows a channel has to put it back, and why `vectorcheck --pair` restores on Ctrl-C.

### Reading the dialog

In Vector Hardware Config (or Hardware Manager) an application shows a fixed list:

```
CAN 1    VN1630A 1 (545980)  Channel 1
CAN 40   Not assigned
CAN 61   VN1630A 1 (545980)  Channel 3
CAN 62   Not assigned
```

**`CAN <n>` is the application channel NUMBER, not a name** — it is not editable, and it is not
a description of the bus. It is the `n` in `vector:<n>`. Rows reading *Not assigned* are channels
this application has registered and not mapped. They are harmless, and they are left behind by
whatever assigned them — `--assign` followed by `--release`, or a `--pair` run on channels 61 and
62, both of which clear the mapping without removing the row.

**Opening a channel does not create one.** It is worth being exact, because the two look similar:
opening a channel the application already has but has not mapped rewrites the zeroes already there,
which is how the application first becomes visible in the Hardware Manager. Opening a channel the
application does *not* have fails instead (`-1007`) and registers nothing. So rows appear by being
**assigned**, never by being opened, and the section below is the only way to add one.

That registration **extends an application that already exists** — *opening* a channel does not
create one. Delete `blobly_net` in the Hardware Manager and no amount of opening brings it back;
the driver has nothing to add the channel to, and every `vector:<n>` fails with the same code an
unmapped channel gives.

**Assigning is the other half, and it does create.** `xlSetApplConfig` — what the Discover dialog's
Assign button and `vectorcheck --assign` both call — writes the application into existence if it is
not there, so a deleted or never-created `blobly_net` is recovered from inside the app: tick
**create unregistered channel**, type a number, press Assign. The Hardware Manager is not needed for
this, and the dialog says so when nothing could be read for the application.

The two failures are worth separating because they look identical from the wire — nothing arrives
either way — and the dialog names which one it is rather than leaving you to guess.

So the two columns answer different questions: the left is **our** numbering, the right is **the
driver's** hardware. `--list` prints both, with the driver's `hwType:hwIndex:hwChannel` triple.

### Doing it without the Hardware Manager

Two ways, and both make the same `xlSetApplConfig` call the Hardware Manager does.

**From the app:** the Discover dialog (File → Configure… → Discover) grows a **Vector hardware**
section listing every physical channel with its transceiver, its rate and its `can-fd` verdict.
Mapped rows show the address they already answer to (`vector:2`); unmapped ones get an **Assign**
button. Type the application channel number you want in the field at the top, then press Assign on
the row.

Nothing proposes a number for you — the choice is yours, and the dialog reports what the driver
confirmed rather than guessing. Two kinds of number are free, and they are not offered on the same
terms:

- **channels the application already has, pointing at nothing.** The driver says so positively, so
  these are listed individually and Assign just works.
- **channels it does not have at all** — most of the range on any real bench, and *every* channel on
  one where `blobly_net` has never run. Assigning one **creates** it, the same extension the
  Hardware Manager performs. These are counted rather than listed (there are usually about 57), and
  they need the **create unregistered channel** box ticked first.

That box exists because of a limitation worth knowing about. The driver reports "no such channel"
using its *generic* error code, which is also what a momentary failed read of an **occupied** channel
looks like — the two are indistinguishable, and no amount of re-asking separates them. Assigning
blind would therefore risk retargeting a mapping that survives reboots, and refusing outright would
make a fresh bench impossible to set up. So the app does not guess: it refuses by default and lets
you say when you mean to create. The box clears itself after each use, because it authorises one
write rather than switching on a mode.

Both ends are re-checked under a cross-process lock at the moment you press Assign, because the
list is a snapshot and `vectorcheck` or a second copy of the app may have written since: an
application channel already pointing at hardware is refused, and so is a physical channel another
number already claims. If the driver will not describe *every* application channel, a row whose
ownership cannot be established shows `(owner unknown)` and gets no button — one of the channels
that stayed silent may be the one already pointing at it, and assigning a second is how you end up
with two addresses for one wire. A channel carrying no CAN — a VN1630A's D/A IO channel, say — is
listed but gets no button either, since the mapping could only fail to open.

**Best effort, not a guarantee**, and for the reason the checkbox exists. The owner of a physical
row is worked out from what each application channel reports, so a channel that answers the generic
error *twice* is classified as unregistered and counted as a known non-owner — if it was in fact
occupied and pointing at that row, the row still looks unclaimed. The same ambiguity that makes
creating a channel your decision limits this check, and no re-reading closes it. What does catch it
afterwards is `destination_conflicts()`, which refuses a project carrying two application channels
on one physical channel ([#167](https://github.com/MartenH/blobly_net/issues/167)).

Writes go under the application name `blobly_net` only; another application's assignments (CANoe,
CANalyzer) are never touched, and the mapping is stored by the driver and survives a reboot.

**From the CLI**, when there is no GUI or you want it scripted. `cmd/vectorcheck` is a **source-tree
tool and is not in the release bundle** — that ships `blobly_net` only — so build it from a checkout
first, or use the Discover dialog above, which does the same job and checks more before it writes:

```sh
v -enable-globals -path "@vlib|@vmodules|modules" -o vectorcheck.exe cmd/vectorcheck
```

```sh
vectorcheck --list                               # which application channels are already mapped
vectorcheck --probe                              # find the row number of the hardware you want
vectorcheck --channel 5 --assign 2 --seconds 1   # map application channel 5 -> probe row 2
vectorcheck --release 5                          # clear channel 5 again
```

> **`--assign` overwrites, and `--release` does not undo it.** Unlike the GUI, this path performs no
> check: it does not look at what the channel currently points at, and it keeps no copy. `--release`
> **clears** the channel rather than restoring its previous target, so assigning over a mapped
> channel and then releasing it leaves that channel pointing at *nothing* — and the original mapping
> is gone for good, from persistent state that survives reboots.
>
> **Absence from `--list` is not proof that a channel is free.** That list skips any channel the
> driver would not describe, and an unreadable channel is indistinguishable from an unassigned one
> for the same reason the Discover dialog asks before creating — so a channel hidden by one failed
> read looks exactly like a spare. For a bench that matters, confirm positively in the **Discover
> dialog** (which reports `taken`, free, and "could not read" as three different things) or in
> Vector Hardware Manager, rather than inferring from what `--list` did not print. The example uses
> channel 5 rather than 1 or 2 because the low numbers are the ones a bench is most likely to be
> using already.

`--assign` takes a **`--probe` row**, not a channel number. Deliberately: the driver lists its
channels device-first while a hwType sweep walks them in another order, and an earlier version
took one for the other — the caller named one thing and got another, with silence on a wire that
was fine as the only symptom. It also *listens* after assigning rather than exiting, so give it
`--seconds 1` when all you want is the mapping.

`--pair` is the one path with **save-and-restore** behaviour: it borrows application channels 61 and
62, runs, and puts back whatever they pointed at, including on Ctrl-C. That makes it the least
disruptive way to test a bench whose mappings you did not make.

**Best effort, though.** The restore runs from a deferred cleanup that cannot fail the command: if
the driver resets or disconnects mid-run and `xlSetApplConfig` is rejected, `give_back` prints a
`note:` line and the run still reports its result. So a `--pair` that ends with a note about a
channel it could not restore has left 61 or 62 pointing at the test hardware, persistently — read
those notes, and check `--list` afterwards on a bench that matters. Making a failed restore change
the exit status is [#197](https://github.com/MartenH/blobly_net/issues/197).

It does need those two channels to be *registered*, though — 61 and 62 are hardcoded, and the borrow
refuses to touch a channel it cannot first read, which is exactly the protection that stops it
"restoring" a mapping by clearing one. On a bench where `blobly_net` has never run they are not
registered, so `--pair` exits before assigning anything. Register them once — assign each to any row
and release it, or tick **create unregistered channel** in Discover — and it works from then on.
Letting the borrow bootstrap them itself is [#195](https://github.com/MartenH/blobly_net/issues/195).

### "It only shows one speed" — where the CAN-FD data rate lives

The dialog shows a single **Default CAN baud rate** per channel. That is not a statement about
CAN-FD, and not a limit either:

- it is the rate a channel keeps for applications that never configure one;
- this backend overrides it at open — `xlCanSetChannelBitrate` for a classic port,
  `xlCanFdSetConfiguration` for an FD one, which is where the *second* rate comes from;
- so there is one field because the data phase is an **application-time** setting, not a hardware
  one. `vector:1@500000/2000000` is where you say it.

**Whether a channel can do CAN-FD at all** is a property of its transceiver, and you do not have
to identify the part to find out — the driver answers it
(`XL_CHANNEL_FLAG_CANFD_ISO_SUPPORT` / `..._BOSCH_SUPPORT` in `channelCapabilities`), and
`vectorcheck --probe` prints it in a **`can-fd`** column:

| `can-fd` | means |
|---|---|
| `iso` | ISO CAN-FD — the variant this backend configures. Usable. |
| `iso+bosch` | both variants; this backend uses ISO. Usable. |
| `bosch-only` | FD hardware, but the non-ISO variant only — this backend cannot drive it. |
| `-` | classic CAN only. A data phase will be refused. |

Asking beforehand is the point: the alternative is a late, indirect failure — configure a data
phase, Start, and get a refusal from `xlCanFdSetConfiguration` for a channel that was never
FD-capable. The part name is a weaker clue than the flag but agrees with it; the `CANpiggy
1057Gcap` and the on-board `1051cap` on the bench this was written against both report `iso`.

## Checking a bench

`cmd/vectorcheck` is the Vector one: `--list` shows application channels with hardware
assigned, `--probe` shows what the driver reports as present, `--selftest` proves the backend
on Vector's own virtual channels with no hardware, `--modecheck` proves that an open port pins
its channel and that `wire_pin_clash` predicts it, and `--pair A,B` transmits on one channel
and verifies every frame arrives on another. All but `--pair` are silent — they will not
acknowledge on a bus until you ask them to, so they are safe to point at a live one.

Add **`--fd`** to `--pair` or `--channel` for CAN-FD, with `--dbitrate` for the data phase
(default 2 Mbit/s) and `--length` for the payload size (default 64 with `--fd`). `--dbitrate`
on its own implies `--fd`, because a data rate that was silently ignored would be worse than a
refusal. The payload is checked byte for byte against what was sent, not merely counted: an
under-terminated FD bus corrupts the data phase, and a marker-only check would pass over it.

**Termination matters much more for FD.** A CAN bus wants 120 Ω at *both* ends, and it is the first
thing to suspect when an FD data phase at 2 Mbit/s or above starts producing malformed frames, since
the reflections a missing one leaves scale with the bit rate. Fix the termination before reading a
malformed-frame count as a backend bug.

One resistor was survivable *here*, and the FD table below records both conditions side by side: a
single terminator and the correct two, measured the same day. They agree exactly, which on a 30 cm
link is what to expect — the classic table above explains why. Under-terminating a real harness is a
different proposition, and nothing here tests it.

**With NO resistor fitted, classic CAN goes too.** Measured on this same bench, Channel 1 to
Channel 3, after the one terminator was removed:

| bitrate | result |
|---|---|
| 125 000 | 100% arrived |
| 200 000 | nothing arrived · 17,899 error frames |
| 250 000 | nothing arrived · 22,332 error frames |
| 500 000 | nothing arrived · 42,894 error frames |

**The shape of that table is the diagnostic.** Error frames rising roughly in proportion to the bit
rate is a constant error rate *per bit*, which is what reflections look like — they settle inside a
125 k bit time and do not inside a 250 k one. So a link that passes at a low bitrate and fails at a
higher one is a physical-layer problem, not a software one. Two checks isolate it in a minute:

- **`vectorcheck --selftest`** proves the backend end to end on the driver's *virtual* channels —
  assign, open, set the bitrate, go on the bus, transmit, receive. It picks them by hardware type
  (`XL_HWTYPE_VIRTUAL`), so it touches no real bus on any machine. Use this rather than naming
  `--probe` rows: row numbers are per-bench, and `--pair` transmits in **normal** mode, so a
  hardcoded pair of rows that happen to be virtual here can be two live buses somewhere else.
  Like `--pair`, it borrows fixed application channels — 63 and 64 — and cannot bootstrap them, so
  on a bench where `blobly_net` has never run they need registering once first
  ([#195](https://github.com/MartenH/blobly_net/issues/195)).
- **Drop the bitrate until it passes.** If the backend is fine and 125 k works while 500 k does not,
  what is left is the wire.

Refitting the resistor recovered the rows it was re-measured on, and fitting a second one changed
nothing further. Only the termination differs across these three columns, so the comparison is
controlled — but note the gaps: 200 kbit/s was re-measured only with two resistors, and 1 Mbit/s was
never run with none, so neither row is a before-and-after on its own.

| bitrate | no terminator | one | two (correct) |
|---|---|---|---|
| 125 000 | 100% arrived | 100% arrived | 100% arrived |
| 200 000 | 17,899 error frames | — | 100% arrived |
| 250 000 | 22,332 error frames | 100% arrived | 100% arrived |
| 500 000 | 42,894 error frames | 100% arrived | 100% arrived |
| 1 000 000 | — | 100% arrived | 100% arrived |

**The cliff is between none and one, not between one and two.** With both fitted the frame counts
came back identical to the single-resistor run — 3,132 at 125 k, 5,298 at 250 k, 9,573 at 500 k.

**The link is 30 cm**, and that number is what makes the rest interpretable. Over a stub that short
a reflection returns in a couple of nanoseconds, far inside even an 8 Mbit/s bit time, so the second
resistor has nothing left to fix and one is indistinguishable from two. Removing the *last* one is a
different matter: an entirely unterminated bus has no defined idle state for the differential pair
to settle to, which is why the left-hand column fails at 200 k on a cable where reflections are
otherwise irrelevant.

So read this table as "none is broken, one is enough **at 30 cm**" — not as evidence about
termination in general. On a metres-long harness the one-resistor column is where failures would
appear first, and the correct answer stays 120 Ω at both ends.

`--modecheck` is the bench half of a test whose other half runs everywhere: on Linux
`modules/transport/pinned_test.v` checks the bookkeeping over `inproc:` buses, and only a VN
device can answer whether the driver actually refuses what that bookkeeping predicts. It holds
one listen-only port, asks for a second bitrate, opens a matching sibling, and checks the
refusals against the predictions — then that all of it is released when the ports close.

The **normal-mode** probe needs `--transmit`, and the reason is worth stating: asking the driver
for a normal port is the sharpest check in the set, and it is silent only *while the driver
refuses it*. If the driver ever allowed it — a regression, a different XL version, a channel
whose initialisation access had been released — the port would activate, and a normal port on a
live bus acknowledges (or, at the wrong bitrate, floods error frames) for as long as it takes to
close. A test that is safe only while it passes is not safe, so that one probe is opt-in and its
absence is printed rather than silently skipped.

Run on a VN1630A, application channel 1 at 500k and 250k, `--transmit`, 2026-08-23:

```
modecheck: application channel 1 at 500000, listen-only
  held  vector:1@500000,silent
  predicted, normal open : is normal and ports are still open on vector:1 in listen-only mode
  predicted, other rate  : asks 250000 and ports are still open on vector:1 at 500000
  predicted, same again  : (no clash)
  driver refused normal  : Vector channel 1 is already open in listen-only mode by this project
                           and cannot also be normal …
  driver refused rate    : Vector channel 1 is already open at a different bitrate by this project …
  predicted, as CAN-FD   : is CAN-FD and ports are still open on vector:1 as classic CAN
  driver refused CAN-FD  : Vector channel 1 is already open as classic CAN by this project …
  driver allowed sibling : vector:1@500000,silent
  released, channel free
  held  vector:1@500000/2000000,silent
  predicted, other dphase: asks a 4000000 bit/s data phase and ports are still open … at 2000000
  driver refused dphase  : Vector channel 1 is already open with a different CAN-FD data bitrate …
  driver refused classic : Vector channel 1 is already open as CAN-FD by this project …
  released, FD channel free
modecheck: OK — the driver pins what wire_pin_clash predicts, and releases it
```

The FD half was added with the CAN-FD backend and covers all four directions: a classic-held
channel refusing an FD port, an FD-held channel refusing a classic one, and an FD-held channel
refusing a second data phase. It needs no `--transmit`, because both addresses are silent and
only the protocol changes.

**CAN-FD link test**, same adapter, Channel 1 to Channel 3 — 64-byte payloads with BRS, arbitration
at 500 kbit/s, every byte verified against what was sent. Every phase passed under **both**
termination conditions, measured the same day over the same two-second window, with identical
frame counts:

| data phase | arrived | malformed | frames (2×120 Ω) | frames (1×120 Ω) |
|---|---|---|---|---|
| 2 Mbit/s | 100% | 0 | 6,196 | 6,196 |
| 4 Mbit/s | 100% | 0 | 10,267 | 10,267 |
| 5 Mbit/s | 100% | 0 | 11,877 | 11,877 |
| 8 Mbit/s | 100% | 0 | 15,603 | 15,603 |

(The 2026-08-24 run reported different totals — 14,913 to 23,216 — because it ran longer, not
because it behaved differently; these two columns are the same two-second window.)

`vectorcheck --pair 0,2 --fd --dbitrate <rate> --length 64`. The count **rising with the data phase**
is the part that carries the meaning: it is what shows BRS is switching rather than the payload
quietly going out at the arbitration rate.

**Do not convert those counts into a throughput figure.** `--pair` reports frames the driver
*accepted* divided by the run length, while its queue keeps draining after the window closes, so the
`/s` it prints includes buffer absorption. The giveaway is this page's own arithmetic: it printed
4,786/s for eight-byte frames at 500 kbit/s, above the ~4,504/s that 111 bits per frame allows, and
a wire cannot beat its own bit time. Counts and arrival percentages are exact; a rate derived from
them is an upper bound. [#196](https://github.com/MartenH/blobly_net/issues/196) tracks fixing that.

**Termination, as measured rather than assumed:** none failed classic CAN from 200 kbit/s up; one
carried FD to 8 Mbit/s; two behaved identically to one. All of that is on a 30 cm link, which is
why one and two are indistinguishable, and it says nothing about a harness of any real length. The
correct answer remains 120 Ω at both ends — this bench now has that.

It was worth running for a second reason: the `-1004` message used to name the mode backwards.
The shim's check is bidirectional and says so, but the V-side text assumed the channel was open
in *normal* mode — and `--modecheck` holds one *silent*, which is how the mismatch showed. The
message now derives the direction instead of assuming it.

CROSS-COMPILED FROM WSL, which is how it is run here — `v -os windows -enable-globals -path
"@vlib|@vmodules|modules" -o vectorcheck.exe cmd/vectorcheck/main.v`, then the `.exe` from a
Windows-visible directory. WSL's interop launches it as an ordinary Windows process, so it
reaches `vxlapi64.dll` and the adapter. A Linux build of this tool warns at startup that the
backend is Windows-only and then runs anyway — on Linux `vector:1` is an ordinary SocketCAN
name, so what it reports is a missing interface rather than a missing driver.

For PCAN and Kvaser, `cmd/can_smoke` opens a channel and does a TX/RX round trip. Kvaser's
virtual channels make that possible with nothing plugged in.

`cmd/kvasercheck` is the Kvaser equivalent of `vectorcheck`: `--list` prints canlib's channel
numbers next to the connector numbers silk-screened on the case (they differ by one, and canlib
numbers the SOFTWARE virtual channels in the same sequence, which is why `--list` marks them),
`--from`/`--to` loop a frame between two channels, `--ladder` walks classic and then FD at
500k/1M/2M/4M/8M.

  The eight-byte case is there because the first fix did not go far enough, and the bench said
  so: with the read buffer left uninitialised the frame came back as `c07db72d00000000`. Those
  bytes were never **on the wire** — a remote frame carries no payload, which is the whole point
  of it — they were this host's own stack, read out of an untouched receive buffer and put into
  the decoded frame. That is a backend defect, not a bus one, and worth saying precisely: chasing
  it as transmitted data would send you to the cable. `wiretap` compares payloads, so the echo
  still failed to match and was still filed as the ECU's answer; #177 would have been closed with
  its own defect alive for every DLC above zero. A check that only ever asked for `dlc=0` could
  not see it.

What good looks like: `transport.open(...)` returns without error (DLL found, channel opens,
bus on); frames Blobly Net sends appear byte-identical in a second tool on the same bus —
`python-can` with the matching backend is the established oracle, as `sut/` does for decoding —
and a bitrate mismatch or missing termination shows up as no RX or bus-off, which is expected
rather than a bug in the backend.

## Pending

- **CAN-FD on PCAN** — Vector and Kvaser have it; PCAN needs `CAN_InitializeFD`, which takes a
  bit-rate *string* instead of the baudrate enum ([ROADMAP](../ROADMAP.md)).
- **slcan** — vendor-neutral, cross-platform, no DLL; the cheapest path to real frames on a
  bench with no vendor adapter at all.

## Bus health (fault ladder)

Every backend now reports the controller's fault ladder (warning / error-passive / **BUS-OFF**)
through one decode in `modules/transport/health.v`: PCAN via `CAN_GetStatus`, Kvaser via
`canReadStatus`, Vector from its chip state. The Buses panel colors the row (`BOFF` red) and
the Log narrates transitions. The decoders are pinned to the vendors' header constants by unit
tests; **the live paths are NOT yet hand-verified on hardware** — the same bench pass that
verified each backend's I/O should provoke a bus-off (short CANH/CANL, or a lone node
transmitting) and confirm the row turns red and the Log speaks.
