# DBC attributes blobly reads and writes

A DBC is the one file the whole bench shares: blobly_net reads it to decode, simulate and
check traffic, and blobly_emb's generator (loom2v) reads it to build the ECU. Where the DBC's
own grammar has no place for something both sides must agree on, we add a **message
attribute** (`BA_ … BO_ <id> …`), or a signal attribute where it protects a signal group. This page is the definition of every attribute we add, for
both repositories. Change it here first, and change both readers together.

Attributes we did not invent but do read are listed at the end, so the line between "ours" and
"the industry's" stays visible.

## Ours: the E2E contract

Declares how a message is protected with **AUTOSAR E2E Profile 1**: CRC-8 (polynomial 0x1D,
start 0x00, no final XOR) over the Data ID (low byte, then high) and every payload byte except
the CRC's, with a 4-bit alive counter counting 0..14. With no further configuration, a message
carrying these attributes is:
- stamped by blobly_net's simulated sender of it;
- stamped by blobly_emb's generated bridge when the ECU sends it, and checked when it receives it.

blobly_net checks a received frame in the GUI's trace only for messages a `verify:` entry names. A
script (Python or Lua) judges every frame it reads by the declaration (unless a `verify:` entry for
the message says otherwise), `E2ETimeout` included, and stamps the declaration on a message it
sends by name ([scripting_python.md](scripting_python.md#e2e-on-what-a-script-reads-and-sends)).

```
BA_DEF_ BO_ "E2ECounterSignal" STRING;
BA_DEF_ BO_ "E2ECrcSignal" STRING;
BA_DEF_ BO_ "E2EProfile" STRING;
BA_DEF_ BO_ "E2EDataId" INT 0 65535;
BA_DEF_ BO_ "E2ETimeout" INT 0 65535;
BA_DEF_DEF_ "E2ECounterSignal" "";
BA_DEF_DEF_ "E2ECrcSignal" "";
BA_DEF_DEF_ "E2EProfile" "";
BA_DEF_DEF_ "E2EDataId" 0;
BA_DEF_DEF_ "E2ETimeout" 0;
BA_ "E2ECounterSignal" BO_ 769 "BrakeCounter";
BA_ "E2ECrcSignal" BO_ 769 "BrakeCrc";
BA_ "E2EProfile" BO_ 769 "P01";
BA_ "E2EDataId" BO_ 769 68;
BA_ "E2ETimeout" BO_ 769 300;
```

| attribute | type | meaning |
|---|---|---|
| `E2ECounterSignal` | STRING | the signal holding the alive counter: for Profile 1, 4 bits — AUTOSAR lets it sit in either nibble, and blobly_net stamps it wherever its signal is; blobly_emb requires the low nibble of a byte other than the CRC's. For Profile 5, a whole byte, the one after the CRC's two |
| `E2ECrcSignal` | STRING | the signal holding the CRC: for Profile 1, 8 bits, exactly one byte; for Profile 5, 16 bits little-endian (Intel) on a byte boundary, so its low byte comes first |
| `E2EProfile` | STRING | the profile. `"P01"` is AUTOSAR E2E Profile 1, the one both sides implement. `"PROFILE_01"` (AUTOSAR's name) and `"autosar_p01"` (blobly_net's internal name, written by builds before the `P01` spelling) read the same. `"P05"` is AUTOSAR E2E Profile 5 (CRC-16/CCITT-FALSE, an 8-bit counter 0..255), which blobly_net implements and blobly_emb does not; `"PROFILE_05"` and `"autosar_p05"` read the same. blobly_net's simulation also knows the checksum primitives `crc8_j1850`, `crc8_autosar`, `sum8` and `xor8`, which no AUTOSAR receiver accepts and blobly_emb refuses |
| `E2EDataId` | INT | the 16-bit Data ID that goes into the CRC. 0 is a valid Data ID, so a message without this attribute has none, and Profiles 1 and 5 refuse it |
| `E2ETimeout` | INT, ms | the receiver's E2E sender-loss timeout: no *valid* frame within this time and the receiver reports `timeout` (blobly_emb REQ-E2E-002). A sender ignores it. 0 means no timeout. On its own it declares no protection |

### Several windows in one frame: signal groups

AUTOSAR protects a *signal group*, not a frame, so one frame can carry several groups, each a
window of bytes with its own CRC, counter and Data ID. A DBC converted from an AUTOSAR system
description says so with `SIG_GROUP_` records and the same five attributes at **`SG_` scope**,
stated on the group's CRC signal (its counter signal where it has no CRC):

```
BA_DEF_ SG_ "E2ECounterSignal" STRING;
BA_DEF_ SG_ "E2ECrcSignal" STRING;
BA_DEF_ SG_ "E2EProfile" STRING;
BA_DEF_ SG_ "E2EDataId" INT 0 65535;
BA_ "E2ECrcSignal" SG_ 291 Speed_CRC "Speed_CRC";
BA_ "E2ECounterSignal" SG_ 291 Speed_CRC "Speed_Counter";
BA_ "E2EProfile" SG_ 291 Speed_CRC "P01";
BA_ "E2EDataId" SG_ 291 Speed_CRC 68;
BA_ "E2ECrcSignal" SG_ 291 Torque_CRC "Torque_CRC";
BA_ "E2ECounterSignal" SG_ 291 Torque_CRC "Torque_Counter";
BA_ "E2EProfile" SG_ 291 Torque_CRC "P01";
BA_ "E2EDataId" SG_ 291 Torque_CRC 69;
SIG_GROUP_ 291 SpeedGroup 1 : Speed_CRC Speed_Counter Speed;
SIG_GROUP_ 291 TorqueGroup 1 : Torque_CRC Torque_Counter Torque;
```

- The **window** is the bytes the members of the `SIG_GROUP_` holding that signal span, from the
  first byte any of them touches to the last. The profile is computed over the window alone, as
  if it were the frame: Profile 1's CRC covers the window's bytes but the CRC's, Profile 5's
  header is at the window's first byte offset by the CRC's place in it. The CRC and counter must
  lie inside it. Profiles 1 and 5 and the primitives all work per window.
- A frame's windows must not overlap; a declaration whose window overlaps one before it is not
  applied, and the simulation says so. A `BO_`-scope declaration is the whole payload, so it
  cannot sit beside a group's.
- A signal held by no `SIG_GROUP_`, or by several, has no window: the declaration is not applied,
  and the load notes say so. A file-wide default fills in a group's declaration as it does a
  message's.
- blobly_net writes the attributes back where it read them, `SG_`-scope ones with a `BA_DEF_ SG_`
  definition, and every `SIG_GROUP_` record. A file using both scopes gets a definition for each.
- An `E2E*` attribute at any other scope (`BU_`, `EV_`, a relation, the whole network) or naming a
  message the file does not define is not read, and the load notes say so; a Save drops it.
- blobly_emb reads the `BO_` scope only.

Rules both readers follow:

- **Positions come from the signals**, never from numbers in the attributes, so the layout is
  stated once, in the `SG_` lines. For Profile 1 the CRC must be one whole byte and the counter 4
  bits; for Profile 5 the CRC two bytes (low first) and the counter the byte after them. Neither
  may be a multiplexed signal: it would be stamped into every frame, over another mux branch's
  bits.
- **A file-wide default (`BA_DEF_DEF_`) fills in only messages that declare protection of their
  own.** A message that states none is not protected by a default. `E2EDataId` never comes from
  a default, because a Data ID every frame shares identifies none. An `E2ETimeout` default of 0
  states nothing, and a message's own `E2ETimeout`, 0 included, is never overridden by a default.
- **A value that is not what the attribute holds is refused by name when read.** It is never read
  as absent: a missing Data ID and Data ID 0 give different checksums. An empty value is malformed
  too. blobly_net's editor does **not** write a malformed value back on Save, because under an
  `INT` definition it would make the file unreadable to every other tool; so a Save drops it, and
  says so. A malformed `E2EDataId` takes the message's whole E2E declaration with it, because a
  declaration written back without its Data ID is a different one: for a profile that needs no
  Data ID it would be applied after the reload where it had been refused. A malformed
  `E2ETimeout` is dropped on its own, and the message then has no timeout. Fix the value rather
  than saving over it.
- **The local configuration may override, but only on purpose.**
  - In blobly_net, a node's `protect:` entry for the message takes precedence, and the
    difference is reported (for example, a wrong Data ID to test a receiver's rejection path).
  - In blobly_emb, `[[frame]].e2e` fields that contradict the DBC are refused unless the table
    says `deviates_from_dbc = true`; a field it leaves out is the DBC's.
- **Writers emit `"P01"` and `"P05"`.** blobly_net's DBC editor writes the attributes from the
  model; it never writes `autosar_p01` or `autosar_p05`. `cmd/arxml2dbc` writes `"P01"` only:
  its DBC is what blobly_emb builds from, and blobly_emb refuses any other profile.
- **From ARXML**, `cmd/arxml2dbc` exports the contract when the frame's E2E protection is
  PROFILE_01 with DATA-ID-MODE ALL-16-BIT, and its CRC and counter are signals at the declared
  offsets. A PROFILE_05 protection (its 16-bit CRC signal at its `OFFSET`, its 8-bit counter
  signal 16 bits on) is applied by blobly_net's own reader but not exported, since blobly_emb
  implements Profile 1 only; the fragment and the export's notes name it. Other Data ID modes (LOWER-8-BIT, ALTERNATING-8-BIT) cannot be stated with these
  attributes, so they are left out, and the export's notes say so. `E2ETimeout` is not taken
  from an ARXML file: the reader does not take a timeout from the E2E configuration, so the
  export leaves it for the DBC's author to add.

## Ours: provenance of an exported DBC

`cmd/arxml2dbc` writes one file-level comment saying where the DBC came from, so a generated
file is never mistaken for a hand-written one:

```
CM_ "arxml2dbc: source=<file> sha256=<hex> reader=<version> cluster=<name> schema=<AUTOSAR schema> inputs=<hex> dropped=<n> unresolved=<n> notes=<n>";
```

A system description read from several files (`arxml2dbc a.arxml b.arxml`, or a directory)
names each in `source`, comma-separated in the order read, and each one's hash in `sha256`, in
the same order, and in `schema` each distinct schema they declare; one file is written as it
always was.

`inputs` is a SHA-256 over everything the read depends on: the ARXML files and the model
file, its lists, the rules, policy, configuration and schema files it is merged by. A merge
rule or a schema changed changes it where `sha256` stays the same.

Nonzero `dropped`, `unresolved` or `notes` means the ARXML was read only partly; re-run the
export to see what was left out. Nothing reads this comment back.

## Read, not ours

| attribute | from | used for |
|---|---|---|
| `GenMsgCycleTime` (INT, ms) | Vector | a message's cycle time: the simulated senders' period, and blobly_emb's TX cadence. Its `BA_DEF_DEF_` gives the cycle of a message that states none |
| `GenMsgSendType` (ENUM) | Vector | when a message is sent: its index read against the file's own `BA_DEF_` (the choices differ between databases), or the quoted choice, as `VFrameFormat` is. A choice is read as cyclic (`cyclic`, `cyclicIfActive`, …), event (`spontaneous`, `OnChange`, `OnWrite`, …), mixed (cyclic and event, `cyclicAndSpontaneous`, `Mixed`, `POE`, …) or none (`NoMsgSendType`). A simulated node sends a message on its cycle unless it is event-only or none, and an event or mixed one when a generator changes one of its signals. Written back with Vector's enum, a choice the database uses that is not in it appended |
| `GenMsgCycleTimeFast`, `GenMsgNrOfRepetition`, `GenMsgDelayTime`, `GenMsgStartDelayTime` (INT, ms or a count) | Vector | an event send's repetitions (after the first, a fast cycle apart), the least time between two sends of an event or mixed message (cyclic ones included), and the time from a simulated node's start to its first send |
| `GenSigStartValue` (INT, raw; a `BA_DEF_ SG_` attribute) | Vector | the raw value a node sends before anything sets the signal — a negative one two's complement for a signed signal. A simulated node and a `senders:` generator send it for a signal they do not set; a script's `encode` / `send_message` start at raw 0. The file-wide `BA_DEF_DEF_` is the start value of every signal that states none (0 included); a Save writes a default of 0 and a record per signal starting elsewhere |
| `VFrameFormat` (ENUM) | Vector | The message's frame format, read against the file's own enum (an index, or the quoted choice), per message or from `BA_DEF_DEF_`: `StandardCAN` / `ExtendedCAN` / `J1939PG` classic (`J1939PG` also marks a J1939 message, whose PGN blobly_net reads), `StandardCAN_FD` / `ExtendedCAN_FD` CAN-FD. blobly_net sends a message built by name — a simulated node, a generator, a script's send by name — in the format stated; written back on Save, and by `arxml2dbc`'s export. Read however the record's whitespace is spelled (CANdb++ writes `BA_DEF_DEF_  "VFrameFormat"` with two spaces) |
| `CANFD_BRS` (ENUM `"0","1"`) | Vector | Whether a CAN-FD message switches its bit rate; unstated, `"1"` (the default of Vector's CAN-FD templates). Written back on Save for every CAN-FD message |
