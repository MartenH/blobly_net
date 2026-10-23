"""project — a .blobnet project brought up in this process through libblobly (blobly.headless),
its enabled channels as objects that complete in a REPL, and the event loop over them."""
import collections
import ctypes
import math
import numbers
import os
import sys
import warnings
import weakref
from collections.abc import Callable, Iterator, Sequence
from typing import TYPE_CHECKING, Generic, Literal, Protocol, Self, TypeVar

from . import _lib
from ._lib import BloblyError, ByteData, Timeout
from .events import SLICE_MS, EventLoop, _finite, _sliced, monotonic_ms, sleep_ms, wait_on
from .doip import DoipAnnouncement, discover
from .uds import FunctionalReply, UdsClient, _close_orphans, functional
from .faults import Faults
from .metrics import BusDiagnostics, BusLoad, diagnostics_of, load_of
from .generators import Generators, listed as _listed_generators

if TYPE_CHECKING:
    from .nodes import Nodes


class Frame:
    """A CAN frame. `data` is the payload; `length` its length, or for a remote frame (`rtr`, no
    payload) the length it asks for; `fd`/`brs` CAN-FD and its bit-rate switch; `esi` CAN-FD's
    error-state indicator. `t_ms` is when a received frame arrived, in ms on the host's monotonic
    clock (`blobly.now_ms()`), the time the GUI's trace gives it: its receive stamp where the
    backend reads one, else its receipt. None on a frame not received. A value: equal frames hash
    alike, and none is changed once made; `t_ms` is not part of the value, so a received frame
    equals the frame built from its content."""
    __slots__ = ("id", "data", "length", "ext", "fd", "brs", "rtr", "esi", "t_ms")
    id: int
    data: bytes
    length: int
    ext: bool
    fd: bool
    brs: bool
    rtr: bool
    esi: bool
    t_ms: float | None

    def __init__(self, id: int, data: ByteData = b"", ext: bool = False, fd: bool = False,
                 brs: bool = False, rtr: bool = False, esi: bool = False, length: int | None = None,
                 t_ms: float | None = None) -> None:
        data = bytes(data)
        _fill(self, (id, data, len(data) if length is None else length, ext, fd, brs, rtr, esi, t_ms))

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError(f"a Frame is a value: make another rather than set {name}")

    def __delattr__(self, name: str) -> None:
        raise AttributeError(f"a Frame is a value: {name} cannot be deleted")

    def __setstate__(self, state: object) -> None:
        """copy and pickle restore a frame's slots (a subclass's too) past __setattr__."""
        attrs, slots = state if isinstance(state, tuple) else (state, None)
        object.__setattr__(self, "t_ms", None)  # a frame pickled before frames carried a time
        for k, v in {**(attrs or {}), **(slots or {})}.items():
            object.__setattr__(self, k, v)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Frame) and self._key() == other._key()

    def __hash__(self) -> int:
        return hash(self._key())

    def _key(self):
        return tuple(getattr(self, k) for k in _IDENTITY)

    def __repr__(self) -> str:
        flags = "".join(f" {k}" for k in ("ext", "fd", "brs", "rtr", "esi") if getattr(self, k))
        return f"Frame(0x{self.id:X} [{self.data.hex(' ').upper()}]{flags})"


# what a frame is: every field but when it was received
_IDENTITY = ("id", "data", "length", "ext", "fd", "brs", "rtr", "esi")


def _fill(frame, fields):
    for k, v in zip(Frame.__slots__, fields):
        object.__setattr__(frame, k, v)


def frame_of(f: _lib.BbFrame, received: bool = False) -> Frame:
    """A Frame from a bb_frame: a remote frame's len is the length it asks for, with no payload;
    a received one carries its t_ns as t_ms."""
    data = b"" if f.rtr else bytes(f.data[:f.len])
    return Frame(f.id, data, bool(f.ext), bool(f.fd), bool(f.brs), bool(f.rtr), bool(f.esi), f.len,
                 _lib.ms_of(f.t_ns) if received else None)


def _bb_frame(who, id, data, ext=False, fd=False, brs=False, rtr=False):
    """A bb_frame from a frame's parts, refusing what no CAN frame is."""
    if isinstance(id, bool) or not isinstance(id, int) or not 0 <= id <= 0x1FFF_FFFF:
        raise ValueError(f"{who}: a CAN id is an integer of at most 29 bits, not {id!r}")
    data = bytes(data)
    if len(data) > 64:
        raise ValueError(f"{who}: {len(data)} bytes is more than a CAN-FD frame carries")
    f = _lib.BbFrame(id=id, len=len(data), ext=int(bool(ext)), fd=int(bool(fd)), brs=int(bool(brs)),
                     rtr=int(bool(rtr)))
    ctypes.memmove(f.data, data, len(data))
    return f


def _s(n):
    return "" if n == 1 else "s"


def _num(x):
    """A number as a person writes it: 300, 0.5, 1000000."""
    return str(int(x)) if float(x).is_integer() else repr(x)


def _id_text(id, ext):
    return f"0x{id:X}" + (" (29-bit)" if ext else "")


