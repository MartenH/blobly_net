"""uds — UDS (ISO 14229) diagnostics on a channel, through libblobly: a client over ISO-TP on a CAN
channel's bus, or over a DoIP channel's connection to its entity, opened by the rule the Lua
uds.open opens by, each call one of the engine's helpers. Answers come back decoded and failures
typed, so nothing here reads a UDS payload."""
import ctypes
import threading
import time
from dataclasses import dataclass
from collections.abc import Callable, Sequence
from typing import TYPE_CHECKING, Literal, Self

from . import _lib
from ._lib import BloblyError, ByteData, ConnectionLost, NegativeResponse

if TYPE_CHECKING:
    from .project import Channel

# how many key_fn callbacks this thread is inside: each runs holding its client's lock
_callbacks = threading.local()

# a whole ISO-TP PDU (4095 bytes) fits, so an answer comes back in one call
_CAP = 4096


@dataclass(frozen=True)
class Exchange:
    """One request a UdsClient put through, answered or not (UdsClient.last).

    `request` is the request as it went out (a suppressed one with its bit set); `answer` the
    positive answer, a negative one's 7F <sid> <nrc>, an undecodable one as it came, or b"" when
    none came; `nrc` the negative response's code, else None. `sent` is whether the request went out
    whole (False: it failed before or during its send, so the ECU never had all of it, and repeating
    it does not ask twice); `rtt_us` the time from the send to the final answer or the failure; `pending` how many responsePending (0x78) came before the
    answer, and `pending_us` the time from the first of them to the end (0 without one)."""
    request: bytes
    answer: bytes
    nrc: int | None
    sent: bool
    rtt_us: int
    pending: int
    pending_us: int


@dataclass(frozen=True)
class Dtc:
    """A DTC as the ECU reported it: `code` (24 bits, the DTC and its failure-type byte), `name`
    (SAE J2012's display, U0121-00), `status` (ISO 14229-1's status byte), `availability` (the
    status bits the ECU reports; 0xFF where its answer carries no mask, 0x19 04 / 06), and `bits`,
    each status bit the ECU reports by ISO's name (testFailed, testFailedThisOperationCycle,
    pendingDTC, confirmedDTC, testNotCompletedSinceLastClear, testFailedSinceLastClear,
    testNotCompletedThisOperationCycle, warningIndicatorRequested): a bit outside `availability`
    is left out, since the ECU says nothing about it, so ask `bits.get(name)` of an ECU that may not
    report every bit (None: not reported). A 0x19 04 / 06 answer carries no mask: every bit is
    read as it gives it. `fault` is the name a node's description gives the DTC (a NodeClient's;
    None for a plain UdsClient, or a DTC the description does not declare)."""
    code: int
    name: str
    status: int
    availability: int
    bits: dict[str, bool]
    fault: str | None = None


@dataclass(frozen=True)
class SnapshotId:
    """A DTC holding a snapshot (0x19 03), and the snapshot record's number; `fault` as Dtc's."""
    code: int
    name: str
    record: int
    fault: str | None = None


@dataclass(frozen=True)
class SnapshotRecord:
    """One snapshot record of a DTC: its number, and each DID it captured with its value then, in
    the ECU's order (a DID listed twice keeps its first value)."""
    number: int
    dids: dict[int, bytes]


@dataclass(frozen=True)
class Snapshot:
    """A DTC's snapshots (0x19 04): the DTC with its status, and its records (none is a valid
    answer: nothing stored)."""
    dtc: Dtc
    records: list[SnapshotRecord]


@dataclass(frozen=True)
class Extended:
    """A DTC's extended data (0x19 06): the DTC with its status, its records by number (the
    bytes), and blobly_emb's counters where the answer carries them — `occurrence` (record 0x01),
    `aging` (0x02), `failed_cycles` (0x03), None where it does not (absent is not zero)."""
    dtc: Dtc
    records: dict[int, bytes]
    occurrence: int | None
    aging: int | None
    failed_cycles: int | None


@dataclass(frozen=True)
class FunctionalReply:
    """One target's reply to a functional request (Channel.uds_functional): `outcome` "positive",
    "negative", "silent" (nothing within the window: normal for a functional request, and what a
    suppressed positive response looks like), "pending" (responsePending, then nothing within its
    P2*) or "failed"; `answer` the answer's bytes (positive, or 7F <sid> <nrc>); `nrc` a negative
    answer's code, else None; `pended` whether responsePending came on the way; `error` why it
    failed, else ""."""
    outcome: str
    answer: bytes
    nrc: int | None
    pended: bool
    error: str


