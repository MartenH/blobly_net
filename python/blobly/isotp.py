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
from .uds import _CAP, _ISOTP_DEFAULT, _close_orphans, _data, _int, _isotp_settings, _orphans

if TYPE_CHECKING:
    from .project import Channel, FrameFormat


class IsoTp:
    """A raw ISO-TP channel on a CAN channel (Channel.isotp): messages of 1 .. 4095 bytes sent on CAN
    id `tx` and received on `rx`, 29-bit when `ext` (either id past 0x7FF), sent in 8-byte frames
    (FD on a row the project declares CAN-FD) unless `tx_dl` says longer, and received in frames of
    any length a sender chose: a CAN-FD peer's Single Frame of up to 62 bytes, or its First Frame of
    up to 64 and Consecutive Frames as long.
    As a sender it honours the receiver's Flow Control; as a receiver it asks for no pacing.

    ch.isotp's `padding` is the byte frames are padded to 8 bytes with (0x00), None for frames as
    long as their content; `block_size` (0 .. 255) and `stmin_ms` (a whole 0 .. 127, or 0.1 .. 0.9
    for 100 .. 900 µs) are the Flow Control it answers a First Frame with as a receiver, 0 and 0
    asking for no pacing; above 0 it sends the next Flow Control after each block. Out of range is
    refused before the channel opens; what was asked holds on every handle it opens.
    `tx_dl` (8, 12, 16, 20, 24, 32, 48 or 64) is the length of the frames it sends in: above 8 a
    Single Frame carries up to tx_dl - 2 bytes, a Consecutive Frame tx_dl - 1, and a frame is padded
    up to the next CAN-FD length; refused on a classic row unless `format` states FD. `format`
    ("classic", "fd" or "fd_brs"; None the row's declared format) is stated on every frame it sends,
    a classic one refused with a tx_dl above 8.

    send() returns once the message is on the wire; a long one waits for the receiver's Flow Control
    (1000 ms each, N_Bs; 120 s in all) and raises Timeout when none came. recv() returns the next
    whole message, or None when none came in time: a transfer begun is kept and the next recv goes
    on with it, until 1000 ms pass with no Consecutive Frame (N_Cr: CarrierFailed). A message the
    channel cannot carry, or a send on a listen-only row, is Refused; the bus or the transfer failing
    (a frame lost, a frame that is not ISO-TP, the receiver's overflow) is CarrierFailed.

    `with ch.isotp(tx, rx) as tp:` closes it at the end of the block. A stop and a start of the
    project let its handle go and the next call opens another on the same ids. Calls on one channel
    are serialised, so threads may share it, a send waiting for a receive in progress (one ISO-TP
    channel cannot do both at once); close() from another thread ends a call in progress there
    within 20 ms. Open one per id pair: two on one rx (a UdsClient on it included) each answer
    a First Frame with a Flow Control of their own."""
    channel: "Channel"
    tx: int
    rx: int
    ext: bool

    def __init__(self, channel: "Channel", tx: int, rx: int, *, padding: int | None = 0, block_size: int = 0,
                 stmin_ms: float = 0, tx_dl: int = 8, format: "FrameFormat | None" = None) -> None:
        self.channel = channel
        self._ask = (_int("tx", tx, 64), _int("rx", rx, 64))
        self._settings = _isotp_settings(padding, block_size, stmin_ms, tx_dl, format)  # stated on each handle
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
        if self._settings != _ISOTP_DEFAULT:
            try:
                _lib.check(lib.bb_isotp_set_settings(self._h, *self._settings))
            except BloblyError:
                self._let_go()
                raise

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
