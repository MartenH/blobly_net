"""nodes — a started project's system model, through libblobly: blobly_emb's system.toml and its
nodes' ecu.toml descriptions as the run read them (the description its simulated servers answer by),
a UDS client by node name — the model supplies the channel and the ids — and a node's DIDs read and
written by name, through its layout. The rules are the engine's (blobly/sysview: the link, the
description, the DID codec and the write gate's plan); this module carries the calls and turns a
part's text into a Python value and back."""
import ctypes
from collections.abc import Mapping
from dataclasses import dataclass
from typing import TYPE_CHECKING, Literal, TypeAlias

from . import _lib
from ._lib import BloblyError, Refused, WriteGated
from .project import Named
from .uds import UdsClient, _data, _int

if TYPE_CHECKING:
    from .project import Channel, Project

# what read() returns: one part's value, or a value of several parts by label
DidValue: TypeAlias = int | bool | str | bytes | dict[str, int | bool]

# enum bb_did_kind and enum bb_part_kind, as the ecu.toml and the codec name them
DID_KINDS = {0: "ascii", 1: "bytes", 2: "signal", 3: "param", 4: "param_status", 5: "tx_saturations",
             6: "unknown"}
PART_KINDS = {0: "int", 1: "bool", 2: "text", 3: "bytes"}


@dataclass(frozen=True)
class Gate:
    """A DID's read or write gate: the sessions it is served in, by the names its ecu.toml gives
    them ("default", "programming", "extended"; none: any), and the security level it needs (0:
    none)."""
    sessions: tuple[str, ...]
    level: int

    def __str__(self) -> str:
        where = "/".join(self.sessions) if self.sessions else "any session"
        return where + (f", level {self.level}" if self.level else "")


@dataclass(frozen=True)
class DidPart:
    """One part of a DID's value, as read() returns it and write() takes it: `label` (a field's
    name, else "text" or "bytes"), `kind` "int", "bool", "text" or "bytes", and `hint` what it
    accepts, as the engine says it ("u16 0..360", "up to 18 characters", "1 bytes, hex")."""
    label: str
    kind: Literal["int", "bool", "text", "bytes"]
    hint: str


@dataclass(frozen=True)
class Did:
    """A DID a node lists: its description's own, then the ISO identification DIDs it does not
    declare. `kind` is where its value comes from ("ascii", "bytes", "signal", "param",
    "param_status", "tx_saturations", or "unknown": no layout known, read as bytes); `size` its
    value's bytes (None: the description does not say); `parts` what a value is made of;
    `by_label` whether read() answers its parts by label (several, or a parameter status, whose
    parts are its parameters) rather than its one part's value; `read_gate` None where none is
    declared (read in any session, unlocked), `write_gate` None where it is not writable."""
    id: int
    name: str
    kind: str
    size: int | None
    parts: tuple[DidPart, ...]
    by_label: bool
    read_gate: Gate | None
    write_gate: Gate | None
    index: int  # its position in the node's listing

    def __repr__(self) -> str:
        size = "" if self.size is None else f", {self.size} bytes"
        write = "" if self.write_gate is None else f", written in {self.write_gate}"
        return f"<Did 0x{self.id:04X} {self.name!r} {self.kind}{size}{write}>"


@dataclass(frozen=True)
class Fault:
    """A `[[fault]]` of a node's ecu.toml: its `name`, its 24-bit `dtc` and the DTC's SAE J2012
    display (`dtc_name`, U0401-00) — what a NodeClient's DTCs are named by (Dtc.fault)."""
    name: str
    dtc: int
    dtc_name: str


@dataclass(frozen=True)
class NodeTarget:
    """Where a node is reached on a channel of the run: on a CAN channel at its request id `tx`
    and response id `rx` (29-bit when `ext`), on a DoIP channel by the channel's own addressing
    (tx and rx None)."""
    channel: "Channel"
    tx: int | None
    rx: int | None
    ext: bool


class Dids(Named[Did]):
    """A node's DIDs (Node.dids), by name — `dids.SteerLimit`, `dids["ECU serial number"]` — or
    by position; Node.did takes an identifier too."""
    _noun = "DID"