def _came(others, id):
    """What an expectation read instead: each id and kind with its count, the expected id's other
    kind first (the likeliest mistake), then the commonest."""
    n = sum(others.values())
    if not n:
        return "no other frame came"
    shown = sorted(others.items(), key=lambda kc: (kc[0][0] != id, -kc[1]))
    text = ", ".join(f"{c} of {_id_text(*k)}" for k, c in shown[:8])
    return f"{n} other frame{_s(n)} came: {text}" + (", ..." if len(shown) > 8 else "")


def _deadline(who, timeout_ms):
    """When an expectation's wait ends (monotonic_ms): timeout_ms from now, a finite number."""
    if not _finite(timeout_ms):
        raise TypeError(f"{who}: timeout_ms must be a finite number of milliseconds; an "
                        "expectation always ends")
    return monotonic_ms() + max(0, timeout_ms)


def _ms(timeout_ms):
    """A timeout as bb_bus_recv takes it: whole milliseconds rounded DOWN (a receive waits at most
    what was asked), None for forever."""
    if timeout_ms is None:
        return -1
    if not _finite(timeout_ms):
        raise TypeError("timeout_ms must be a finite number of milliseconds, or None")
    ms = max(0, math.floor(timeout_ms))
    if ms > 2**31 - 1:  # a C int: wider would wrap to 'forever' or to 0
        raise ValueError(f"timeout_ms {timeout_ms} is longer than one wait can be (2**31 - 1 ms); use None to wait for ever")
    return ms


