"""j1939 — SAE J1939 on a CAN channel, through libblobly (blobly/j1939): multi-packet messages
rejoined from the transport protocol (BAM and RTS/CTS), their faults, and the address directory,
read from the frames the channel's own handle reads (Channel.j1939). A listener: it sends nothing,
no CTS, no acknowledgement, no address claim."""
import collections
import ctypes
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from . import _lib
from ._lib import Timeout

if TYPE_CHECKING:
    from .project import Channel, Message


@dataclass(frozen=True)
class J1939Message:
    """A multi-packet parameter group, rejoined: `pgn`, its sender `sa`, its destination `da` (0xFF
    for a BAM), the announcement's `priority`, `bam` (False: an RTS/CTS connection), `data` exactly
    the announced size. `message` and `signals` are its decode through the channel's databases: the
    message defined at exactly that PGN and source address, else by PGN alone, and {signal: physical
    value} for each signal it carries; None and {} where nothing defines the group, or where
    definitions disagree about its layout — then `note` says why. `t_ms` is when its last packet
    was read and `t_start_ms` its announcement, on the host's monotonic clock (blobly.now_ms)."""
    pgn: int
    sa: int
    da: int
    priority: int
    bam: bool
    data: bytes
    message: "Message | None"
    signals: dict[str, float] = field(default_factory=dict)
    note: str = ""
    t_ms: float = 0.0
    t_start_ms: float = 0.0

    @property
    def packets(self) -> int:
        """How many data frames carried it."""
        return (len(self.data) + 6) // 7


@dataclass(frozen=True)
class J1939Fault:
    """A transfer that did not go to plan: `kind` is "orphan" (a data frame with no transfer to
    belong to), "sequence" (a packet dropped or repeated: the transfer abandoned), "restarted",
    "aborted" (a Connection Abort; the reason in `detail`), "timeout" (nothing within T1 750 ms for a
    BAM, T3 1250 ms for a connection), "malformed" (a control frame J1939-21 does not permit),
    "overflow", "padding" or "off_spec" (said, the message kept), or "truncated". `pgn` is the
    group the transfer announced, None where nothing was announced. `text` (and str()) is the
    whole fault in words, the line the GUI's Log writes."""
    kind: str
    sa: int
    da: int
    pgn: int | None
    detail: str
    text: str = ""

    def __str__(self) -> str:
        return self.text


@dataclass(frozen=True)
class J1939Name:
    """A 64-bit J1939 NAME taken apart (J1939-81): `raw` as claimed, and its fields. `function_name`
    names the 32 global functions (0 "Engine" .. 31), None for any other."""
    raw: int
    identity: int
    manufacturer: int
    ecu_instance: int
    function_instance: int
    function: int
    function_name: str | None
    vehicle_system: int
    vehicle_system_instance: int
    industry_group: int
    arbitrary_address_capable: bool


@dataclass(frozen=True)
class J1939Address:
    """A source address and the NAME holding it, and `t_ms` when that claim was read (blobly.now_ms)."""
    sa: int
    name: J1939Name
    t_ms: float


_QUEUE = 1024  # a listener's queues, bb.h's (j1939.listener_queue)
_names: dict[int, str | None] = {}


def _function_name(function):
    if function not in _names:
        name = _lib.string(_lib.lib().bb_j1939_function_name, function)
        _names[function] = name or None
    return _names[function]


def _int(who, what, v, top):
    if isinstance(v, bool) or not isinstance(v, int):
        raise TypeError(f"{who}: {what} is an int, not {v!r}")
    if not 0 <= v <= top:
        raise ValueError(f"{who}: {what} is 0..0x{top:X}, not 0x{v:X}" if v >= 0 else f"{who}: {what} is 0..0x{top:X}, not {v}")
    return v