class NodeFaults(Named[Fault]):
    """A node's faults (Node.faults), by name or by position."""
    _noun = "fault"


class Node:
    """A node of the run's system model: `name`; `described` (its ecu.toml was read, else
    `problem` says why and it lists only the ISO DIDs), `server` (it declares a diagnostic server),
    `reference_key` (its [uds] security_key is blobly_net's reference key, which
    UdsClient.security_access computes when given no key_fn); `dids`, `faults` and `targets`, where
    the run reaches it. It belongs to the run that listed it: after a stop and a start it goes on
    working while the run's model has a node of its name at its position, and refuses otherwise."""
    name: str
    described: bool
    server: bool
    reference_key: bool
    problem: str
    dids: Dids
    faults: NodeFaults
    targets: list[NodeTarget]

    def __init__(self, project: "Project", index: int, name: str) -> None:
        self._project, self._index, self.name = project, index, name

    def _fill(self, run):
        """Reads its description from the run (under the state lock)."""
        lib, n = _lib.lib(), self._index
        info = _lib.BbNode()
        _lib.check(lib.bb_node_info(n, ctypes.byref(info)))
        self.described, self.server = bool(info.described), bool(info.server)
        self.reference_key = bool(info.reference_key)
        self.problem = _lib.string(lib.bb_node_problem, n)
        dids = []
        for d in range(info.dids):
            x = _lib.BbDid()
            _lib.check(lib.bb_did_info(n, d, ctypes.byref(x)))
            kind = ctypes.c_int()
            parts = []
            for p in range(x.parts):
                label = _lib.string(lib.bb_did_part, n, d, p, ctypes.byref(kind))
                parts.append(DidPart(label, PART_KINDS.get(kind.value, "bytes"), _lib.string(lib.bb_did_hint, n, d, p)))
            dids.append(Did(x.id, _lib.string(lib.bb_did_name, n, d), DID_KINDS.get(x.kind, "unknown"),
                            None if x.size < 0 else x.size, tuple(parts), bool(x.by_label),
                            _gate(lib, n, d, 0, x.read_sessions, x.read_level) if x.read_gated else None,
                            _gate(lib, n, d, 1, x.write_sessions, x.write_level) if x.writable else None, d))
        self.dids = Dids(dids)
        faults, code = [], ctypes.c_uint32()
        for k in range(info.faults):
            name = _lib.string(lib.bb_node_fault, n, k, ctypes.byref(code))
            faults.append(Fault(name, code.value, _lib.string(lib.bb_dtc_name, code.value)))
        self.faults = NodeFaults(faults)
        self._names = {f.dtc: f.name for f in faults}
        channels = self._project.channels
        out, t = [], _lib.BbReach()
        for k in range(info.targets):
            _lib.check(lib.bb_node_target(n, k, ctypes.byref(t)))
            out.append(_target(channels[t.row], t))
        self.targets = out
        self._run = run

    def _live(self):
        """Refuses unless this node is in the current run's model (under the state lock)."""
        self._project.nodes  # re-read after a start: keeps this object if it is still there
        if self._run != _lib.state["run"]:
            raise BloblyError(f"node {self.name!r} is not in this run's system model; take it from "
                              "project.nodes again", _lib.BB_ERR_STATE)

    def did(self, key: int | str) -> Did | None:
        """The listed DID `key` names — its identifier, or its name (a signal's or parameter's, or
        ISO's for a standard identifier) — or None for an identifier the node does not list (a DID
        of no layout, read as its bytes). A name no DID has is a KeyError."""
        if isinstance(key, str):
            return self.dids[key]
        key = _int("did", key)
        return next((d for d in self.dids if d.id == key), None)

    def uds(self, channel: "Channel | str | None" = None) -> "NodeClient":
        """A NodeClient on this node, while the project is started: on the channel of the run that
        reaches it (or on `channel`, a Channel or its name, when it is reached on several), at the ids
        its system.toml (else its ecu.toml) gives it. Refused (Refused), saying how the node is
        reached, when no channel of the run does."""
        return NodeClient(self, channel)

    def __repr__(self) -> str:
        return f"<Node {self.name}>"


def _gate(lib, n, d, write, count, level) -> Gate:
    return Gate(tuple(_lib.string(lib.bb_did_session, n, d, write, k) for k in range(count)), level)