class Channel:
    """One enabled row of the project. Its bus handle is opened on first use and is the one send,
    recv, health and the event loop all use, so what this channel sends is never heard back. It
    belongs to its project: after another project's load it refuses, rather than reach whatever
    row now has its index, and a reload of its own project keeps it if its row is still there.
    Native state calls (open, close) run under _lib.state_lock, so threads may share a project."""
    name: str

    def __init__(self, project: "Project", index: int, name: str, gen: int) -> None:
        self._project, self._index, self.name, self._gen = project, index, name, gen
        self._h = None
        self._messages, self._messages_run = None, None
        self._uds = weakref.WeakSet()  # the UDS clients on this row, let go with its handle

    def _current(self):
        st = _lib.state
        if st["owner"] is not self._project or st["gen"] != self._gen:
            raise BloblyError(f"{self.name}: a channel of an earlier load of its project; take it "
                              "from net.channels again", _lib.BB_ERR_STATE)

    @property
    def iface(self) -> str:
        """What the row opens: after start, as the run has it (a hosted DoIP row moves onto a port
        this process could bind)."""
        lib = _lib.lib()
        with _lib.state_lock:
            self._current()
            return _lib.text(lib.bb_channel_iface(self._index))

    @property
    def kind(self) -> str:
        """"can", "doip" or "someip": only a CAN row has frames to send and receive."""
        lib = _lib.lib()
        with _lib.state_lock:
            self._current()
            k = _lib.check(lib.bb_channel_kind(self._index))
        return _lib.KINDS.get(k, f"unknown ({k})")  # a newer library's kind is not a CAN bus

    def _health_needs_reader(self):
        """Whether this row's ladder moves only while it is read (SocketCAN, Vector)."""
        lib = _lib.lib()
        with _lib.state_lock:
            self._current()
            src = _lib.check(lib.bb_channel_health_source(self._index))
        return src == _lib.BB_HEALTH_SOURCE_NEEDS_READER

    def _handle(self):
        h = self._h
        if h is not None:
            return h
        lib = _lib.lib()
        with _lib.state_lock:
            if self._h is None:
                self._current()
                if not self._project.started:
                    raise BloblyError(f"{self.name}: the project is not started", _lib.BB_ERR_STATE)
                # the library's own bytes: what it named, not a re-encoding of it
                self._h = _lib.check(lib.bb_bus_open(lib.bb_channel_iface(self._index)))
            return self._h

    def send(self, id: int, data: ByteData = b"", ext: bool = False, fd: bool = False,
             brs: bool = False) -> None:
        """Puts a frame on the wire. fd/brs left False let the wire's declared format decide."""
        self._send_on(self._handle(), _bb_frame(self.name, id, data, ext, fd, brs))

    def _send_on(self, h, f):
        lib = _lib.lib()
        _lib.check(lib.bb_bus_send(h, ctypes.byref(f)))

    def recv(self, timeout_ms: float | None = 1000) -> Frame | None:
        """The next frame other nodes sent, waiting at most timeout_ms (None: forever); None when
        nothing came. Ctrl-C ends the wait within 100 ms (SLICE_MS)."""
        ms = _ms(timeout_ms)
        h = self._handle()  # one handle for the whole wait: a close or stop meanwhile ends it
        return _sliced(lambda part: self._receive(part, h)[0], ms)

    def look(self) -> tuple[Frame | None, bool]:
        """One look at what is already queued: (frame or None, spent). `spent` says the look
        stopped at its bound with records still queued behind it, so a poller looks again at once
        rather than sleeping."""
        return self._receive(0)

    def _receive(self, ms, h=None):
        """(frame or None, spent) from the channel's handle, or from `h`, one it had."""
        f = _lib.BbFrame()
        lib = _lib.lib()
        rc = _lib.check(lib.bb_bus_recv(self._handle() if h is None else h, ms, ctypes.byref(f)))
        if rc in (_lib.BB_NONE, _lib.BB_SPENT):
            return None, rc == _lib.BB_SPENT
        return frame_of(f, received=True), False

    def expect(self, id: "int | Message", timeout_ms: float = 1000, *, ext: bool | None = None) -> Frame:
        """The first frame another node sends with this id AND kind, waited for at most timeout_ms
        in all; blobly.Timeout when none came, its message saying what came instead.

        `id` is an int, its kind `ext` (False or None: 11-bit, True: 29-bit), or a Message of this
        channel, whose id and kind it is (ext left out). timeout_ms is one deadline for the whole
        wait however many other frames arrive: a finite number of milliseconds, and nothing read
        once it has passed but the first look (a wait of 0 reads at most one queued frame).

        Every frame read while waiting is consumed, the ones that did not match included: a later
        recv or expect gets the frame after it."""
        __tracebackhide__ = True  # a pytest failure points at the test's line, not this one
        deadline = _deadline("expect", timeout_ms)
        with _lib.state_lock:
            want = self._frame_key("expect", id, ext)
            run = _lib.state["run"]
        others = collections.Counter()
        for f in self._frames_until(deadline, run):
            if (f.id, f.ext) == want:
                self._same_run(run)
                return f
            others[(f.id, f.ext)] += 1
        raise Timeout(f"{self.name}: expected a frame {_id_text(*want)} within {_num(timeout_ms)} ms; "
                      + _came(others, want[0]), _lib.BB_ERR_TIMEOUT)

    def expect_signal(self, message: "Message | str", signal: "Signal | str", want: object,
                      timeout_ms: float = 1000) -> tuple[Frame, float]:
        """The first frame of `message` whose decoded `signal` matches `want`, and that value,
        waited for at most timeout_ms in all; blobly.Timeout when none came, its message saying
        what the signal was instead.

        `message` is a Message of this channel or its name, and its frames are those of its id AND
        kind. `signal` is a signal of it, or its name. `want` is a callable, a predicate on the
        decoded physical value, or a value compared with ==: decoded values are floats carrying
        the rounding of raw x factor + offset, so a value a binary fraction cannot hold (0.1 steps)
        wants pytest.approx(0.3) or a predicate. timeout_ms is one deadline for the whole wait, as
        expect's.

        Every frame read while waiting is consumed, the ones that did not match included: a later
        recv or expect gets the frame after it."""
        __tracebackhide__ = True  # a pytest failure points at the test's line, not this one
        deadline = _deadline("expect_signal", timeout_ms)  # what the lookups below take is spent
        with _lib.state_lock:  # the message and signal of one run, which the wait then holds to
            msg = self._own("expect_signal", message)
            key = self._frame_key("expect_signal", msg, None)
            if isinstance(signal, str):
                sig = msg.signals[signal]  # an unknown name is refused now, not after the wait
            elif isinstance(signal, Signal):
                sig = signal
            else:
                raise TypeError(f"expect_signal: a signal is a Signal or its name, not {signal!r}")
            # the Signal itself, not its name: two signals of one name are two signals
            if not any(s is sig for s in msg.signals):
                raise ValueError(f"expect_signal: that {sig.name} is not a signal of {msg.name} in this "
                                 f"run; take it from {msg.name}.signals, or name it")
            run = _lib.state["run"]
        name = sig.name
        if want is None or isinstance(want, (str, bytes)):
            raise TypeError(f"expect_signal: want is a number (decoded values are) or a predicate, not "
                            f"{want!r}; a value table's labels are {msg.name}.signals.{name}.labels")
        test = want if callable(want) else (lambda v: v == want)
        others = collections.Counter()
        frames, values = 0, {}  # its frames read; the signal's first values, in the order seen
        last = lo = hi = None
        for f in self._frames_until(deadline, run):
            if (f.id, f.ext) != key:
                others[(f.id, f.ext)] += 1
                continue
            frames += 1
            got = self._decode(f, run)
            v = next((v for s, v in got[1] if s is sig), None) if got is not None and got[0] is msg else None
            if v is None:
                continue  # a multiplexed signal the frame does not carry
            if test(v):
                self._same_run(run)  # the predicate may have stopped the run it was asked about
                return f, v
            last, lo, hi = v, v if lo is None else min(lo, v), v if hi is None else max(hi, v)
            if len(values) <= 5:
                values[v] = None
        wanted = f"to satisfy {getattr(want, '__name__', repr(want))}" if callable(want) else f"== {want!r}"
        text = f"{self.name}: expected {msg.name}.{name} {wanted} within {_num(timeout_ms)} ms; "
        if not frames:
            text += f"no {msg.name} frame ({_id_text(*key)}) came; " + _came(others, key[0])
        elif last is None:
            text += f"{frames} {msg.name} frame{_s(frames)} came, none carrying {name}"
        elif len(values) <= 5:
            text += f"{frames} {msg.name} frame{_s(frames)} came, {name} was " + ", ".join(map(repr, values))
        else:
            text += f"{frames} {msg.name} frames came, {name} went from {lo!r} to {hi!r}, last {last!r}"
        raise Timeout(text, _lib.BB_ERR_TIMEOUT)

    def _frame_key(self, who, id, ext):
        """(id, ext) a wait matches: an int and the kind ext names, or a Message's own; either
        refused where no frame can carry it."""
        if isinstance(id, Message):
            if ext is not None:
                raise TypeError(f"{who}: a Message carries its own kind; leave ext out")
            msg = self._own(who, id)
            id, ext, hint = msg.id, msg.ext, f" (its database's {msg.name})"
        elif isinstance(id, bool) or not isinstance(id, int):
            raise TypeError(f"{who}: an id is an int or a Message of {self.name}, not {id!r}")
        else:
            hint = "; a 29-bit id is ext=True" if not ext and 0 <= id <= 0x1FFF_FFFF else ""
        wide = bool(ext)
        if not 0 <= id <= (0x1FFF_FFFF if wide else 0x7FF):
            shown = f"0x{id:X}" if id >= 0 else str(id)
            raise ValueError(f"{who}: {shown} is not {'a 29' if wide else 'an 11'}-bit id{hint}")
        return id, wide

    def _own(self, who, message):
        """A Message of this row's databases in this run: one of this channel's, or its name."""
        if isinstance(message, str):
            return self.messages[message]
        if not isinstance(message, Message):
            raise TypeError(f"{who}: a message is a Message or its name, not {message!r}")
        if message.channel is not self:
            raise ValueError(f"{who}: {message.name} is a message of {message.channel.name}, not of {self.name}")
        message._live()
        return message

    def _frames_until(self, deadline, run):
        """The frames read from now until `deadline` (monotonic_ms) has passed: each read waits
        whole milliseconds, at most SLICE_MS (so Ctrl-C lands), and never past it, the fraction of
        one the driver cannot be asked for is slept rather than read, and nothing is read once it
        has passed but the first look (so a wait of 0 reads at most one queued frame). A look that stopped at its bound with records
        still queued (look's `spent`) looks again at once, within it. All of it in the project's
        run `run`, on the handle the channel had in it: a stop closes that handle, and a stop or
        a start during the wait is refused, never waited through on the next run's handle."""
        with _lib.state_lock:
            self._same_run(run)
            h = self._handle()  # opened inside the wait, not before it: a slow open spends its time
        first = True
        while True:
            self._same_run(run)
            left = deadline - monotonic_ms()
            if left <= 0 and not first:
                return
            first = False
            try:
                f, spent = self._receive(min(max(0, math.floor(left)), SLICE_MS), h)
            except BloblyError:
                with _lib.state_lock:  # a stop closed the handle: said as the stop, once it is done
                    self._same_run(run)
                raise
            self._same_run(run)
            if f is not None:
                yield f
            elif not spent and left < 1:
                rest = deadline - monotonic_ms()
                if rest > 0:
                    sleep_ms(rest)
                self._same_run(run)
                return

    def _same_run(self, run):
        if _lib.state["run"] != run:
            raise BloblyError(f"{self.name}: the project was stopped or restarted during the wait",
                              _lib.BB_ERR_STATE)

    def health(self) -> str:
        """The controller's ladder now: "ok", "error warning", "ERROR-PASSIVE", "BUS-OFF", or ""
        where the backend cannot say (the software buses)."""
        lib = _lib.lib()
        return _lib.HEALTH_NAMES.get(_lib.check(lib.bb_bus_health(self._handle())), "")

    def load(self) -> BusLoad:
        """This channel's bus load as its handle counted it since it opened: the frames it received
        (when read) and sent, priced at the wire's first enabled row's rates. From the thread that
        uses the channel."""
        return load_of(self._handle())

    def diagnostics(self) -> BusDiagnostics:
        """What the backend counted since this channel's handle opened: dropped, controller-error
        and undecodable records. From the thread that uses the channel."""
        return diagnostics_of(self._handle())

    @property
    def messages(self) -> "Messages":
        """The messages of this row's databases, as the run loaded them (start; the merge of its
        `databases:` its simulated ECUs encode by): `ch.messages.Powertrain`, `ch.messages["X"]`,
        by position, iterated in the database's order, completed by dir(). Re-read at each start,
        keeping each Message still at its position under its name and id."""
        lib = _lib.lib()
        with _lib.state_lock:
            self._current()
            run = _lib.state["run"]
            if self._messages is not None and self._messages_run == run:
                return self._messages
            n = _lib.check(lib.bb_message_count(self._index))
            old = list(self._messages) if self._messages is not None else []
            rows = []
            for m in range(n):
                info = _lib.BbMessage()
                _lib.check(lib.bb_message_info(self._index, m, ctypes.byref(info)))
                name = _lib.string(lib.bb_message_name, self._index, m)
                keep = old[m] if m < len(old) else None
                if keep is None or (keep.name, keep.id, keep.ext) != (name, info.id, bool(info.ext)):
                    keep = Message(self, m, name)
                keep._fill(info, run)
                rows.append(keep)
            self._messages, self._messages_run = Messages(rows), run
            return self._messages

    def decode(self, frame: Frame) -> dict[str, float] | None:
        """{signal: physical value} for what `frame` says in this row's databases — the message
        of its id and kind (else, for an extended frame, one of its J1939 PGN), each signal it
        carries (a multiplexed signal its switch does not select is left out, and so is one whose
        bits a short payload does not all hold, where a Lua script's decode() reads them as 0);
        None for a frame of no message, or a remote frame."""
        got = self._decode(frame)
        if got is None:
            return None
        return {s.name: v for s, v in got[1] if v is not None}

    def _decode(self, frame, run=None):
        """(the Message `frame` decodes as, [(Signal, its value, or None where the frame does not
        carry it)] in their order), or None: decode's answer by position, values and signals read
        under one hold of the state lock. With `run`, refused unless the project's run is still
        that one."""
        f = _bb_frame(self.name, frame.id, frame.data, getattr(frame, "ext", False),
                      rtr=getattr(frame, "rtr", False))
        lib = _lib.lib()
        with _lib.state_lock:
            if run is not None:
                self._same_run(run)
            msgs = self.messages
            values, active, m = msgs._decoded  # the lock is held: one decode at a time uses them
            rc = _lib.check(lib.bb_decode(self._index, ctypes.byref(f), ctypes.byref(m), values, active,
                                          msgs._most))
            if rc == _lib.BB_NONE:
                return None
            msg = msgs[m.value]
            return msg, [(s, values[i] if active[i] else None) for i, s in enumerate(msg.signals)]

    def uds(self, tx: int | None = None, rx: int | None = None) -> UdsClient:
        """A UdsClient on this row, by the rule the Lua uds.open opens by, while the project is
        started. On a CAN row UDS requests go out on CAN id `tx` and answers come back on `rx`:
        None is the default pair 0x7E0 / 0x7E8, 0 is an id like any other, and either id past
        0x7FF makes both 29-bit. On a DoIP row they ride a TCP connection to its entity, from the
        row's tester_address to its ecu_address, so tx and rx are refused; RoutingDenied when the
        entity will not route the tester, and one client at a time holds the row's connection
        (ISO 13400-2: one tester address, one connection) — a second is refused while it is open."""
        return UdsClient(self, tx, rx)

    def uds_functional(self, functional_id: int | None, clients: Sequence[UdsClient], request: ByteData,
                       window_ms: int = 1000) -> list[FunctionalReply]:
        """UDS functional addressing (ISO 14229-2) on this row, as the Lua uds.functional. On a
        CAN row `request` goes out ONCE, a Single Frame (7 bytes at most) on CAN id
        `functional_id`, and each of `clients` — UdsClients of this channel — answers on its own
        response id, a multi-frame answer included. On a DoIP row it goes to the functional
        logical address `functional_id` (None: 0xE400) on the connection of `clients`' one
        UdsClient, and the entity answers from its own address. Returns a FunctionalReply per
        client, in their order. `window_ms` bounds each one's first answer; one that says
        responsePending is waited for its P2* after it."""
        return functional(self, functional_id, clients, request, window_ms)

    def discover(self, timeout_ms: float = 1200) -> DoipAnnouncement:
        """A DoIP row's entity asked who it is (ISO 13400-2 vehicle identification, the Lua
        doip.discover): a DoipAnnouncement — what it ANNOUNCES, which need not be what it serves
        at DID 0xF190. Timeout when no answer came within timeout_ms; refused on a CAN or
        SOME/IP row."""
        return discover(self, timeout_ms)

    def close(self) -> None:
        """Lets the handle go, and the connections of its UDS clients; the next use opens another."""
        lib = _lib.lib()
        with _lib.state_lock:
            _close_orphans()
            for c in list(self._uds):
                c._let_go()
            if self._h is not None:
                h, self._h = self._h, None
                _lib.check(lib.bb_bus_close(h))

    def __repr__(self) -> str:
        return f"<Channel {self.name}>"


