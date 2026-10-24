"""cyclic — frames sent on a period in the background (Channel.send_cyclic, Message.send_cyclic),
while the script does something else: blocks in a UDS request, waits in an expect. Each sender is
one of the run's loops in the engine (blobly/cyclic), on a bus handle of its own that only sends,
so the channel's own handle is never used from a second thread."""
import ctypes
import numbers
from dataclasses import dataclass
from typing import TYPE_CHECKING, Literal, Self

from . import _lib
from ._lib import BloblyError, ByteData

if TYPE_CHECKING:
    from .project import Channel, Message


@dataclass(frozen=True)
class CyclicStatus:
    """A background sender as it is now: `sent` the frames the bus took, `failed` the sends it
    refused (a listen-only row refuses every one) and `error` the last refusal's words ("" when
    none), `period_ms`, and `running` — False once it is stopped or its project is."""
    sent: int
    failed: int
    error: str
    period_ms: int
    running: bool


def _period(period_ms: object) -> int:
    if isinstance(period_ms, bool) or not isinstance(period_ms, int):
        raise TypeError(f"period_ms must be an integer, not {period_ms!r}")
    if not 1 <= period_ms <= 3_600_000:
        raise ValueError(f"a period of {period_ms} ms: give 1 .. 3600000")
    return period_ms


def _signals(who: str, signals: dict[str, float]):
    """The n, names and values of `signals`, as the C arrays bb.h takes."""
    names, values = [], []
    for k, v in signals.items():
        if "\0" in k:
            raise ValueError(f"{who}: a signal name cannot carry a NUL: C would read it cut short")
        if not isinstance(v, numbers.Real) or isinstance(v, bool):
            raise TypeError(f"{who}.{k}: a signal's value is a number, not {v!r}")
        names.append(k.encode())
        values.append(float(v))
    n = len(names)
    return n, (ctypes.c_char_p * max(n, 1))(*names), (ctypes.c_double * max(n, 1))(*values)


class CyclicSender:
    """A frame sent every `period_ms` in the background, the first at once (Channel.send_cyclic,
    Message.send_cyclic). It runs until stop() or until its project stops; `with` stops it at the
    end of the block. update() changes what it sends and `period_ms = ...` its period, each from
    its next frame. A message's declared E2E is stamped on every frame, its counter this sender's own
    from 0. Its frames are heard by the channel's own handle as another node's are — they go out on a
    handle of the sender's — so Channel.load() counts them only as it receives them."""
    channel: "Channel"
    message: "Message | None"

    def __init__(self, channel: "Channel", h: int, message: "Message | None") -> None:
        self.channel, self.message, self._h = channel, message, h
        self._final: CyclicStatus | None = None  # the status it ended with, once its loop is out
        self._seen = CyclicStatus(0, 0, "", 0, True)  # the last status read

    def _live(self) -> int:
        """The handle; Refused once the sender is stopped."""
        if self._final is not None:
            raise _lib.Refused(f"{self!r} is stopped", _lib.BB_ERR)
        return self._h

    def update(self, data: ByteData | None = None, /, **signals: float) -> None:
        """What it sends from its next frame: a raw sender's payload `data`, or a message sender's
        signals at these physical values (the others keep theirs; a name the message does not have
        is refused)."""
        lib = _lib.lib()
        with _lib.state_lock:
            h = self._live()
            if self.message is None:
                if signals or data is None:
                    raise TypeError(f"{self!r}: a raw sender takes the payload's bytes, not signals")
                d = bytes(data)
                _lib.check(lib.bb_cyclic_data(h, d, len(d)))
            else:
                if data is not None:
                    raise TypeError(f"{self!r}: a message sender takes signal values, not bytes")
                n, names, values = _signals(self.message.name, signals)
                _lib.check(lib.bb_cyclic_signals(h, n, names, values))

    @property
    def period_ms(self) -> int:
        """Its period; set it to change the period from the next frame (1 .. 3600000)."""
        return self.status().period_ms

    @period_ms.setter
    def period_ms(self, period_ms: int) -> None:
        ms = _period(period_ms)
        with _lib.state_lock:
            _lib.check(_lib.lib().bb_cyclic_period(self._live(), ms))

    def status(self) -> CyclicStatus:
        """What it has done so far (CyclicStatus); after a stop, what it had done when it ended."""
        with _lib.state_lock:
            if self._final is not None:
                return self._final
            try:
                return self._read(self._h)
            except BloblyError as e:
                if e.code != _lib.BB_ERR_HANDLE:
                    raise
                # let go by a later start, its loop long out: what was last read of it
                return self._ended(self._seen)

    def _read(self, h: int) -> CyclicStatus:
        lib = _lib.lib()
        i = _lib.BbCyclicInfo()
        _lib.check(lib.bb_cyclic_status(h, ctypes.byref(i)))
        self._seen = CyclicStatus(i.sent, i.failed, _lib.string(lib.bb_cyclic_error, h), i.period_ms, bool(i.running))
        return self._seen

    def _ended(self, st: CyclicStatus) -> CyclicStatus:
        """`st` as the sender's final status, its handle let go."""
        self._final = CyclicStatus(st.sent, st.failed, st.error, st.period_ms, False)
        h, self._h = self._h, None
        try:
            _lib.lib().bb_cyclic_free(h)
        except BloblyError:
            pass
        try:
            self.channel._project._senders.remove(self)
        except ValueError:
            pass
        return self._final

    def stop(self) -> bool:
        """Stops it: True once its loop is out, False while it is still inside a send past the
        bound (it sends nothing more; stop() again asks again). Stopping a stopped sender does
        nothing. A sender of a stopped project is out already."""
        with _lib.state_lock:
            if self._final is not None:
                return True
            lib = _lib.lib()
            rc = lib.bb_cyclic_stop(self._h)
            if rc == _lib.BB_ERR_HANDLE:  # let go by a later start
                self._ended(self._seen)
                return True
            if _lib.check(rc) == _lib.BB_RELEASING:
                return False
            self._ended(self._read(self._h))  # read once the loop is out: its last frame counted
            return True

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc: object) -> Literal[False]:
        self.stop()
        return False

    def __repr__(self) -> str:
        what = self.message.name if self.message is not None else "frame"
        return f"<CyclicSender {what} on {self.channel.name}>"


def _start_raw(channel: "Channel", f: "_lib.BbFrame", period_ms: int) -> CyclicSender:
    """A raw sender of bb_frame `f` on `channel` (Channel.send_cyclic), under _lib.state_lock."""
    lib = _lib.lib()
    channel._current()
    if not channel._project.started:
        raise BloblyError(f"{channel.name}: the project is not started", _lib.BB_ERR_STATE)
    h = _lib.check(lib.bb_cyclic_start(channel._index, ctypes.byref(f), period_ms))
    s = CyclicSender(channel, h, None)
    channel._project._senders.append(s)
    return s


def _start_message(message: "Message", period_ms: int, e2e: bool, signals: dict[str, float]) -> CyclicSender:
    """A sender of `message` (Message.send_cyclic), under _lib.state_lock."""
    lib = _lib.lib()
    channel = message.channel
    n, names, values = _signals(message.name, signals)
    message._live()
    h = _lib.check(lib.bb_cyclic_start_message(channel._index, message._index, n, names, values,
                                               int(bool(e2e)), period_ms))
    s = CyclicSender(channel, h, message)
    channel._project._senders.append(s)
    return s