def _target(channel, t) -> NodeTarget:
    if t.doip:
        return NodeTarget(channel, None, None, False)
    return NodeTarget(channel, t.tx, t.rx, bool(t.ext))


class Nodes(Named[Node]):
    """The run's nodes (Project.nodes): `net.nodes.zone_a`, `net.nodes["zone-a"]`, by position,
    iterated in system.toml's order, completed by dir()."""
    _noun = "node"


def listed(project: "Project", old: list[Node] | None) -> Nodes:
    """The current run's nodes, keeping each of `old` still at its position under its name; the
    caller holds the state lock."""
    lib = _lib.lib()
    run = _lib.state["run"]
    out = []
    for i in range(_lib.check(lib.bb_node_count())):
        name = _lib.string(lib.bb_node_name, i)
        keep = old[i] if old is not None and i < len(old) else None
        if keep is None or keep.name != name:
            keep = Node(project, i, name)
        keep._fill(run)
        out.append(keep)
    return Nodes(out)


def _value(part: DidPart, text: str) -> int | bool | str | bytes:
    """A part's text as the engine's codec writes it, as a Python value."""
    if part.kind == "int":
        return int(text)
    if part.kind == "bool":
        return text == "true"
    if part.kind == "text":
        return text
    return bytes.fromhex(text)


def _text(did: Did, part: DidPart, v: object) -> str:
    """A part's Python value as the text the codec reads; its range is the engine's to refuse."""
    where = f"{did.name or hex(did.id)}.{part.label}"
    if part.kind in ("int", "bool"):
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, int):
            return str(v)
        raise TypeError(f"{where} is {'an integer' if part.kind == 'int' else 'True or False'}, not {v!r}")
    if part.kind == "text":
        if not isinstance(v, str):
            raise TypeError(f"{where} is a text, not {v!r}")
        if "\0" in v:
            raise ValueError(f"{where}: a text cannot carry a NUL: C would read it cut short")
        return v
    return _data(where, v).hex(" ")


def _texts(did: Did, value: object, fields: dict[str, object]) -> list[str]:
    """The texts of every part of `did` from write()'s arguments."""
    parts = did.parts
    if value is not _UNSET and fields:
        raise TypeError(f"write({did.name or hex(did.id)}): a value or fields by name, not both")
    if value is _UNSET and not fields:
        raise TypeError(f"write({did.name or hex(did.id)}): no value")
    if not did.by_label and value is not _UNSET and not isinstance(value, Mapping):
        return [_text(did, parts[0], value)]
    given = dict(value) if isinstance(value, Mapping) else fields
    labels = [p.label for p in parts]
    unknown = [k for k in given if k not in labels]
    missing = [k for k in labels if k not in given]
    if unknown or missing:
        raise TypeError(f"write({did.name or hex(did.id)}): its parts are {', '.join(labels)}"
                        + (f"; no part {', '.join(map(repr, unknown))}" if unknown else "")
                        + (f"; {', '.join(missing)} not given" if missing else ""))
    return [_text(did, p, given[p.label]) for p in parts]


_UNSET: object = object()