class _HasName(Protocol):
    name: str


_T = TypeVar("_T", bound=_HasName)


class Named(Generic[_T]):
    """Items by name: `c.X`, `c["X-1"]`, `c[0]` (by position), iteration in order, and dir() for
    completion. A name two items answer to is refused, and such items are reached by position."""
    _noun = "item"

    def __init__(self, items: list[_T]) -> None:
        self._by_name = {}
        for c in items:
            self._by_name.setdefault(c.name, []).append(c)
        self._order = items

    def _one(self, name: str) -> _T | None:
        rows = self.__dict__.get("_by_name", {}).get(name)
        if not rows:
            return None
        if len(rows) > 1:
            raise BloblyError(f"{name!r} names {len(rows)} {self._noun}s here; reach them by "
                              f"position ([i]) or rename one")
        return rows[0]

    def __getattr__(self, name: str) -> _T:
        c = self._one(name)
        if c is None:  # also for an object copy or pickle is still building
            raise AttributeError(f"no {self._noun} named {name!r}; there are: "
                                 + ", ".join(self.__dict__.get("_by_name", {})))
        return c

    def __getitem__(self, key: int | str) -> _T:
        if isinstance(key, int):
            return self._order[key]
        c = self._one(key)
        if c is None:
            raise KeyError(f"no {self._noun} named {key!r}; there are: " + ", ".join(self._by_name))
        return c

    def __dir__(self) -> list[str]:
        return [n for n, rows in self._by_name.items() if n.isidentifier() and len(rows) == 1] + ["keys"]

    def __iter__(self) -> Iterator[_T]:
        return iter(self._order)

    def __len__(self) -> int:
        return len(self._order)

    def keys(self) -> list[str]:
        """The names, in order, each once."""
        return list(self._by_name)


