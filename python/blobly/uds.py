"""uds — UDS (ISO 14229) diagnostics on a CAN channel, through libblobly: a client over ISO-TP on
the channel's bus, opened by the rule the Lua uds.open opens by, each call one of the engine's
helpers. Answers come back decoded and failures typed, so nothing here reads a UDS payload."""
import ctypes
import threading
from dataclasses import dataclass
from collections.abc import Callable

from . import _lib
from ._lib import BloblyError, NegativeResponse

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


def _int(name: str, v: object, bits: int = 32) -> int:
    """An integer argument, refused before ctypes would wrap it: its range is the engine's to
    refuse (a byte, a DID, 24 bits), but past the C type it would arrive as another number."""
    if isinstance(v, bool) or not isinstance(v, int):
        raise TypeError(f"{name} must be an integer, not {v!r}")
    if not -(1 << (bits - 1)) <= v < 1 << (bits - 1):
        raise ValueError(f"{name} {v} is past what a {bits}-bit C integer holds")
    return v


def _data(name: str, v: object) -> bytes:
    """A byte-string argument: bytes, bytearray, memoryview, or a sequence of byte values."""
    if isinstance(v, (str, int)):
        raise TypeError(f"{name} must be bytes, not {type(v).__name__}")
    try:
        return bytes(v)
    except (TypeError, ValueError) as e:
        raise TypeError(f"{name} must be bytes: {e}") from None


def _put(fn, *args) -> bytes:
    """The bytes a library call copies into a buffer (bb.h: one past cap is fetched whole again
    with bb_uds_data's handle, args[0]). Raises the call's error."""
    lib = _lib.lib()
    buf = ctypes.create_string_buffer(_CAP)
    n = _lib.check(fn(*args, buf, _CAP))
    if n <= _CAP:
        return buf.raw[:n]
    whole = ctypes.create_string_buffer(n)
    _lib.check(lib.bb_uds_data(args[0], whole, n))
    return whole.raw[:n]


# handles of clients collected without close(), let go at the next call that opens or closes one:
# a finalizer may run between a failed call and the read of its error, and a close there would
# replace the thread's error text and NRC
_orphans: list[int] = []


def _close_orphans() -> None:
    """Closes the collected clients' handles (under _lib.state_lock)."""
    lib = _lib.lib()
    while _orphans:
        lib.bb_uds_close(_orphans.pop())


def reference_key(seed: bytes) -> bytes:
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
    """A UDS client on a CAN channel (Channel.uds): requests out on `tx`, answers back on `rx`,
    29-bit when `ext`. Every call is bounded by the engine's timing — the first answer within
    1000 ms (a 0x10 answer's P2 can lengthen that), each responsePending (0x78) then waited for the
    ECU's P2* + 1000 ms, one request never longer than 120 s — and fails with a typed error:
    NegativeResponse (with its NRC), Timeout, PendingExpired, UndecodableAnswer, CarrierFailed, or
    Refused when nothing was asked of the ECU.

    `with ch.uds() as diag:` closes it at the end of the block. A stop and a start of the project
    let its connection go and the next call opens another on the same ids; a client of a channel
    a reload did not keep refuses. Calls on one client are serialised, so threads may share it;
    close() from another thread ends a call in progress there."""

    def __init__(self, channel, tx: int | None = None, rx: int | None = None):
        self.channel = channel
        self._ask = (None if tx is None else _int("tx", tx, 64), None if rx is None else _int("rx", rx, 64))
        self.tx = self.rx = None
        self.ext = False
        self._h = None
        self._closed = False
        self._lock = threading.RLock()  # re-entered: security_access holds it across two calls
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
        self._h = _lib.check(lib.bb_uds_open(self.channel._index, ids[0], ids[1], ctypes.byref(out)))
        self.tx, self.rx, self.ext = out.tx, out.rx, bool(out.ext)
        self.channel._uds.add(self)

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

    def __enter__(self) -> "UdsClient":
        return self

    def __exit__(self, *exc) -> bool:
        self.close()
        return False

    def __del__(self):
        # an unclosed client lets its bus subscription go with it, at the next call (_orphans):
        # nothing is called into here, since this may run between another call and its error
        try:
            if self._h is not None:
                _orphans.append(self._h)
        except Exception:
            pass

    def _enrich(self, h: int, e: BloblyError) -> BloblyError:
        """A negative response given its code (the thread's, so a close since cannot take it) and
        the exchange it ended, read from handle h (None when the handle was closed since)."""
        if isinstance(e, NegativeResponse):
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
        except NegativeResponse as e:
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
        None before the first (and after a stop let the connection go)."""
        with self._lock, _lib.state_lock:  # a stop on another thread cannot close it under the read
            return None if self._h is None else self._last(self._h)

    def raw(self, request: bytes) -> bytes:
        """Sends `request` and returns the positive answer, its SID included. An answer that names
        another request (a late or repeated one) is skipped and the wait goes on."""
        r = _data("request", request)
        return self._bytes(_lib.lib().bb_uds_raw, r, len(r))

    def raw_suppressed(self, request: bytes) -> bool:
        """Sends `request` with suppress-positive-response set on its sub-function: silence is
        success, a refusal raises. Returns whether a positive answer came anyway (the ECU ignored
        the bit); one owed after responsePending is waited for and does not count."""
        r = _data("request", request)
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

    def write_did(self, did: int, data: bytes) -> None:
        """0x2E WriteDataByIdentifier."""
        d = _data("data", data)
        self._call(_lib.lib().bb_uds_write_did, _int("did", did), d, len(d))

    def security_access(self, level: int, key_fn: Callable[[bytes], bytes] | None = None) -> bytes:
        """0x27 SecurityAccess: requests the seed for `level` (odd), computes the key with
        `key_fn(seed)` — blobly_net's reference key when None — and sends it at level + 1. Returns
        the seed. An all-zero seed is ISO 14229-1's "already unlocked": no key is sent. A wrong key
        raises NegativeResponse (NRC 0x35)."""
        level = _int("level", level)
        unlocked = ctypes.c_uint8()
        # seed, key and the call between them as one, on one connection: no other call takes the
        # seed, and a stop meanwhile fails the key rather than send it on a connection of its own
        with self._lock:
            h = self._handle()
            seed = self._bytes_on(h, _lib.lib().bb_uds_security_seed, level, ctypes.byref(unlocked))
            if unlocked.value:
                return seed
            key = _data("the key key_fn returned", key_fn(seed)) if key_fn is not None else reference_key(seed)
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

    def __repr__(self) -> str:
        ids = f"0x{self.tx:X}/0x{self.rx:X}" if self.tx is not None else "unopened"
        state = " closed" if self._closed else ""
        return f"<UdsClient {self.channel.name} {ids}{state}>"
