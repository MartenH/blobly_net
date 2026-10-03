# DBC attributes blobly reads and writes

A DBC is the one file the whole bench shares: blobly_net reads it to decode, simulate and
check traffic, and blobly_emb's generator (loom2v) reads it to build the ECU. Where the DBC's
own grammar has no place for something both sides must agree on, we add a **message
attribute** (`BA_ … BO_ <id> …`). This page is the definition of every attribute we add, for
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

blobly_net checks a received frame only for messages a `verify:` entry names.

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
| `E2ECounterSignal` | STRING | the signal holding the 4-bit alive counter. AUTOSAR lets it sit in either nibble, and blobly_net stamps it wherever its signal is; blobly_emb requires the low nibble of a byte other than the CRC's |
| `E2ECrcSignal` | STRING | the signal holding the CRC: 8 bits, exactly one byte |
| `E2EProfile` | STRING | the profile. `"P01"` is AUTOSAR E2E Profile 1, the one both sides implement. `"PROFILE_01"` (AUTOSAR's name) and `"autosar_p01"` (blobly_net's internal name, written by builds before the `P01` spelling) read the same. blobly_net's simulation also knows the checksum primitives `crc8_j1850`, `crc8_autosar`, `sum8` and `xor8`, which no AUTOSAR receiver accepts and blobly_emb refuses |
| `E2EDataId` | INT | the 16-bit Data ID that goes into the CRC. 0 is a valid Data ID, so a message without this attribute has none, and Profile 1 refuses it |
| `E2ETimeout` | INT, ms | the receiver's E2E sender-loss timeout: no *valid* frame within this time and the receiver reports `timeout` (blobly_emb REQ-E2E-002). A sender ignores it. 0 means no timeout. On its own it declares no protection |

Rules both readers follow:

- **Positions come from the signals**, never from numbers in the attributes, so the layout is
  stated once, in the `SG_` lines. The CRC must be one whole byte and the counter 4 bits. Neither
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
- **Writers emit `"P01"`.** blobly_net's DBC editor and `cmd/arxml2dbc` write the attributes
  from the model; neither ever writes `autosar_p01`.
- **From ARXML**, `cmd/arxml2dbc` exports the contract when the frame's E2E protection is
  PROFILE_01 with DATA-ID-MODE ALL-16-BIT, and its CRC and counter are signals at the declared
  offsets. Other Data ID modes (LOWER-8-BIT, ALTERNATING-8-BIT) cannot be stated with these
  attributes, so they are left out, and the export's notes say so. `E2ETimeout` is not taken
  from an ARXML file: the reader does not take a timeout from the E2E configuration, so the
  export leaves it for the DBC's author to add.

## Ours: provenance of an exported DBC

`cmd/arxml2dbc` writes one file-level comment saying where the DBC came from, so a generated
file is never mistaken for a hand-written one:

```
CM_ "arxml2dbc: source=<file> sha256=<hex> reader=<version> cluster=<name> schema=<AUTOSAR schema> dropped=<n> unresolved=<n> notes=<n>";
```

Nonzero `dropped`, `unresolved` or `notes` means the ARXML was read only partly; re-run the
export to see what was left out. Nothing reads this comment back.

## Read, not ours

| attribute | from | used for |
|---|---|---|
| `GenMsgCycleTime` (INT, ms) | Vector | a message's cycle time: the simulated senders' period, and blobly_emb's TX cadence |
| `VFrameFormat` (ENUM) | Vector | `J1939PG` marks a J1939 message (blobly_net reads its PGN); `StandardCAN_FD` / `ExtendedCAN_FD` mark CAN-FD frames in `arxml2dbc`'s export |