class Channels(Named[Channel]):
    """The project's enabled rows: `net.channels.CAN1`, `net.channels["CAN-1"]`, `net.channels[0]`.
    Names are not unique in a project: two rows of one name are reached by position."""
    _noun = "enabled channel"


class Messages(Named["Message"]):
    """A row's messages (Channel.messages)."""
    _noun = "message"

    def __init__(self, items: list["Message"]) -> None:
        super().__init__(items)
        self._most = max((m._count for m in items), default=0)
        # bb_decode's out arrays, as wide as the widest message, made once
        n = max(self._most, 1)
        self._decoded = ((ctypes.c_double * n)(), (ctypes.c_uint8 * n)(), ctypes.c_int(-1))


class Signals(Named["Signal"]):
    """A message's signals (Message.signals)."""
    _noun = "signal"


class Signal:
    """A signal of a message, as its database defines it. physical = raw * factor + offset, the
    raw value two's complement where `signed`; `byte_order` "little" (Intel) or "big" (Motorola),
    `start_bit` as the DBC numbers it; `minimum`/`maximum` the DBC's range (both 0 where it states
    none; encode does not apply it); `labels` the value table as decode's values name it,
    {physical value: text}, and `raw_labels` as the database keys it, {raw key: text} — the field's
    bits, two's complement for a signed signal; every entry is there, where two keys a double
    cannot tell apart (past 2**53) are one entry of `labels`."""
    __slots__ = ("name", "start_bit", "length", "byte_order", "signed", "factor", "offset",
                 "minimum", "maximum", "unit", "multiplexor", "multiplexed", "mux_value", "labels",
                 "raw_labels")
    name: str
    start_bit: int
    length: int
    byte_order: Literal["little", "big"]
    signed: bool
    factor: float
    offset: float
    minimum: float
    maximum: float
    unit: str
    multiplexor: bool
    multiplexed: bool
    mux_value: int
    labels: dict[float, str]
    raw_labels: dict[int, str]

    def __repr__(self) -> str:
        unit = f" {self.unit!r}" if self.unit else ""
        return (f"<Signal {self.name} {self.start_bit}|{self.length} {self.byte_order} "
                f"x{self.factor:g}{self.offset:+g} [{self.minimum:g}..{self.maximum:g}]{unit}>")


