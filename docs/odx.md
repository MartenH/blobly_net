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
  of whole bytes) or `STRUCTURE` of them. An `A_UINT32` / `A_INT32`
  of 1, 2 or 4 bytes is an integer field, an `A_ASCIISTRING` a text, an `A_BYTEFIELD` bytes. The
  DID's name is its one value parameter's `SHORT-NAME`, else the service's.
- **Scaling** — an integer field's `COMPU-METHOD`: `IDENTICAL` is the integer itself; `LINEAR` (one
  `COMPU-SCALE`) and `SCALE-LINEAR` (several, each over its `LOWER-LIMIT`..`UPPER-LIMIT`) are a
  **number**, physical = (V0 + V1 · raw) / D0 from the `COMPU-RATIONAL-COEFFS`, in the unit its
  `UNIT-REF` names; `TEXTTABLE` is a **label**, each `COMPU-SCALE`'s `COMPU-CONST`/`VT` naming the
  raw values in its limits (no `UPPER-LIMIT`: the lower one alone), the `COMPU-DEFAULT-VALUE` naming
  the rest. A limit's `INTERVAL-TYPE` is read (`OPEN` excludes it, `INFINITE` is unbounded). A
  number is written as the raw value whose physical value is nearest it — the first scale's on a
  tie, so one between two scales' values goes to the nearer of them — and a raw value in
  no scale is refused, never shown as a number; a
  label is written as its `COMPU-INVERSE-VALUE`, else its lower limit, and a decimal integer that is
  no label as itself (a raw value no label names reads as the default's label, else as its
  number). `COMPU-PHYS-TO-INTERNAL`,
  a `LINEAR`'s `COMPU-DEFAULT-VALUE`, and a `DATA-OBJECT-PROP`'s `INTERNAL-CONSTR` / `PHYS-CONSTR`
  are said and not read.
- **Gates** — a DID's read gate is its read service's `PRE-CONDITION-STATE-REFS`, its write gate its
  write service's. A state of a `STATE-CHART` whose `SEMANTIC` names `SESSION` is the session the
  sub-function of every `0x10` service whose `STATE-TRANSITION-REFS` enter it (its chart's start
  state: the default session); one of a `SECURITY` chart is the level of every `0x27` sendKey
  (sub-function 2L) whose transitions enter it (its start state: locked). States of one chart are alternatives: each
  session is listed (one ISO does not name by its sub-function, `0x40`), the lowest level is
  needed. A write is then refused until the connection has
  switched and unlocked as the gate asks (`WriteGated` in Python, the error's words in Lua); no
  precondition is no gate (a write service's: written in any session).
- **DTCs** — every `DTC` of the variant's `DTC-DOPS`, by `SHORT-NAME` and `TROUBLE-CODE`; a node's
  DTC records then carry that name as their `fault`.
- **Files** — a `.pdx` is a ZIP (stored or deflated entries, a deflated one refused as soon as it inflates past the size the archive states for it; ZIP64 and encryption are refused), of
  which every `.odx` / `.odx-*` entry is read — the rest (its index, attachments) are never
  inflated, and the archive is refused when the entries read state more than 512 MB together or
  two directory records name one entry. An ID is its document's: a reference resolves in
  its own document, or in the one its `DOCREF` names (by its container's `SHORT-NAME`).

## What is not read, and how it is said

Nothing the reader does not understand is read as 0. At Start each node's notes are printed (the
headless runner's stderr, the Script panel in the GUI):

- a DID whose value it cannot lay out — a `COMPU-METHOD` other than `IDENTICAL`, `LINEAR`,
  `SCALE-LINEAR` and `TEXTTABLE` (`RAT-FUNC`, `TAB-INTP`, `COMPUCODE`, ...), a scale that is not
  one (a constant, a denominator of 0, a coefficient that is not a number), a bit position,
  a bit mask, low byte first, a float, a parameter of no fixed length, a gap — is kept as **bytes**
  of its size (a value at a bit position spanning every byte it reaches; `kind` `data`; of no fixed size when that is not known), with the reason;
- every other service (by its service id — a `0x10` or `0x27` service too, whose state
  transitions are read for the gates but which a script does not call by name), every
  `SINGLE-ECU-JOB`, and every layer or data dictionary element it does not use (`TABLES`,
  `COMPARAM-REFS`, a `PARENT-REF`'s `NOT-INHERITED-VARIABLES`, a DID service's `AUDIENCE` and
  `SDGS`, ...) is counted:
  `not read: 2 x DIAG-SERVICE 0x10, 1 x DIAG-SERVICE 0x11`;
- a precondition it cannot give a meaning — a state no `0x10` / `0x27` transition enters and that
  is not its chart's start state, a chart whose `SEMANTIC` is neither, a precondition on a
  parameter's value — is said and left out of the gate; where a session or security state left
  out has no other of its chart beside it, the gate is **unresolved** (its words say which state),
  and no write is planned by it rather than one sent as if the gate were open;
- a value that is not a number where one belongs (a `BYTE-POSITION`, a `TROUBLE-CODE`) is named
  with its text, and that DID's layout or that DTC is not read;
- a source that cannot be read, or a variant it does not have, still adds the node, its problem
  given, so a script is told why it has no names.

## Not yet

These are later steps (#638):

- **gates from anything but state charts** — an `AUDIENCE`, or a vendor's `SDGS` on a service, is
  not read as a gate;
- **other compu methods** — `RAT-FUNC`, `SCALE-RAT-FUNC`, `TAB-INTP`, `COMPUCODE`, and a scaled
  value's constraints;
- **routines and I/O control** by short name (`0x31`, `0x2F`), and DIDs a service reads several
  of, or through a `TABLE`;
- **variant identification** — choosing the ECU variant from what the ECU answers;
- **DoIP** — a node named on a DoIP row, by its logical address;
- **the GUI's Diagnostics panel** — it names nodes from the system.toml only; a script started
  from the GUI's Script panel does see the rows' ODX nodes;
- **simulation** — a simulated ECU described by ODX.