_bits: tuple[tuple[int, str], ...] | None = None


def _status_bits() -> tuple[tuple[int, str], ...]:
    """ISO 14229-1's status bits as the engine names them, (mask, name) low to high: read once,
    and published whole, so a thread never sees part of the list."""
    global _bits
    if _bits is None:
        lib, bits, mask = _lib.lib(), [], ctypes.c_uint8()
        for k in range(8):  # the status byte's bits, low to high
            name = _lib.string(lib.bb_dtc_status_bit, k, ctypes.byref(mask))
            bits.append((mask.value, name))
        _bits = tuple(bits)
    return _bits


def _dtc(d, faults: dict[int, str]) -> Dtc:
    """A Dtc from a bb_dtc, named by `faults` (a node's, by DTC)."""
    bits = {name: bool(d.status & mask) for mask, name in _status_bits() if d.availability & mask}
    return Dtc(d.code, _lib.string(_lib.lib().bb_dtc_name, d.code), d.status, d.availability, bits,
               faults.get(d.code))


def _dtc_code(dtc: int | str) -> int:
    """A DTC given by its code, or by its display name ("U0401-00", or "U0401" for failure type
    00, either case)."""
    if isinstance(dtc, str):
        if "\0" in dtc:
            raise ValueError(f"not a DTC name: {dtc!r}")
        code = ctypes.c_int()
        if _lib.check(_lib.lib().bb_dtc_code(dtc.encode(), ctypes.byref(code))) == _lib.BB_NONE:
            raise ValueError(f"not a DTC name: {dtc!r}")
        return code.value
    return _int("dtc", dtc)


def _int(name: str, v: object, bits: int = 32) -> int:
    """An integer argument, refused before ctypes would wrap it: its range is the engine's to
    refuse (a byte, a DID, 24 bits), but past the C type it would arrive as another number."""
    if isinstance(v, bool) or not isinstance(v, int):
        raise TypeError(f"{name} must be an integer, not {v!r}")
    if not -(1 << (bits - 1)) <= v < 1 << (bits - 1):
        raise ValueError(f"{name} {v} is past what a {bits}-bit C integer holds")
    return v


_data = _lib.byte_data  # the one rule for a byte-string argument


def _put(fn, *args) -> bytes:
    """The bytes a library call copies into a buffer (bb.h: one past cap is fetched whole again
    with bb_uds_data's handle, args[0]). Raises the call's error."""
    buf = ctypes.create_string_buffer(_CAP)
    n = _lib.check(fn(*args, buf, _CAP))
    if n <= _CAP:
        return buf.raw[:n]
    return _lib.bytes_of(_lib.lib().bb_uds_data, args[0])


# handles of clients and ISO-TP channels collected without close(), each with the bb.h call that
# closes it, let go at the next call that opens or closes one: a finalizer may run between a failed
# call and the read of its error, and a close there would replace the thread's error text and NRC
_orphans: list[tuple[str, int]] = []


def _close_orphans() -> None:
    """Closes the collected handles (under _lib.state_lock)."""
    lib = _lib.lib()
    while _orphans:
        closer, h = _orphans.pop()
        getattr(lib, closer)(h)


def reference_key(seed: ByteData) -> bytes:
    """blobly_net's reference key for a 0x27 seed (each byte XOR 0xFF): the key the simulated
    ECUs accept, and a blobly_emb node whose description names it (docs/security_access.md)."""
    s = _data("seed", seed)
    lib = _lib.lib()
    buf = ctypes.create_string_buffer(max(len(s), 1))
    n = _lib.check(lib.bb_reference_key(s, len(s), buf, len(buf)))
    return buf.raw[:n]


def _nrc_name(nrc: int) -> str:
    return _lib.string(_lib.lib().bb_nrc_name, nrc)