class Message:
    """A message of a row's databases: `id`, `ext`, `dlc`, `j1939` (the database declares it),
    `signals`; encode / send by signal name. It belongs to the run that listed it: after a stop
    and a start it goes on working while its row's database still has it at its position, and
    refuses otherwise."""
    name: str
    id: int
    ext: bool
    dlc: int
    j1939: bool
    channel: Channel

    def __init__(self, channel: Channel, index: int, name: str) -> None:
        self.channel, self._index, self.name = channel, index, name
        self._signals = None

    def _fill(self, info, run):
        self.id, self.ext, self.dlc, self.j1939 = info.id, bool(info.ext), info.dlc, bool(info.j1939)
        self._count, self._run, self._signals = info.signals, run, None

    def _live(self):
        """Refuses unless this message is in the current run's database of its channel."""
        self.channel.messages  # re-read after a start: keeps this object if it is still there
        if self._run != _lib.state["run"]:
            raise BloblyError(f"{self.name}: not in this run's database of {self.channel.name}; "
                              "take it from channel.messages again", _lib.BB_ERR_STATE)

    @property
    def signals(self) -> Signals:
        """Its signals, as its database defines them."""
        lib = _lib.lib()
        with _lib.state_lock:
            self._live()
            if self._signals is None:
                row, m, rows = self.channel._index, self._index, []
                for i in range(self._count):
                    info = _lib.BbSignal()
                    _lib.check(lib.bb_signal_info(row, m, i, ctypes.byref(info)))
                    s = Signal()
                    s.name = _lib.string(lib.bb_signal_name, row, m, i)
                    s.unit = _lib.string(lib.bb_signal_unit, row, m, i)
                    s.start_bit, s.length = info.start_bit, info.length
                    s.byte_order = "big" if info.big_endian else "little"
                    s.signed, s.factor, s.offset = bool(info.is_signed), info.factor, info.offset
                    s.minimum, s.maximum = info.minimum, info.maximum
                    s.multiplexor, s.multiplexed = bool(info.multiplexor), bool(info.multiplexed)
                    s.mux_value = info.mux_value
                    s.labels, s.raw_labels = {}, {}
                    raw, value = ctypes.c_uint64(), ctypes.c_double()
                    for k in range(info.labels):
                        text = _lib.string(lib.bb_signal_label, row, m, i, k, ctypes.byref(raw), ctypes.byref(value))
                        s.raw_labels[raw.value] = text
                        s.labels.setdefault(value.value, text)
                    rows.append(s)
                self._signals = Signals(rows)
            return self._signals

    def encode(self, /, **signals: float) -> Frame:
        """The Frame this message sends with the named signals at these physical values and every
        other at raw 0, as a Lua script's bus.send_message encodes it: a name the message does not
        have is refused; a value past what the signal's width holds is clamped to the nearer end.
        fd/brs are left unset, so a send takes the wire's declared format."""
        names = []
        values = []
        for k, v in signals.items():
            if "\0" in k:
                raise ValueError(f"{self.name}: a signal name cannot carry a NUL: C would read it cut short")
            names.append(k.encode())
            if not isinstance(v, numbers.Real):
                raise TypeError(f"{self.name}.{k}: a signal's value is a number, not {v!r}")
            values.append(float(v))
        n = len(names)
        f = _lib.BbFrame()
        lib = _lib.lib()
        with _lib.state_lock:
            self._live()
            _lib.check(lib.bb_encode(self.channel._index, self._index, n, (ctypes.c_char_p * n)(*names),
                                     (ctypes.c_double * n)(*values), ctypes.byref(f)))
        return frame_of(f)

    def send(self, /, **signals: float) -> Frame:
        """Encodes this message (encode) and sends it on its channel; returns the encoded Frame. Its
        fd/brs are unset, so what goes out takes the wire's declared format. Encoded and the
        channel's handle taken under one hold of the state lock, so a stop and start on another
        thread cannot put this run's encoding on the next run's wire."""
        with _lib.state_lock:
            f = self.encode(**signals)
            h = self.channel._handle()
        self.channel._send_on(h, _bb_frame(self.channel.name, f.id, f.data, f.ext))
        return f

    def __repr__(self) -> str:
        return f"<Message {self.name} 0x{self.id:X}{' ext' if self.ext else ''} [{self.dlc}] on {self.channel.name}>"