class J1939Listener:
    """The J1939 reading of a channel's frames (Channel.j1939): every frame its handle reads — by
    recv, expect, the event loop or the waits here — goes through it, so a frame is consumed once
    and what the channel sends is never in it. Completed messages and faults wait until taken (1024
    of each; past that the oldest is dropped, `dropped` counts them). From the thread that uses the
    channel. A stop and a start of the project, or the channel's close, begin a new reading."""
    channel: "Channel"

    def __init__(self, channel: "Channel") -> None:
        self.channel = channel
        # the faults taken from the handle and not yet from faults(), as bounded as the engine's
        self._faults: collections.deque[J1939Fault] = collections.deque(maxlen=_QUEUE)
        self._lost = 0
        self._h = None

    def _handle(self):
        """The channel's handle, listening; what was kept of another handle's reading let go."""
        h = self.channel._handle()
        if h != self._h:
            _lib.check(_lib.lib().bb_j1939_attach(h, self.channel._index, 1))
            self._faults.clear()
            self._lost = 0
            self._h = h
        return h

    def _pull_faults(self, h):
        lib = _lib.lib()
        f = _lib.BbJ1939Fault()
        while _lib.check(lib.bb_j1939_take_fault(h, ctypes.byref(f))) != _lib.BB_NONE:
            if len(self._faults) == self._faults.maxlen:
                self._lost += 1  # the oldest goes, as in the engine
            self._faults.append(J1939Fault(_lib.J1939_FAULTS.get(f.kind, f"unknown ({f.kind})"), f.sa, f.da,
                                           f.pgn if f.announced else None, _lib.text(f.detail), _lib.text(f.text)))

    def _take(self, h, run, match):
        """The completed messages the handle's listener holds, oldest first and decoded: every one,
        or with `match` up to the first it matches, the rest left queued."""
        lib = _lib.lib()
        out = []
        m = _lib.BbJ1939Message()
        with _lib.state_lock:
            self.channel._same_run(run)
            msgs = self.channel.messages
            values, active, _ = msgs._decoded  # the lock is held: one decode at a time uses them
            while _lib.check(lib.bb_j1939_take_message(h, ctypes.byref(m), values, active,
                                                        msgs._most)) != _lib.BB_NONE:
                msg = msgs[m.message] if m.message >= 0 else None
                sigs = {} if msg is None else {s.name: values[i] for i, s in enumerate(msg.signals) if active[i]}
                out.append(J1939Message(m.pgn, m.sa, m.da, m.priority, bool(m.bam), bytes(m.data[:m.len]), msg,
                                        sigs, _lib.text(m.note), _lib.ms_of(m.t_end_ns),
                                        _lib.ms_of(m.t_start_ns)))
                if match is not None and match(out[-1]):
                    break
        self._pull_faults(h)
        return out

    def _until(self, who, timeout_ms, match):
        """Reads the channel until a message is taken (with `match`, one it matches) or timeout_ms
        has passed (one deadline, as Channel.expect's): what it took, in order — with `match` only
        the one it matched, the others counted by (pgn, sa) — and those counts."""
        from .project import _deadline
        deadline = _deadline(who, timeout_ms)
        with _lib.state_lock:
            run = _lib.state["run"]
            h = self._handle()
        others = collections.Counter()

        def sift(new):  # the match, or every message without one; the others counted, not kept
            if match is None:
                return new
            for m in new:
                if match(m):
                    return [m]
                others[(m.pgn, m.sa)] += 1
            return []
        got = sift(self._take(h, run, match))
        if got:
            return got, others
        for _ in self.channel._frames_until(deadline, run):
            got = sift(self._take(h, run, match))
            if got:
                return got, others
        return sift(self._take(h, run, match)), others

    def messages(self, timeout_ms: float = 0) -> list[J1939Message]:
        """Every completed message waiting, oldest first; when none waits, the channel is read until
        one completes or timeout_ms has passed ([] then). 0 takes what is complete, after one look."""
        return self._until("messages", timeout_ms, None)[0]

    def expect_pgn(self, pgn: int, timeout_ms: float = 1000, *, sa: int | None = None) -> J1939Message:
        """The first completed message of parameter group `pgn` (from source address `sa`, when
        given), waited for at most timeout_ms in all; blobly.Timeout when none came, its message
        saying what came instead and the transfer faults seen. Messages of other groups ahead of it
        are consumed, as Channel.expect consumes other frames, and those after it stay queued;
        faults stay for faults()."""
        __tracebackhide__ = True  # a pytest failure points at the test's line, not this one
        _int("expect_pgn", "a PGN", pgn, 0x3FFFF)
        if (pgn >> 8) & 0xFF < 0xF0 and pgn & 0xFF:
            raise ValueError(f"expect_pgn: 0x{pgn:04X} is a PDU1 group, whose PGN has a zero low byte "
                             f"(the destination is not part of it): 0x{pgn & 0x3FF00:04X}")
        if sa is not None:
            _int("expect_pgn", "a source address", sa, 0xFD)  # 0xFE and 0xFF send no transfer

        def match(m):
            return m.pgn == pgn and (sa is None or m.sa == sa)
        got, others = self._until("expect_pgn", timeout_ms, match)
        if got:
            return got[0]
        want = f"PGN 0x{pgn:04X}" + (f" from SA 0x{sa:02X}" if sa is not None else "")
        came = ", ".join(f"PGN 0x{p:04X} from SA 0x{s:02X}" + (f" (x{n})" if n > 1 else "")
                         for (p, s), n in others.most_common(5)) or "no multi-packet message came"
        text = f"{self.channel.name}: expected a J1939 {want} within {timeout_ms:g} ms; {came}"
        if self._faults:
            text += f"; {len(self._faults)} transfer fault{'s' if len(self._faults) > 1 else ''}, the last: {self._faults[-1]}"
        raise Timeout(text, _lib.BB_ERR_TIMEOUT)

    def faults(self) -> list[J1939Fault]:
        """The transfer faults seen since the last call, oldest first. It reads nothing: a fault is
        found as the frames are read (a timeout, once a read finds nothing queued)."""
        with _lib.state_lock:
            h = self._handle()
        self._pull_faults(h)
        out = list(self._faults)
        self._faults.clear()
        return out

    def addresses(self, window_ms: float = 0) -> list[J1939Address]:
        """Who holds which source address, by address, from the Address Claimed frames read: a
        contested address held by the lower NAME, a Cannot Claim releasing it. With window_ms the
        channel is read for that long first (every frame consumed); 0 reads nothing. Nodes claim
        at power-up, and this listener sends no Request for Address Claimed."""
        from .project import _deadline
        lib = _lib.lib()
        if window_ms:
            deadline = _deadline("addresses", window_ms)
            with _lib.state_lock:
                run = _lib.state["run"]
                self._handle()
            for _ in self.channel._frames_until(deadline, run):
                pass
        with _lib.state_lock:
            if window_ms:
                self.channel._same_run(run)  # the window's reading, not the next run's
            h = self._handle()
        out = []
        a = _lib.BbJ1939Address()
        for k in range(_lib.check(lib.bb_j1939_address_count(h))):
            _lib.check(lib.bb_j1939_address_info(h, k, ctypes.byref(a)))
            name = J1939Name(a.name, a.identity, a.manufacturer, a.ecu_instance, a.function_instance, a.function,
                             _function_name(a.function), a.vehicle_system, a.vehicle_system_instance,
                             a.industry_group, bool(a.arbitrary_address_capable))
            out.append(J1939Address(a.sa, name, _lib.ms_of(a.t_ns)))
        return out

    @property
    def dropped(self) -> int:
        """Messages and faults dropped untaken since the reading began, the queue being full."""
        with _lib.state_lock:
            h = self._handle()
        return _lib.check(_lib.lib().bb_j1939_dropped(h)) + self._lost

    def __repr__(self) -> str:
        return f"<J1939Listener {self.channel.name}>"

