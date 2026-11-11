# ODX: a node described by its ODX file

For an ECU that was not built with blobly_emb, its diagnostic description usually exists as ODX
(ISO 22901-1), packaged in a PDX. A CAN row of a project can name such an ECU as a **node**, so a
script reaches it, its DIDs and its DTCs by name exactly as it reaches a node of a blobly_emb
`system.toml` (`uds.node` in Lua, `net.nodes` in Python, `bb_node_*` in C).

```yaml
channels:
  - name: CAN1
    type: can
    interface: vcan0
    diagnostics:
      - node: BodyController
        odx: descriptions/BodyController.pdx   # a .pdx, one ODX file, or a folder of them
        variant: BodyController_Base           # the base or ECU variant's SHORT-NAME
        tx: "0x7E0"                            # the request id the tester sends
        rx: "0x7E8"                            # the ECU's response id
```

`odx:` is relative to the project, like a database. Every key is required, and the ids are CAN ids
(29-bit past 0x7FF). A project with `diagnostics:` is schema v13. The same node may be named on
several rows (one node, reached on each); a name another node already has is refused at Start, an
enabled row's entry read before a disabled row's.
`projects/odx-demo.blobnet` is a working example, `dbc/odx_demo.odx-d` its hand-made description.

## What is read

The reader (`blobly/odx`) takes the variant, then its parents (`PARENT-REFS`) in ODX's
inheritance precedence — ECU variant, base variant, functional group, protocol, ECU shared data,
and nearer before farther within one kind: a service or `DTC-DOP` a layer earlier in that order
names again overrides, and a `NOT-INHERITED-DIAG-COMM` or
`NOT-INHERITED-DOP` is left out of everything that parent passes on — what it inherited itself
included. A layer reached on two ways passes on what either way passes on.

- **DIDs** — every `DIAG-SERVICE` whose request is `0x22` or `0x2E` with one 16-bit DID at byte 1
  (a `0x22` request carrying anything past that DID — several DIDs — is said and not read).
  The value is laid out from the read service's positive response, whatever order the services
  come in (else the write service's request; a DID two of its services lay out differently is not written, whatever service follows), from byte 3: each `VALUE` parameter's `DATA-OBJECT-PROP` (a `STANDARD-LENGTH-TYPE`
  of whole bytes, `COMPU-METHOD` `IDENTICAL`) or `STRUCTURE` of them. An `A_UINT32` / `A_INT32`
  of 1, 2 or 4 bytes is an integer field, an `A_ASCIISTRING` a text, an `A_BYTEFIELD` bytes. The
  DID's name is its one value parameter's `SHORT-NAME`, else the service's.
- **DTCs** — every `DTC` of the variant's `DTC-DOPS`, by `SHORT-NAME` and `TROUBLE-CODE`; a node's
  DTC records then carry that name as their `fault`.
- **Files** — a `.pdx` is a ZIP (stored or deflated entries; ZIP64 and encryption are refused), of
  which every `.odx` / `.odx-*` entry is read. An ID is its document's: a reference resolves in
  its own document, or in the one its `DOCREF` names (by its container's `SHORT-NAME`).

## What is not read, and how it is said

Nothing the reader does not understand is read as 0. At Start each node's notes are printed (the
headless runner's stderr, the Script panel in the GUI):

- a DID whose value it cannot lay out — a `LINEAR`, `TEXTTABLE` or other scaling, a bit position,
  a bit mask, low byte first, a float, a parameter of no fixed length, a gap — is kept as **bytes**
  of its size (a value at a bit position spanning every byte it reaches; `kind` `data`; of no fixed size when that is not known), with the reason;
- every other service (by its service id), every `SINGLE-ECU-JOB`, and every layer or data
  dictionary element it does not use (`STATE-CHARTS`, `TABLES`, `COMPARAM-REFS`, a `PARENT-REF`'s
  `NOT-INHERITED-VARIABLES`, ...) is counted:
  `not read: 1 x DIAG-SERVICE 0x11, 1 x STATE-CHARTS`;
- a value that is not a number where one belongs (a `BYTE-POSITION`, a `TROUBLE-CODE`) is named
  with its text, and that DID's layout or that DTC is not read;
- a source that cannot be read, or a variant it does not have, still adds the node, its problem
  given, so a script is told why it has no names.

## Not yet

These are later steps (#638):

- **gates** — the sessions and security levels a DID is read and written in (`STATE-CHARTS`, the
  services' `PRE-CONDITION-STATE-REFS`): a DID with a `0x2E` service has a write gate that asks
  for nothing, and the ECU's own refusal says what it needs;
- **scaling** — `LINEAR` / `SCALE-LINEAR` and `TEXTTABLE` values as physical numbers and labels;
- **routines and I/O control** by short name (`0x31`, `0x2F`), and DIDs a service reads several
  of, or through a `TABLE`;
- **variant identification** — choosing the ECU variant from what the ECU answers;
- **DoIP** — a node named on a DoIP row, by its logical address;
- **the GUI's Diagnostics panel** — it names nodes from the system.toml only; a script started
  from the GUI's Script panel does see the rows' ODX nodes;
- **simulation** — a simulated ECU described by ODX.