class UdsClient:
    """A UDS client on a channel (Channel.uds). On a CAN channel requests go out on `tx` and answers
    come back on `rx`, 29-bit when `ext`; on a DoIP channel they ride its connection to the entity,
    from logical address `tester` to `ecu` (tx and rx None). Every call is bounded by the engine's
    timing — the first answer within 1000 ms (a 0x10 answer's P2 can lengthen that), each
    responsePending (0x78) then waited for the ECU's P2* + 1000 ms, one request never longer than
    120 s — and fails with a typed error: NegativeResponse (with its NRC), Timeout, PendingExpired,
    UndecodableAnswer, CarrierFailed (ConnectionLost when a DoIP connection is gone), or Refused
    when nothing was asked of the ECU. Opening on a DoIP channel may raise RoutingDenied.

    `with ch.uds() as diag:` closes it at the end of the block. A stop and a start of the project
    let its connection go and the next call opens another on the same ids; so does a
    ConnectionLost (that reopen ended by a close from another thread, as a call is). A client of a
    channel a reload did not keep refuses. Calls on one client are
    serialised, so threads may share it; close() from another thread ends a call in progress
    there.

    The waits are its attributes, `timeout_ms`, `p2_star_ms`, `margin_ms` and `pending_budget_ms`:
    read as they stand, set from the next request on (ch.uds takes them as keywords too). What a
    script set holds on every connection the client opens; one opened after a stop and start begins
    from it again, without what a 0x10 answer adopted.
    On a DoIP channel `retarget` moves the connection to a node behind the gateway its entity is."""

    _opener = "bb_uds_open"  # the call that opens its connection, the ids it defaults to
    channel: "Channel"
    tx: int | None
    rx: int | None
    ext: bool
    tester: int | None
    ecu: int | None

    def __init__(self, channel: "Channel", tx: int | None = None, rx: int | None = None, *,
                 timeout_ms: int | None = None, p2_star_ms: int | None = None, margin_ms: int | None = None,
                 pending_budget_ms: int | None = None) -> None:
        self.channel = channel
        self._ask = (None if tx is None else _int("tx", tx, 64), None if rx is None else _int("rx", rx, 64))
        # the waits a script stated, stated again on each connection the client opens
        stated = (("timeout_ms", timeout_ms), ("p2_star_ms", p2_star_ms), ("margin_ms", margin_ms),
                  ("pending_budget_ms", pending_budget_ms))
        self._timing = {name: _int(name, ms) for name, ms in stated if ms is not None}
        for name, ms in self._timing.items():  # refused before anything opens
            _lib.check(_lib.lib().bb_uds_check_wait(_lib.WAITS[name], ms))
        self._target: int | None = None  # retarget's address, named again on each DoIP connection
        self._entity: int | None = None  # the DoIP channel's ecu_address
        self.tx = self.rx = None
        self.ext = False
        self.tester = self.ecu = None  # a DoIP channel's logical addresses
        self._h = None
        self._closed = False
        self._faults: dict[int, str] = {}  # the fault names a node's description gives its DTCs
        self._did_sizes: dict[int, int] = {}  # what did_size / ext_record_size stated, for a reopen
        self._ext_sizes: dict[int, int] = {}
        self._lock = threading.RLock()  # re-entered: security_access holds it across two calls
        self._in_key_fn = False  # security_access is inside its key_fn
        self._opened = False  # a connection was opened before the current one
        with _lib.state_lock:
            self._open()

    def _open(self):
        """Opens the connection (under _lib.state_lock)."""
        lib = _lib.lib()
        _close_orphans()
        self.channel._current()
        if not self.channel._project.started:
            raise BloblyError(f"{self.channel.name}: the project is not started", _lib.BB_ERR_STATE)
        ids = [None if v is None else ctypes.byref(ctypes.c_int64(v)) for v in self._ask]
        out = _lib.BbUdsTarget()
        self._h = _lib.check(getattr(lib, self._opener)(self.channel._index, ids[0], ids[1], ctypes.byref(out)))
        self.tx = self.rx = self.tester = self.ecu = None
        self.ext = False
        if self.channel.kind == "doip":  # bb_uds_target holds the logical addresses there
            self.tester, self.ecu = out.tx, out.rx
            self._entity = out.rx
        else:
            self.tx, self.rx, self.ext = out.tx, out.rx, bool(out.ext)
        self.channel._uds.add(self)
        # the sizes stated on an earlier connection hold on this one too, or it is not opened: a
        # call on it would ask without them; and a seed of an earlier one answers no key here
        try:
            if self._opened:
                _lib.check(lib.bb_uds_replaces(self._h))
            self._state_waits(self._h, self._timing)
            if self._target is not None:
                _lib.check(lib.bb_uds_retarget(self._h, ctypes.byref(ctypes.c_int64(self._target))))
                self.ecu = self._target
            for did, size in self._did_sizes.items():
                _lib.check(lib.bb_uds_did_size(self._h, did, size))
            for record, size in self._ext_sizes.items():
                _lib.check(lib.bb_uds_ext_record_size(self._h, record, size))
        except BloblyError:
            self._let_go()
            raise
        self._opened = True

    def _handle(self) -> int:
        with _lib.state_lock:
            _close_orphans()
            if self._closed:
                raise BloblyError(f"{self!r} is closed", _lib.BB_ERR_HANDLE)
            if self._h is None:
                self._open()
            return self._h

    def _let_go(self):
        """Closes the connection, keeping the client: its next call opens another (a stop)."""
        h, self._h = self._h, None
        if h is not None:
            try:
                _lib.check(_lib.lib().bb_uds_close(h))
            except BloblyError:
                pass  # already gone

    def close(self) -> None:
        """Lets the connection go for good: a later call refuses."""
        with _lib.state_lock:
            _close_orphans()
            self._closed = True
            self._let_go()
            self.channel._uds.discard(self)

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc: object) -> Literal[False]:
        self.close()
        return False

    def __del__(self) -> None:
        # an unclosed client lets its bus subscription go with it, at the next call (_orphans):
        # nothing is called into here, since this may run between another call and its error
        try:
            if self._h is not None:
                _orphans.append(("bb_uds_close", self._h))
        except Exception:
            pass

    def _enrich(self, h: int, e: BloblyError) -> BloblyError:
        """A negative response given its code (the thread's, so a close since cannot take it) and
        the exchange it ended, read from handle h (None when the handle was closed since); a lost
        DoIP connection let go, so the next call opens another."""
        if isinstance(e, ConnectionLost):
            try:
                e.exchange = self._last(h)
            except BloblyError:
                e.exchange = None
        elif isinstance(e, NegativeResponse):
            lib = _lib.lib()
            nrc = ctypes.c_uint8()
            if lib.bb_last_nrc(ctypes.byref(nrc)) == 0:  # before any other call replaces it
                e.nrc, e.nrc_name = nrc.value, _nrc_name(nrc.value)
            try:
                e.exchange = self._last(h)
            except BloblyError:
                e.exchange = None
        return e

    def _call(self, fn, *args) -> int:
        with self._lock:
            return self._call_on(self._handle(), fn, *args)

    def _call_on(self, h: int, fn, *args) -> int:
        rc = fn(h, *args)
        if rc < 0:
            raise self._enrich(h, _lib.error(rc))
        return rc

    def _bytes(self, fn, *args) -> bytes:
        with self._lock:
            return self._bytes_on(self._handle(), fn, *args)

    def _bytes_on(self, h: int, fn, *args) -> bytes:
        try:
            return _put(fn, h, *args)
        except BloblyError as e:
            raise self._enrich(h, e)

    def _last(self, h: int) -> Exchange | None:
        lib = _lib.lib()
        x = _lib.BbUdsExchange()
        req, ans = ctypes.create_string_buffer(_CAP), ctypes.create_string_buffer(_CAP)
        if _lib.check(lib.bb_uds_last(h, ctypes.byref(x), req, _CAP, ans, _CAP)) == _lib.BB_NONE:
            return None
        if x.request_len > _CAP or x.answer_len > _CAP:
            req, ans = ctypes.create_string_buffer(x.request_len), ctypes.create_string_buffer(x.answer_len)
            _lib.check(lib.bb_uds_last(h, ctypes.byref(x), req, x.request_len, ans, x.answer_len))
        return Exchange(req.raw[:x.request_len], ans.raw[:x.answer_len], x.nrc if x.negative else None,
                        bool(x.sent), x.rtt_us, x.pending, x.pending_us)

    @property
    def last(self) -> Exchange | None:
        """The last request this client put through, whichever call made it, answered or not;
        None before the first, after a stop let the connection go, and after a functional request
        (Channel.uds_functional), whose FunctionalReply is the client's answer."""
        with self._lock, _lib.state_lock:  # a stop on another thread cannot close it under the read
            return None if self._h is None else self._last(self._h)

    def raw(self, request: ByteData) -> bytes:
        """Sends `request` and returns the positive answer, its SID included. An answer that names
        another request (a late or repeated one) is skipped and the wait goes on."""
        r = _data("request", request)
        with self._lock:  # the key_fn's own thread holds it: another thread waits its turn
            self._no_seed_in_key_fn(r)
            return self._bytes(_lib.lib().bb_uds_raw, r, len(r))

    def _no_seed_in_key_fn(self, r: bytes) -> None:
        """Refuses a 0x27 seed request inside this client's security_access key_fn, by whichever
        call it would go out: its seed would stand in for the one the key_fn's key answers. Asked
        holding the client's lock, which the key_fn's own thread holds."""
        if self._in_key_fn and r[:1] == b"\x27" and len(r) > 1 and r[1] & 1:
            raise BloblyError(f"{self!r}: a 0x27 seed request inside a security_access key_fn", _lib.BB_ERR_STATE)

    def raw_suppressed(self, request: ByteData) -> bool:
        """Sends `request` with suppress-positive-response set on its sub-function: silence is
        success, a refusal raises. Returns whether a positive answer came anyway (the ECU ignored
        the bit); one owed after responsePending is waited for and does not count."""
        r = _data("request", request)
        with self._lock:
            self._no_seed_in_key_fn(r)
            return self._call(_lib.lib().bb_uds_raw_suppressed, r, len(r)) == _lib.BB_ANSWERED

    def session(self, session: int = 0x01) -> bytes:
        """0x10 DiagnosticSessionControl: returns the answer after its SID — the session, then its
        timing record (P2, P2*), which the client adopts for its waits."""
        return self._bytes(_lib.lib().bb_uds_session, _int("session", session))

    def tester_present(self) -> None:
        """0x3E 00 TesterPresent: keeps a non-default session alive."""
        self._call(_lib.lib().bb_uds_tester_present)

    def read_did(self, did: int) -> bytes:
        """0x22 ReadDataByIdentifier: the DID's value."""
        return self._bytes(_lib.lib().bb_uds_read_did, _int("did", did))

    def write_did(self, did: int, data: ByteData) -> None:
        """0x2E WriteDataByIdentifier."""
        d = _data("data", data)
        self._call(_lib.lib().bb_uds_write_did, _int("did", did), d, len(d))

    def security_access(self, level: int, key_fn: Callable[[bytes], ByteData] | None = None) -> bytes:
        """0x27 SecurityAccess: requests the seed for `level` (odd), computes the key with
        `key_fn(seed)` — blobly_net's reference key when None — and sends it at level + 1. Returns
        the seed. An all-zero seed is ISO 14229-1's "already unlocked": no key is sent. A wrong key
        raises NegativeResponse (NRC 0x35)."""
        level = _int("level", level)
        unlocked = ctypes.c_uint8()
        # seed, key and the call between them as one, on one connection: no other call takes the
        # seed, and a stop meanwhile fails the key rather than send it on a connection of its own
        with self._lock:
            if self._in_key_fn:
                # its seed would replace the outer one's, whose key then goes against the wrong seed
                raise BloblyError(f"{self!r}: security_access inside its own key_fn", _lib.BB_ERR_STATE)
            h = self._handle()
            seed = self._bytes_on(h, _lib.lib().bb_uds_security_seed, level, ctypes.byref(unlocked))
            if unlocked.value:
                return seed
            if key_fn is None:
                key = reference_key(seed)
            else:
                _callbacks.depth = getattr(_callbacks, "depth", 0) + 1
                self._in_key_fn = True
                try:
                    key = _data("the key key_fn returned", key_fn(seed))
                finally:
                    self._in_key_fn = False
                    _callbacks.depth -= 1
            self._call_on(h, _lib.lib().bb_uds_security_key, level + 1, key, len(key))
            return seed

    def reset(self, kind: int = 0x01) -> bytes:
        """0x11 ECUReset: kind 1 hard, 2 key-off-on, 3 soft; returns the answer after its SID."""
        return self._bytes(_lib.lib().bb_uds_reset, _int("kind", kind))

    def comm_control(self, control: int, comm_type: int = 0x01) -> None:
        """0x28 CommunicationControl: `control` 0..3 for messages of `comm_type` (1: the
        application's own)."""
        self._call(_lib.lib().bb_uds_comm_control, _int("control", control), _int("comm_type", comm_type))

    def dtc_setting(self, on: bool) -> None:
        """0x85 ControlDTCSetting: True on, False off (the ECU records no faults while off)."""
        if not isinstance(on, bool):
            raise TypeError(f"dtc_setting(on): on must be True or False, not {on!r}")
        self._call(_lib.lib().bb_uds_dtc_setting, int(on))

    def clear_dtcs(self, group: int = 0xFFFFFF) -> None:
        """0x14 ClearDiagnosticInformation: one DTC or a group of 24 bits (0xFFFFFF, the default:
        all)."""
        self._call(_lib.lib().bb_uds_clear_dtcs, _int("group", group))

    def _list(self, fn, *args) -> list[Dtc]:
        """A 0x19 02 / 0A answer: the call, then each DTC it held, under one hold of the lock."""
        lib = _lib.lib()
        with self._lock:
            h = self._handle()
            n = self._checked(h, fn(h, *args))
            out = []
            for i in range(n):
                d = _lib.BbDtc()
                _lib.check(lib.bb_uds_dtc(h, i, ctypes.byref(d)))
                out.append(_dtc(d, self._faults))
            return out

    def _checked(self, h: int, rc: int) -> int:
        if rc < 0:
            raise self._enrich(h, _lib.error(rc))
        return rc

    def dtcs(self, mask: int = 0xFF) -> list[Dtc]:
        """0x19 02 ReadDTCInformation: the DTCs with any of `mask`'s status bits (0xFF: any)."""
        return self._list(_lib.lib().bb_uds_dtcs, _int("mask", mask))

    def supported_dtcs(self) -> list[Dtc]:
        """0x19 0A: every DTC the ECU supports, each with its whole status."""
        return self._list(_lib.lib().bb_uds_supported_dtcs)

    def dtc_count(self, mask: int = 0xFF) -> int:
        """0x19 01: how many DTCs have any of `mask`'s status bits."""
        return self._call(_lib.lib().bb_uds_dtc_count, _int("mask", mask), None)

    def snapshot_ids(self) -> list[SnapshotId]:
        """0x19 03: every DTC holding a snapshot, with the snapshot record's number."""
        lib = _lib.lib()
        with self._lock:
            h = self._handle()
            n = self._checked(h, lib.bb_uds_snapshot_ids(h))
            out, code, record = [], ctypes.c_uint32(), ctypes.c_uint8()
            for i in range(n):
                _lib.check(lib.bb_uds_snapshot_id(h, i, ctypes.byref(code), ctypes.byref(record)))
                out.append(SnapshotId(code.value, _lib.string(lib.bb_dtc_name, code.value), record.value,
                                      self._faults.get(code.value)))
            return out

    def snapshot(self, dtc: int | str, record: int = 0xFF) -> Snapshot:
        """0x19 04: DTC `dtc`'s snapshot record `record` (0xFF: every one). `dtc` is its code or
        its name ("P1234-56"). A snapshot DID whose size the client does not know is read once
        (0x22) to learn it; did_size states one that cannot be read."""
        code, rec = _dtc_code(dtc), _int("record", record)
        lib = _lib.lib()
        with self._lock:
            h = self._handle()
            d = _lib.BbDtc()
            n = self._checked(h, lib.bb_uds_snapshot(h, code, rec, ctypes.byref(d)))
            records, number, did = [], ctypes.c_uint8(), ctypes.c_uint16()
            for r in range(n):
                count = _lib.check(lib.bb_uds_snapshot_record(h, r, ctypes.byref(number)))
                dids: dict[int, bytes] = {}
                for k in range(count):
                    value = _lib.bytes_of(lib.bb_uds_snapshot_did, h, r, k, ctypes.byref(did))
                    dids.setdefault(did.value, value)
                records.append(SnapshotRecord(number.value, dids))
            return Snapshot(_dtc(d, self._faults), records)

    def extended(self, dtc: int | str, record: int = 0xFF) -> Extended:
        """0x19 06: DTC `dtc`'s extended data record `record` (0xFF: every one), sized as
        blobly_emb's (ext_record_size states another's)."""
        code, rec = _dtc_code(dtc), _int("record", record)
        lib = _lib.lib()
        with self._lock:
            h = self._handle()
            d, c = _lib.BbDtc(), _lib.BbCounters()
            n = self._checked(h, lib.bb_uds_extended(h, code, rec, ctypes.byref(d), ctypes.byref(c)))
            records, number = {}, ctypes.c_uint8()
            for k in range(n):
                value = _lib.bytes_of(lib.bb_uds_extended_record, h, k, ctypes.byref(number))
                records.setdefault(number.value, value)  # a record listed twice keeps its first
            has = c.has
            return Extended(_dtc(d, self._faults), records, c.occurrences if has & 1 else None, c.aging if has & 2 else None,
                            c.failed_cycles if has & 4 else None)

    def did_size(self, did: int, size: int) -> None:
        """States a snapshot DID's size, for one the client cannot learn by reading it (or whose
        size varies)."""
        did, size = _int("did", did), _int("size", size)
        with self._lock:
            self._call(_lib.lib().bb_uds_did_size, did, size)
            self._did_sizes[did] = size  # kept for the next connection

    def ext_record_size(self, record: int, size: int) -> None:
        """States an extended data record's size (blobly_emb's 0x01..0x03 are known)."""
        record, size = _int("record", record), _int("size", size)
        with self._lock:
            self._call(_lib.lib().bb_uds_ext_record_size, record, size)
            self._ext_sizes[record] = size  # kept for the next connection

    def _state_waits(self, h: int, stated: dict[str, int]) -> None:
        """States the waits `stated` names on handle h, one by one."""
        lib = _lib.lib()
        for name, ms in stated.items():
            self._call_on(h, lib.bb_uds_set_wait, _lib.WAITS[name], ms)

    def _get_timing(self, name: str) -> int:
        t = _lib.BbUdsTiming()
        self._call(_lib.lib().bb_uds_get_timing, ctypes.byref(t))
        return getattr(t, name)

    def _set_timing(self, name: str, ms: int) -> None:
        ms = _int(name, ms)
        with self._lock:
            self._state_waits(self._handle(), {name: ms})
            self._timing[name] = ms  # kept for the next connection

    @property
    def timeout_ms(self) -> int:
        """How long the first answer to a request is waited for (1000; a 0x10 answer's P2 can
        lengthen it). Set: 1 .. 3600000."""
        return self._get_timing("timeout_ms")

    @timeout_ms.setter
    def timeout_ms(self, ms: int) -> None:
        self._set_timing("timeout_ms", ms)

    @property
    def p2_star_ms(self) -> int:
        """The ECU's P2*: after each responsePending (0x78) the next answer is waited for this plus
        margin_ms (5000 until a 0x10 answer names the ECU's, which replaces one set). Set:
        0 .. 3600000."""
        return self._get_timing("p2_star_ms")

    @p2_star_ms.setter
    def p2_star_ms(self, ms: int) -> None:
        self._set_timing("p2_star_ms", ms)

    @property
    def margin_ms(self) -> int:
        """What is added to the P2* wait (1000): P2* bounds an answer's start, and a multi-frame
        answer must also arrive whole. Set: 0 .. 3600000."""
        return self._get_timing("margin_ms")

    @margin_ms.setter
    def margin_ms(self, ms: int) -> None:
        self._set_timing("margin_ms", ms)

    @property
    def pending_budget_ms(self) -> int:
        """The longest one request may take from its send, however often the ECU says
        responsePending (120000). Set: 1 .. 3600000."""
        return self._get_timing("pending_budget_ms")

    @pending_budget_ms.setter
    def pending_budget_ms(self, ms: int) -> None:
        self._set_timing("pending_budget_ms", ms)

    def retarget(self, address: int | None = None) -> None:
        """DoIP: requests go to logical address `address` from now on, and the answers taken are
        its — a node behind the gateway the channel's entity is (ISO 13400-2), on the same
        connection, so what was unlocked on the gateway holds for the node. None goes back to the
        channel's ecu_address; `ecu` follows it. A new connection (a lost one reopened, a stop and
        start) keeps the target but not the gateway's unlock: a gateway that routes only an
        unlocked tester refuses the node's requests (CarrierFailed, a negative acknowledgement)
        until it is unlocked again. Another target is another ECU: the client starts again from the
        waits and sizes the script set, without what it learned of the one before. Refused on a CAN
        channel, and inside a security_access key_fn."""
        a = None if address is None else _int("address", address, 64)
        with self._lock:
            if self._in_key_fn:
                # the key would go to the new target, answering the old one's seed
                raise BloblyError(f"{self!r}: retarget inside a security_access key_fn", _lib.BB_ERR_STATE)
            h = self._handle()
            self._call_on(h, _lib.lib().bb_uds_retarget, None if a is None else ctypes.byref(ctypes.c_int64(a)))
            self._target = a
            self.ecu = self._entity if a is None else a

    def __repr__(self) -> str:
        if self.tester is not None:
            ids = f"DoIP 0x{self.tester:04X} -> 0x{self.ecu:04X}"
        else:
            ids = f"0x{self.tx:X}/0x{self.rx:X}" if self.tx is not None else "unopened"
        state = " closed" if self._closed else ""
        return f"<UdsClient {self.channel.name} {ids}{state}>"