class NodeClient(UdsClient):
    """A UdsClient on a node of the run's system model (Node.uds): every UdsClient call, plus
    read and write by DID name through the node's layout, and DTCs named by its faults
    (Dtc.fault, SnapshotId.fault). A snapshot DID's size is the description's, so a 0x19 04 does
    not read the DID to learn it."""
    node: Node

    def __init__(self, node: Node, channel: "Channel | str | None" = None) -> None:
        from .project import Channel
        project = node._project
        with _lib.state_lock:
            node._live()
            if not project.started:
                raise BloblyError(f"{node.name}: the project is not started", _lib.BB_ERR_STATE)
            self._row = -1  # the channel asked for, -1: wherever the node is reached
            if channel is not None:
                ch = project.channels[channel] if isinstance(channel, str) else channel
                if not isinstance(ch, Channel) or ch._project is not project:
                    raise BloblyError(f"{channel!r} is not a channel of this project")
                ch._current()
                self._row = ch._index
            self.node = node
            self._target = self._reach()
            super().__init__(self._target.channel, self._target.tx, self._target.rx)

    def _reach(self) -> NodeTarget:
        """Where the node is reached in this run (under _lib.state_lock)."""
        t = _lib.BbReach()
        _lib.check(_lib.lib().bb_node_reach(self.node._index, self._row, ctypes.byref(t)))
        return _target(self.node._project.channels[t.row], t)

    def _open(self):
        """Opens the connection where the node is reached in this run (under _lib.state_lock) —
        refused when a start moved it from where this client was opened — and states the
        description's DID sizes and fault names as this run's (a size stated with did_size wins)."""
        self.node._live()
        if self._reach() != self._target:
            raise BloblyError(f"{self.node.name} is reached elsewhere in this run than this client was opened "
                              "on; open another with node.uds()", _lib.BB_ERR_STATE)
        super()._open()
        lib = _lib.lib()
        self._faults = self.node._names
        # one past what the carrier answers is left for the client to learn by reading the DID
        for d in self.node.dids:
            if d.size is not None and d.id not in self._did_sizes:
                lib.bb_uds_did_size(self._h, d.id, d.size)

    def _resolved(self, did: int | str) -> tuple[int, Did | None, int]:
        """(the node's index, DID `did` as the current run lists it, the run), read under one hold
        of the state lock: what the native call that follows is held to."""
        with _lib.state_lock:
            self.node._live()
            self._faults = self.node._names
            return self.node._index, self.node.did(did), _lib.state["run"]

    def read(self, did: int | str) -> DidValue:
        """0x22 of DID `did` (its name, or its identifier), decoded by the node's layout: an
        integer or a bool for a value of one field, a str for a text, bytes for fixed bytes or a DID
        of no known layout, and {label: value} where the Did is by_label. UndecodableAnswer when
        the answer is not the size the description lays out."""
        n, d, run = self._resolved(did)
        if d is None:
            return self.read_did(_int("did", did))
        data = self.read_did(d.id)
        lib = _lib.lib()
        with _lib.state_lock:
            if _lib.state["run"] != run:  # another run's model may list another DID at d.index
                raise BloblyError(f"{self.node.name}: the project was stopped or started while 0x{d.id:04X} "
                                  "was read; read it again", _lib.BB_ERR_STATE)
            texts = [_lib.string(lib.bb_did_text, n, d.index, data, len(data), p) for p in range(len(d.parts))]
        values = [_value(p, t) for p, t in zip(d.parts, texts)]
        if not d.by_label:
            return values[0]
        return {p.label: v for p, v in zip(d.parts, values)}

    def write(self, did: int | str, value: object = _UNSET, /, **fields: object) -> None:
        """0x2E of DID `did` (its name, or its identifier) with `value` — one field's integer or
        bool, a text, bytes, or a mapping of every part by label (or the parts as keywords: `x=1,
        y=2`) — encoded by the node's layout. Nothing is sent, and Refused raised, for a DID with
        no write gate or a value the layout does not hold (a TypeError for one of the wrong type);
        WriteGated (its `session` and `level`) when this client's connection has not established
        what the gate needs — switch and unlock first (session, security_access): nothing here
        does it for you."""
        lib = _lib.lib()
        needs = _lib.BbWriteNeeds()
        with self._lock:
            # the handle first, then the model it is held to: a stop and a start between them
            # leave a handle the engine refuses rather than a DID of another listing
            h = self._handle()
            n, d, _ = self._resolved(did)
            if d is None:
                raise Refused(f"0x2E 0x{_int('did', did):04X}: not writable: {self.node.name} does not list it")
            # a DID with no write gate is the engine's to refuse, in its words, whatever the value
            texts = [] if d.write_gate is None else [t.encode() for t in _texts(d, value, fields)]
            rc = lib.bb_uds_write_described(h, n, d.index, (ctypes.c_char_p * len(texts))(*texts), len(texts),
                                            ctypes.byref(needs))
            if rc < 0:
                e = self._enrich(h, _lib.error(rc))
                if isinstance(e, WriteGated):
                    e.session, e.level = needs.session, needs.level
                raise e

    def __repr__(self) -> str:
        return super().__repr__().replace("<UdsClient", f"<NodeClient {self.node.name} on", 1)
