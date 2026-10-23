"""isotp — a raw ISO-TP (ISO 15765-2) channel on a CAN channel, through libblobly: whole messages on a
request / response id pair, segmented and reassembled by the engine's ISO-TP (the one a UdsClient
rides), with no UDS on top — a protocol of your own over ISO-TP, or a malformed UDS request and the
bytes that come back."""
import ctypes
import threading
from typing import TYPE_CHECKING, Literal

from . import _lib
from ._lib import BloblyError, ByteData
from .doip import _ms
from .events import _sliced
from .uds import _CAP, _close_orphans, _data, _int, _orphans

if TYPE_CHECKING:
    from .project import Channel


class IsoTp:
    """A raw ISO-TP channel on a CAN channel (Channel.isotp): messages of 1 .. 4095 bytes sent on CAN
    id `tx` and received on `rx`, 29-bit when `ext` (either id past 0x7FF), in 8-byte frames (sent FD
    on a row the project declares CAN-FD).
    As a sender it honours the receiver's Flow Control; as a receiver it asks for no pacing.

    send() returns once the message is on the wire; a long one waits for the receiver's Flow Control
    (1000 ms each, N_Bs; 120 s in all) and raises Timeout when none came. recv() returns the next
    whole message, or None when none came in time: a transfer begun is kept and the next recv goes
    on with it, until 1000 ms pass with no Consecutive Frame (N_Cr: CarrierFailed). A message the
    channel cannot carry, or a send on a listen-only row, is Refused; the bus or the transfer failing
    (a frame lost, a frame that is not ISO-TP, the receiver's overflow) is CarrierFailed.

    `with ch.isotp(tx, rx) as tp:` closes it at the end of the block. A stop and a start of the
    project let its handle go and the next call opens another on the same ids. Calls on one channel
    are serialised, so threads may share it; close() from another thread ends a call in progress
    there within 20 ms. Open one per id pair: two on one rx (a UdsClient on it included) each answer
    a First Frame with a Flow Control of their own."""
    channel: "Channel"
    tx: int
    rx: int
    ext: bool

    def __init__(self, channel: "Channel", tx: int, rx: int) -> None:
        self.channel = channel
        self._ask = (_int("tx", tx, 64), _int("rx", rx, 64))
        self.tx, self.rx = self._ask
        self.ext = False
        self._h = None
        self._closed = False
        self._lock = threading.RLock()
        with _lib.state_lock:
            self._open()

    def _open(self):
        """Opens the handle (under _lib.state_lock)."""
        lib = _lib.lib()
        _close_orphans()
        self.channel._current()
        if not self.channel._project.started:
            raise BloblyError(f"{self.channel.name}: the project is not started", _lib.BB_ERR_STATE)
        out = _lib.BbUdsTarget()
        self._h = _lib.check(lib.bb_isotp_open(self.channel._index, self._ask[0], self._ask[1], ctypes.byref(out)))
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
        """Closes the handle, keeping the channel: its next call opens another (a stop)."""
        h, self._h = self._h, None
        if h is not None:
            try:
                _lib.check(_lib.lib().bb_isotp_close(h))
            except BloblyError:
                pass  # already gone

    def close(self) -> None:
        """Lets the handle go for good: a later call refuses."""
        with _lib.state_lock:
            _close_orphans()
            self._closed = True
            self._let_go()
            self.channel._uds.discard(self)

    def __enter__(self) -> "IsoTp":
        return self

    def __exit__(self, *exc: object) -> Literal[False]:
        self.close()
        return False

    def __del__(self) -> None:
        # let go at the next call that opens or closes a handle (uds._orphans): nothing is called
        # into here, since this may run between another call and its error
        try:
            if self._h is not None:
                _orphans.append(("bb_isotp_close", self._h))
        except Exception:
            pass

    def send(self, data: ByteData) -> None:
        """Sends `data`, one whole message (1 .. 4095 bytes), and returns once it is on the wire."""
        d = _data("data", data)
        with self._lock:
            _lib.check(_lib.lib().bb_isotp_send(self._handle(), d, len(d)))

    def recv(self, timeout_ms: float = 1000) -> bytes | None:
        """The next whole message on `rx`, waiting at most timeout_ms (0 only looks); None when none
        came. Ctrl-C ends the wait within 100 ms."""
        wait = _ms("recv", timeout_ms)
        lib = _lib.lib()
        buf = ctypes.create_string_buffer(_CAP)
        with self._lock:
            h = self._handle()  # one handle for the whole wait: a close or stop meanwhile ends it

            def part(ms):
                rc = lib.bb_isotp_recv(h, ms, buf, _CAP)
                if rc == _lib.BB_ERR_TIMEOUT:
                    return None
                n = _lib.check(rc)
                return buf.raw[:n] if n <= _CAP else _lib.bytes_of(lib.bb_isotp_data, h)
            return _sliced(part, wait)

    def __repr__(self) -> str:
        state = " closed" if self._closed else ""
        return f"<IsoTp {self.channel.name} 0x{self.tx:X}/0x{self.rx:X}{state}>"