def functional(channel: "Channel", functional_id: int | None, clients: Sequence[UdsClient], request: ByteData,
               window_ms: int = 1000) -> list[FunctionalReply]:
    """`request` once on `channel`'s functional id, each client answering on its own response id;
    on a DoIP channel to the functional logical address (None: 0xE400) on its one client's
    connection (Channel.uds_functional)."""
    doip = channel.kind == "doip"
    fid = None if doip and functional_id is None else _int("functional_id", functional_id, 64)
    window = _int("window_ms", window_ms)
    req = _data("request", request)
    clients = list(clients)
    for c in clients:
        if not isinstance(c, UdsClient):
            raise TypeError(f"uds_functional: {c!r} is not a UdsClient")
    if not clients:
        raise ValueError("uds_functional: no client to answer; a functional request needs one")
    if doip and len(clients) != 1:
        raise ValueError(f"uds_functional: {channel.name} is a DoIP channel, one connection to one entity; "
                         "pass its one UdsClient")
    if len({id(c) for c in clients}) != len(clients):
        raise ValueError("uds_functional: a client is named twice")
    for c in clients:
        if c.channel is not channel:
            raise BloblyError(f"uds_functional: {c!r} is not a client of {channel.name}")
    lib = _lib.lib()
    # inside a key_fn this thread holds that client's lock, whichever client it is, and cannot let
    # it go while waiting for others: waiting for one held elsewhere could wait for ever
    reentered = getattr(_callbacks, "depth", 0) > 0
    held: list[UdsClient] = []
    try:
        # every client's lock, without waiting on one while holding another: a client held across
        # a key_fn that calls another client would otherwise wait on us as we wait on it
        while True:
            for c in clients:
                if not c._lock.acquire(blocking=False):
                    break
                held.append(c)  # only what was acquired is released, an interrupt included
            else:
                break
            for c in reversed(held):
                c._lock.release()
            held.clear()
            if reentered:
                raise BloblyError("uds_functional: called inside a call on one of its clients while "
                                  "another is busy elsewhere; it would wait for ever", _lib.BB_ERR_STATE)
            time.sleep(0.001)
        with _lib.state_lock:
            channel._current()
            if not channel._project.started:
                raise BloblyError(f"{channel.name}: the project is not started", _lib.BB_ERR_STATE)
        for c in clients:
            c._no_seed_in_key_fn(req)
        handles = [c._handle() for c in clients]
        if doip:
            out = _lib.BbFunctionalReply()
            address = None if fid is None else ctypes.byref(ctypes.c_int64(fid))
            clients[0]._call_on(handles[0], lib.bb_uds_functional_doip, address, req, len(req), window,
                                ctypes.byref(out))
            return [_reply(lib, handles[0], out)]
        n = len(handles)
        out = (_lib.BbFunctionalReply * n)()
        _lib.check(lib.bb_uds_functional(channel._index, fid, (ctypes.c_int * n)(*handles), n, req, len(req),
                                         window, out))
        return [_reply(lib, h, out[i]) for i, h in enumerate(handles)]
    finally:
        for c in held:
            c._lock.release()


def _reply(lib, h: int, r) -> FunctionalReply:
    """Handle h's FunctionalReply, from its bb_functional_reply."""
    answer = _lib.bytes_of(lib.bb_uds_data, h) if r.answer_len else b""
    error = _lib.string(lib.bb_uds_reply_error, h)
    outcome = _lib.OUTCOMES.get(r.outcome, f"unknown ({r.outcome})")
    return FunctionalReply(outcome, answer, r.nrc if outcome == "negative" else None, bool(r.pended), error)