def _say_dropped(path, gone):
    """The RuntimeWarning naming the rows whose handlers a reload dropped, said from the first
    caller outside this module (the line that loaded, started or entered the with block)."""
    if not gone:
        return
    level, f = 2, sys._getframe(1)
    while f.f_back is not None and f.f_code.co_filename == __file__:
        f, level = f.f_back, level + 1
    warnings.warn(f"{path}: handlers dropped, their rows are not in this load of the project ("
                  + ", ".join(gone) + "); register them again", RuntimeWarning, stacklevel=level)


class Project(EventLoop[Channel | str], Faults):
    """A .blobnet project in this process. `with Project(path) as net:` loads and starts it — its
    simulated ECUs, UDS servers, generators and DoIP entities run until the block ends. One run per
    process, and one thread drives load, start and stop (bb.h); send and recv may run on others.
    Faults (fault, clear_fault) make its simulated ECUs misbehave on purpose; `generators` fires and
    cycles its generators."""
    path: str | bytes
    started: bool

    def __init__(self, path: "str | bytes | os.PathLike[str] | os.PathLike[bytes]") -> None:
        super().__init__()
        p = os.fspath(path)
        if (b"\0" if isinstance(p, bytes) else "\0") in p:
            raise ValueError("a project path cannot carry a NUL: C would read it cut short")
        self.path = os.path.abspath(path)
        self.started = False
        self._channels = None
        self._gen = None  # which load of the library is this project's
        self._rr = 0
        self._gens, self._gens_run = None, None  # the generators, as the run of _gens_run lists them
        self._nodes, self._nodes_run = None, None  # the system model's nodes, as the run of _nodes_run has them

    def load(self) -> Self:
        """Reads the project into the library, which holds one load at a time: another project's
        channels refuse from here on. A reload of this project KEEPS each Channel whose row is
        still at its position under its name — so a variable, a timer's closure and a handler all
        go on working — and drops the handlers of rows that went, naming them in a
        RuntimeWarning."""
        _say_dropped(self.path, self._load())
        return self

    def _load(self):
        """load, answering the rows whose handlers it dropped."""
        lib = _lib.lib()
        with _lib.state_lock:
            _lib.check(lib.bb_load(os.fsencode(self.path)))  # the filesystem's bytes, not UTF-8
            old = list(self._channels) if self._channels is not None else []
            for c in old:
                try:
                    c.close()
                except BloblyError:
                    pass
            st = _lib.state
            st["gen"] += 1
            st["owner"] = self
            self._gen = st["gen"]
            n = _lib.check(lib.bb_channel_count())
            rows = []
            for i in range(n):
                name = _lib.text(lib.bb_channel_name(i))
                keep = old[i] if i < len(old) and old[i].name == name else None
                if keep is not None:
                    keep._gen = st["gen"]  # the same object, current again
                    rows.append(keep)
                else:
                    rows.append(Channel(self, i, name, st["gen"]))
            self._channels = Channels(rows)
        return self._drop_gone(rows)

    def _drop_gone(self, rows):
        """Drops the registrations on channels this load did not keep, and names them, rather than
        leave a handler that hears nothing."""
        live = set(map(id, rows))
        gone = []

        def kept(key):
            if not isinstance(key, Channel) or id(key) in live:
                return True
            gone.append(f"{key.name} (row {key._index})")
            return False
        self._listened = [k for k in self._listened if kept(k)]
        self._on_msg = [(k, i, fn) for k, i, fn in self._on_msg if kept(k)]
        self._on_health = [h for h in self._on_health if kept(h.channel)]
        return sorted(set(gone))

    def start(self) -> Self:
        """Starts this project — reloaded first if the library holds another load now (see load)."""
        lib = _lib.lib()
        with _lib.state_lock:
            st = _lib.state
            if st["owner"] is not self or st["gen"] != self._gen:
                _say_dropped(self.path, self._load())  # before bb_start: a failed start still says it
            _lib.check(lib.bb_start())
            st["run"] += 1  # the rows' databases are this run's from here
            self.started = True
        return self

    def stop(self) -> bool:
        """Ends the run. True when the process is free for the next start; False when a loop
        outlived the stop's bound (a driver call that will not return) — blobly.wait_released
        waits for it."""
        lib = _lib.lib()
        with _lib.state_lock:
            if not self.started:
                # nothing of ours runs; an earlier stop may still be letting go of the process
                return _lib.check(lib.bb_wait_released(0)) == 0
            for c in self._channels:
                try:
                    c.close()
                except BloblyError:
                    pass  # a handle already gone is closed enough
            self.started = False
            _lib.state["run"] += 1  # the run's databases end with it
            # False: a loop outlived the stop's bound and still holds the process; a start refuses
            # until blobly.wait_released says it has let go
            return _lib.check(lib.bb_stop()) != _lib.BB_RELEASING

    def __enter__(self) -> Self:
        return self.start()

    def __exit__(self, *exc: object) -> Literal[False]:
        if not self.stop():
            warnings.warn(f"{self.path}: a loop outlived the stop's bound and still holds the "
                          "process; blobly.wait_released() waits for it before the next start",
                          RuntimeWarning, stacklevel=2)
        return False

    @property
    def channels(self) -> Channels:
        """The enabled rows; BloblyError before load()."""
        if self._channels is None:
            raise BloblyError("the project is not loaded", _lib.BB_ERR_STATE)
        return self._channels

    @property
    def generators(self) -> Generators:
        """The run's generators (blobly.Generators): `net.generators["Heartbeat pulse"].fire()`.
        BloblyError (code -3) when the project is not started."""
        with _lib.state_lock:
            if not self.started:
                raise BloblyError("the project is not started: its generators are the run's", _lib.BB_ERR_STATE)
            if self._gens_run != _lib.state["run"]:
                self._gens = _listed_generators(self, list(self._gens) if self._gens is not None else None)
                self._gens_run = _lib.state["run"]
            return self._gens

    @property
    def system(self) -> str | None:
        """The system.toml the run read — beside the project, beside one of its databases, or in
        its folder's parent — and its nodes' ecu.toml with it; None when none describes the project.
        BloblyError (code -3) when the project is not started."""
        with _lib.state_lock:
            if not self.started:
                raise BloblyError("the project is not started: its system model is the run's", _lib.BB_ERR_STATE)
            return _lib.string(_lib.lib().bb_system_path) or None

    @property
    def nodes(self) -> "Nodes":
        """The nodes of the run's system model (blobly.Nodes): `net.nodes.zone_a.uds()` is a
        NodeClient on zone_a, its DIDs `net.nodes.zone_a.dids`. Empty when no system.toml
        describes the project (system is None). BloblyError (code -3) when the project is not
        started."""
        with _lib.state_lock:
            if not self.started:
                raise BloblyError("the project is not started: its system model is the run's", _lib.BB_ERR_STATE)
            if self._nodes_run != _lib.state["run"]:
                from .nodes import listed  # nodes.py builds on this module's Named
                self._nodes = listed(self, list(self._nodes) if self._nodes is not None else None)
                self._nodes_run = _lib.state["run"]
            return self._nodes

    # the event loop's hooks, over libblobly
    def _resolve(self, channel):
        c = self.channels[channel] if isinstance(channel, str) else channel
        if not isinstance(c, Channel) or c._project is not self:
            raise BloblyError(f"{channel!r} is not a channel of this project")
        c._current()
        return c

    def _now(self):
        return monotonic_ms()

    def _listen(self, c):
        c._handle()  # open (and refuse a channel that is not a CAN bus) here

    def _health(self, c):
        return c.health()

    def _health_needs_reader(self, c):
        return c._health_needs_reader()

    def _wait_frame(self, channels, timeout_ms):
        got, self._rr = wait_on(channels, timeout_ms, self._rr, monotonic_ms, sleep_ms)
        return got

    def __repr__(self) -> str:
        return f"<Project {self.path}{' started' if self.started else ''}>"
