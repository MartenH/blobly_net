"""project — a .blobnet project brought up in this process through libblobly (blobly.headless),
its enabled channels as objects that complete in a REPL, and the event loop over them."""
import collections
import ctypes
import math
import numbers
import os
import sys
import threading
import warnings
import weakref
from collections.abc import Callable, Iterator, Mapping, Sequence
from typing import TYPE_CHECKING, Generic, Literal, Protocol, Self, TypeAlias, TypeVar

from . import _lib
from ._lib import BloblyError, ByteData, Refused, Timeout
from .events import SLICE_MS, EventLoop, _finite, _on_thread, _sliced, monotonic_ms, sleep_ms, wait_on
from .doip import DoipAnnouncement, discover
from .uds import FunctionalReply, UdsClient, _close_orphans, _orphans, functional
from .faults import Faults
from .metrics import BusDiagnostics, BusLoad, ErrorCounters, diagnostics_of, error_counters_of, load_of
from .generators import Generators, listed as _listed_generators
from .isotp import IsoTp
from .j1939 import J1939Listener
from .nm import NmListener
from .replay import Replays
from .e2e import E2eStatus, _passed, status_of
from .cyclic import CyclicSender, _period, _start_message, _start_raw

if TYPE_CHECKING:
    from .lin import LinBuses
    from .nodes import Nodes

# a frame's stated format (bb.h's enum bb_format, the Lua bus.send's `format =`); None states none
FrameFormat: TypeAlias = Literal["classic", "fd", "fd_brs"]

# how long latest() reads what is queued before it answers: a bus faster than this reader still
# gets an answer
CATCH_UP_MS = 100


class Frame:
    """A CAN frame. `data` is the payload; `length` its length, or for a remote frame (`rtr`, no
    payload) the length it asks for; `fd`/`brs` CAN-FD and its bit-rate switch; `esi` CAN-FD's
    error-state indicator. `t_ms` is when a received frame arrived, in ms on the host's monotonic
    clock (`blobly.now_ms()`), the time the GUI's trace gives it: its receive stamp where the
    backend reads one, else its receipt. None on a frame not received. `e2e` is a received frame's
    E2E verdict (an E2eStatus), None where its message has no E2E on its channel or the frame was
    not received; where the message is protected in several windows (a signal group's bytes each),
    the worst of theirs, and `e2e_groups` each window's by name (its signal group's, else the
    message's), None where `e2e` is. A value: equal frames hash alike, and none is changed once
    made; `t_ms`, `e2e` and `e2e_groups` are not part of the value, so a received frame equals the
    frame built from its content."""
    __slots__ = ("id", "data", "length", "ext", "fd", "brs", "rtr", "esi", "t_ms", "e2e", "e2e_groups")
    id: int
    data: bytes
    length: int
    ext: bool
    fd: bool
    brs: bool
    rtr: bool
    esi: bool
    t_ms: float | None
    e2e: E2eStatus | None
    e2e_groups: dict[str, E2eStatus] | None

    def __init__(self, id: int, data: ByteData = b"", ext: bool = False, fd: bool = False,
                 brs: bool = False, rtr: bool = False, esi: bool = False, length: int | None = None,
                 t_ms: float | None = None, e2e: E2eStatus | str | None = None,
                 e2e_groups: Mapping[str, E2eStatus | str] | None = None) -> None:
        data = _lib.byte_data("data", data)
        _fill(self, (id, data, len(data) if length is None else length, ext, fd, brs, rtr, esi, t_ms,
                     None if e2e is None else E2eStatus(e2e),
                     None if e2e_groups is None else {k: E2eStatus(v) for k, v in e2e_groups.items()}))

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError(f"a Frame is a value: make another rather than set {name}")

    def __delattr__(self, name: str) -> None:
        raise AttributeError(f"a Frame is a value: {name} cannot be deleted")

    def __setstate__(self, state: object) -> None:
        """copy and pickle restore a frame's slots (a subclass's too) past __setattr__."""
        attrs, slots = state if isinstance(state, tuple) else (state, None)
        object.__setattr__(self, "t_ms", None)  # a frame pickled before frames carried a time
        object.__setattr__(self, "e2e", None)  # or a verdict
        object.__setattr__(self, "e2e_groups", None)
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


# what a frame is: every field but when it was received and its E2E verdicts
_IDENTITY = ("id", "data", "length", "ext", "fd", "brs", "rtr", "esi")


def _fill(frame, fields):
    for k, v in zip(Frame.__slots__, fields):
        object.__setattr__(frame, k, v)


def frame_of(f: _lib.BbFrame, received: bool = False, h: int | None = None) -> Frame:
    """A Frame from a bb_frame: a remote frame's len is the length it asks for, with no payload;
    a received one carries its t_ns as t_ms, and its E2E verdict, with each window's read from `h`,
    the handle that received it."""
    data = b"" if f.rtr else bytes(memoryview(f.data)[:f.len])
    e2e = status_of(f.e2e) if received else None
    groups = _e2e_groups(h) if e2e is not None and h is not None else None
    return Frame(f.id, data, bool(f.ext), bool(f.fd), bool(f.brs), bool(f.rtr), bool(f.esi), f.len,
                 _lib.ms_of(f.t_ns) if received else None, e2e, groups)


def _e2e_groups(h: int) -> dict[str, E2eStatus]:
    """Each window's verdict on the last frame handle `h` received, by name."""
    lib = _lib.lib()
    out: dict[str, E2eStatus] = {}
    for i in range(_lib.check(lib.bb_e2e_groups(h))):
        status = status_of(_lib.check(lib.bb_e2e_group_verdict(h, i)))
        if status is not None:
            out[_lib.string(lib.bb_e2e_group_name, h, i)] = status
    return out


# an enum bb_format as a stated format: BB_FORMAT_WIRE (0) states none
_FORMAT_NAMES: dict[int, FrameFormat] = {_lib.FORMATS["classic"]: "classic", _lib.FORMATS["fd"]: "fd",
                                          _lib.FORMATS["fd_brs"]: "fd_brs"}


def _format(who, format):
    """bb_frame.format for a stated format: None states nothing, else "classic", "fd" or "fd_brs"."""
    if format is None:
        return 0
    code = _lib.FORMATS.get(format) if isinstance(format, str) else None
    if code is None:
        raise ValueError(f"{who}: format is \"classic\", \"fd\", \"fd_brs\" or None, not {format!r}")
    return code


def _bb_frame(who, id, data, ext=False, fd=False, brs=False, rtr=False, format=None):
    """A bb_frame from a frame's parts, refusing what no CAN frame is."""
    if isinstance(id, bool) or not isinstance(id, int) or not 0 <= id <= 0x1FFF_FFFF:
        raise ValueError(f"{who}: a CAN id is an integer of at most 29 bits, not {id!r}")
    data = _lib.byte_data(f"{who}: data", data)
    if len(data) > 64:
        raise ValueError(f"{who}: {len(data)} bytes is more than a CAN-FD frame carries")
    f = _lib.BbFrame(id=id, len=len(data), ext=int(bool(ext)), fd=int(bool(fd)), brs=int(bool(brs)),
                     rtr=int(bool(rtr)), format=_format(who, format))
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


class Bus:
    """A CAN bus by its address (blobly.open): send, recv, look, expect, health, load,
    diagnostics and error_counters on one handle of its own, opened at once and let go by close (or the end of a
    `with`). A project row's Channel is a Bus too. Every send is checked against the wire policy
    of the loaded project, if any — a wire it marks listen-only refuses here as on its row — and
    the handle's load is priced at the rates of the project's first enabled row on that wire, else
    the address's own (`@<arb>[/<data>]`), else 500 kbit/s. One thread at a time uses it; close may
    come from another and ends a wait in progress."""
    name: str

    def __init__(self, address: str) -> None:
        if not isinstance(address, str) or not address:
            raise TypeError(f"an interface address is a non-empty string, not {address!r}")
        if "\0" in address:  # a C string would end there and name another bus
            raise ValueError(f"an interface address has no NUL: {address!r}")
        self.name = address
        self._h = None
        self._latest = {}  # the newest frame read per (id, ext), where the library keeps no view
        self._watch = None  # the handle whose newest-frame view the library keeps (bb_bus_watch)
        lib = _lib.lib()
        with _lib.state_lock:  # bb_bus_open reads the loaded project's rows
            _close_orphans()
            self._h = _lib.check(lib.bb_bus_open(address.encode()))
            self._watched(self._h)

    @property
    def iface(self) -> str:
        """The address it was opened with."""
        return self.name

    def _handle(self):
        h = self._h
        if h is None:
            raise BloblyError(f"{self.name}: closed", _lib.BB_ERR_HANDLE)
        return h

    def _watched(self, h):
        """Gives handle `h` the library's newest-frame view (bb_bus_watch), which latest and value
        then answer from; where the library cannot open one, they answer from what h reads."""
        lib = _lib.lib()
        if lib.bb_bus_watch(h) == 0:
            self._watch = h
            return
        try:
            warnings.warn(f"{self.name}: no newest-frame reader ({_lib.text(lib.bb_last_error())}); "
                          "latest and value answer as of this channel's last read", RuntimeWarning, stacklevel=3)
        except BaseException:  # the warning raised (an error filter): the handle goes with it
            if self._h == h:
                self._h = None
            lib.bb_bus_close(h)
            raise

    def _run(self):
        """What a wait holds to: nothing for a bus of its own (a Channel: its project's run)."""
        return None

    def _same_run(self, run):
        pass

    def _frame_key(self, who, id, ext, hint=None):
        """(id, ext) a wait matches: an int and the kind ext names (None: either kind, as on_message
        and Lua's expect take it), refused where no frame can carry it; `hint` what to add to that
        refusal (default: that a 29-bit id is ext=True)."""
        if isinstance(id, bool) or not isinstance(id, int):
            raise TypeError(f"{who}: an id is an int{self._message_note()}, not {id!r}")
        if ext is None:
            if not 0 <= id <= 0x1FFF_FFFF:
                shown = f"0x{id:X}" if id >= 0 else str(id)
                raise ValueError(f"{who}: {shown} is not a CAN id (at most 29 bits)")
            return id, None
        if hint is None:
            hint = "; a 29-bit id is ext=True" if not ext and 0 <= id <= 0x1FFF_FFFF else ""
        wide = bool(ext)
        if not 0 <= id <= (0x1FFF_FFFF if wide else 0x7FF):
            shown = f"0x{id:X}" if id >= 0 else str(id)
            raise ValueError(f"{who}: {shown} is not {'a 29' if wide else 'an 11'}-bit id{hint}")
        return id, wide

    def _message_note(self):
        return ""

    def send(self, id: int, data: ByteData = b"", ext: bool = False, fd: bool = False,
             brs: bool = False, *, format: FrameFormat | None = None) -> None:
        """Puts a frame on the wire. fd/brs left False let the declared format decide: a project
        channel's own (a canfd row's FD, also on a wire a can row shares), else the wire's.
        `format` STATES the frame's format, as the Lua bus.send's `format =` does: "classic" sends
        a classic frame on a CAN-FD wire (at most 8 bytes, refused otherwise), "fd" and "fd_brs"
        CAN-FD without and with the bit-rate switch whatever the wire declares; a flag it
        contradicts (fd or brs with "classic", brs with "fd") is refused. None states nothing."""
        self._send_on(self._handle(), _bb_frame(self.name, id, data, ext, fd, brs, format=format))

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
        h = self._handle() if h is None else h
        table = self._latest  # this handle's: a close replaces it only once the handle is gone
        rc = _lib.check(lib.bb_bus_recv(h, ms, ctypes.byref(f)))
        if rc in (_lib.BB_NONE, _lib.BB_SPENT):
            return None, rc == _lib.BB_SPENT
        frame = frame_of(f, received=True, h=h)
        if not frame.rtr:  # every read path comes through here; a remote frame carries no data
            table[(frame.id, frame.ext)] = frame
        return frame, False

    def latest(self, id: "int | Message", *, ext: bool | None = None) -> Frame | None:
        """The newest frame on the wire with this id AND kind since the handle opened, None before
        the first: kept by a reader in the library on a handle of its own, so it is current at the
        call even when nothing read this channel meanwhile (a UDS exchange, a flash, a sleep), and
        asking reads nothing off this channel. What this handle sends is not kept. `id` and `ext`
        as expect's (None: the newer of either kind); on a Channel `id` may be a Message of it.
        Its t_ms says how old it is; its e2e is None (no verdict). A remote frame (rtr) is not
        kept: it asks for the data and carries none. The frames of a closed handle are forgotten
        with it."""
        with _lib.state_lock:
            want = self._frame_key("latest", id, ext)
        h = self._handle()
        if self._watch is not None and self._watch == h:
            f = _lib.BbFrame()
            lib = _lib.lib()
            rc = _lib.check(lib.bb_bus_latest(h, want[0], -1 if want[1] is None else int(want[1]),
                                              ctypes.byref(f)))
            return None if rc == _lib.BB_NONE else frame_of(f, received=True)
        # no view: what is queued read first (at most CATCH_UP_MS), so the answer is as of the call
        self._catch_up()
        kinds = (False, True) if want[1] is None else (want[1],)
        got = [f for f in (self._latest.get((want[0], k)) for k in kinds) if f is not None]
        return max(got, key=lambda f: f.t_ms or 0.0) if got else None

    def _forget_latest(self):
        """Forgets the newest frames kept so far, the handle kept: latest answers from what comes
        after, as on a handle just opened."""
        self._latest = {}
        h = self._h
        if h is not None and self._watch == h:
            _lib.check(_lib.lib().bb_bus_latest_clear(h))

    def _catch_up(self):
        """Reads what is queued on the handle now into the newest-frame table, for at most
        CATCH_UP_MS, so a bus faster than this reader still answers."""
        h = self._handle()
        end = monotonic_ms() + CATCH_UP_MS
        while monotonic_ms() < end:
            f, spent = self._receive(0, h)
            if f is None and not spent:
                return

    def expect(self, id: "int | Message", timeout_ms: float = 1000, *, ext: bool | None = None,
               e2e: bool = False) -> Frame:
        """The first frame another node sends with this id AND kind, waited for at most timeout_ms
        in all; blobly.Timeout when none came, its message saying what came instead.

        `id` is an int, its kind `ext` (None: either kind, False: 11-bit, True: 29-bit), or on a
        Channel a Message of it, whose id and kind it is (ext left out). timeout_ms is one deadline for the whole
        wait however many other frames arrive: a finite number of milliseconds, and nothing read
        once it has passed but the first look (a wait of 0 reads at most one queued frame).

        With e2e=True the frame must pass its E2E check (Frame.e2e is "ok"): blobly.E2eError
        otherwise, its status the verdict, None where the frame's message has no E2E.

        Every frame read while waiting is consumed, the ones that did not match included: a later
        recv or expect gets the frame after it."""
        __tracebackhide__ = True  # a pytest failure points at the test's line, not this one
        if e2e and not isinstance(self, Channel):
            raise ValueError(f"expect: {self.name} is a bus opened by address, whose frames no row's E2E "
                             "judges; e2e=True needs the project's channel")
        deadline = _deadline("expect", timeout_ms)
        with _lib.state_lock:
            want = self._frame_key("expect", id, ext)
            run = self._run()
        others = collections.Counter()
        for f in self._frames_until(deadline, run):
            if f.id == want[0] and want[1] in (None, f.ext):
                self._same_run(run)
                if e2e:
                    _passed(self.name, f)
                return f
            others[(f.id, f.ext)] += 1
        raise Timeout(f"{self.name}: expected a frame {_id_text(*want)} within {_num(timeout_ms)} ms; "
                      + _came(others, want[0]), _lib.BB_ERR_TIMEOUT)

    def _frames_until(self, deadline, run, idle=False, slice_ms=SLICE_MS, look_first=False):
        """The frames read from now until `deadline` (monotonic_ms) has passed: each read waits
        whole milliseconds, at most SLICE_MS (so Ctrl-C lands), and never past it, the fraction of
        one the driver cannot be asked for is slept rather than read, and nothing is read once it
        has passed but the first look (so a wait of 0 reads at most one queued frame). A look that stopped at its bound with records
        still queued (look's `spent`) looks again at once, within it. All of it in the project's
        run `run`, on the handle the channel had in it: a stop closes that handle, and a stop or
        a start during the wait is refused, never waited through on the next run's handle. With
        `idle`, a read that found nothing yields None too, so a wait on a reading that moves with
        time (the NM state going to sleep) is asked after it; `slice_ms` (at most SLICE_MS) bounds
        each read; with `look_first` the first read waits for nothing, so what it brings up to
        now is asked before any wait (and a wait of 0 is still that one look)."""
        with _lib.state_lock:
            self._same_run(run)
            h = self._handle()  # opened inside the wait, not before it: a slow open spends its time
        first = True
        while True:
            self._same_run(run)
            left = deadline - monotonic_ms()
            if left <= 0 and not first:
                return
            look = first and look_first
            first = False
            try:
                f, spent = self._receive(0 if look else min(max(0, math.floor(left)), slice_ms), h)
            except BloblyError:
                with _lib.state_lock:  # a stop closed the handle: said as the stop, once it is done
                    self._same_run(run)
                raise
            self._same_run(run)
            if f is not None:
                yield f
                continue
            if idle and not spent:
                yield None
            if not spent and left < 1 and not look:
                rest = deadline - monotonic_ms()
                if rest > 0:
                    sleep_ms(rest)
                self._same_run(run)
                return

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

    def error_counters(self) -> ErrorCounters | None:
        """The controller's transmit and receive error counters as it last reported them, None
        where the backend cannot say (the software buses, PCAN, the CAN bridge). On SocketCAN and
        Vector they move only while the channel is read, as health() does. From the thread that
        uses the channel."""
        return error_counters_of(self._handle())

    def close(self) -> None:
        """Lets the handle go; a wait in progress on another thread ends within 20 ms. Closing
        twice is nothing."""
        lib = _lib.lib()
        with _lib.state_lock:
            h, self._h = self._h, None
            try:
                if h is not None:
                    _lib.check(lib.bb_bus_close(h))
            finally:  # after the close: a receive still inside it keeps its frame in the old table
                self._latest = {}

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc: object) -> Literal[False]:
        self.close()
        return False

    def __del__(self) -> None:
        # an unclosed bus lets its handle go at the next open (_orphans): nothing is called into
        # here, since this may run between another call and its error
        try:
            if self._h is not None:
                _orphans.append(("bb_bus_close", self._h))
        except Exception:
            pass

    def __repr__(self) -> str:
        return f"<Bus {self.name}>"


class Channel(Bus):
    """One enabled row of the project. Its bus handle is opened on first use and is the one send,
    recv, health and the event loop all use, so what this channel sends is never heard back. It
    belongs to its project: after another project's load it refuses, rather than reach whatever
    row now has its index, and a reload of its own project keeps it if its row is still there.
    Native state calls (open, close) run under _lib.state_lock, so threads may share a project."""
    name: str

    def __init__(self, project: "Project", index: int, name: str, gen: int) -> None:
        self._project, self._index, self.name, self._gen = project, index, name, gen
        self._h = None
        self._latest = {}  # the newest frame read per (id, ext), where the library keeps no view
        self._watch = None  # the handle whose newest-frame view the library keeps (bb_bus_watch)
        self._messages, self._messages_run = None, None
        self._uds = weakref.WeakSet()  # the UDS clients and ISO-TP channels on this row, let go with its handle
        self._j1939 = None  # its J1939Listener, once asked for: every handle it opens then listens
        self._nm = None  # its NmListener, once asked for: every handle it opens then reads by it

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
        """"can", "doip", "someip" or "lin": only a CAN row has frames to send and receive (a LIN row's are `net.lin`'s)."""
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
                h = _lib.check(lib.bb_bus_open(lib.bb_channel_iface(self._index)))
                try:  # its frames judged by this row's E2E (Frame.e2e), and read as J1939 where the
                    # row's wire says so (a j1939: tick, a database declaring it) or a listener was asked for
                    _lib.check(lib.bb_e2e_attach(h, self._index))
                    # and what it sends stating no format in the row's own (a canfd row's FD on a
                    # wire a can row also names, which declares nothing)
                    _lib.check(lib.bb_framing_attach(h, self._index))
                    _lib.check(lib.bb_j1939_attach(h, self._index, int(self._j1939 is not None)))
                    if self._j1939 is not None:  # and answering where it was told to
                        self._j1939._answering(h)
                    # and its NM reading from its first frame: a stated range, else the wire's own
                    # (none is no reading: NM is a reader beside the channel, never a refusal of it)
                    if self._nm is not None and self._nm.explicit is not None:
                        self._nm._attach(h)
                    else:
                        _lib.check(lib.bb_nm_attach(h, self._index))
                        if self._nm is not None:
                            self._nm._h = h
                except BloblyError:
                    lib.bb_bus_close(h)
                    raise
                self._watched(h)  # its newest frame per id kept current by the library (latest)
                self._h = h
            return self._h

    def send_cyclic(self, id: int, data: ByteData = b"", period_ms: int = 100, *, ext: bool = False,
                    fd: bool = False, brs: bool = False,
                    format: FrameFormat | None = None) -> CyclicSender:
        """Sends a frame every period_ms in the background, the first at once, until the sender's
        stop() or the project's (a CyclicSender; `with` stops it at the end of the block). It goes
        out on a bus handle of the sender's own, so this channel's handle hears it as another
        node's frame. fd/brs/format as send() reads them. While the project is started."""
        f = _bb_frame(self.name, id, data, ext, fd, brs, format=format)
        with _lib.state_lock:
            return _start_raw(self, f, _period(period_ms))

    def expect_signal(self, message: "Message | str", signal: "Signal | str", want: object,
                      timeout_ms: float = 1000, *, e2e: bool = False) -> tuple[Frame, float | bytes]:
        """The first frame of `message` whose decoded `signal` matches `want`, and that value,
        waited for at most timeout_ms in all; blobly.Timeout when none came, its message saying
        what the signal was instead.

        `message` is a Message of this channel or its name, and its frames are those of its id AND
        kind. `signal` is a signal of it, or its name. `want` is a callable, a predicate on the
        decoded physical value, or a value compared with ==: decoded values are floats carrying
        the rounding of raw x factor + offset, so a value a binary fraction cannot hold (0.1 steps)
        wants pytest.approx(0.3) or a predicate; a byte signal (Signal.kind "bytes") decodes to
        bytes, so its `want` is bytes or a predicate. timeout_ms is one deadline for the whole wait, as
        expect's. With e2e=True every frame of `message` read while waiting must pass its E2E
        check: blobly.E2eError at the first that does not, as expect's.

        Every frame read while waiting is consumed, the ones that did not match included: a later
        recv or expect gets the frame after it."""
        __tracebackhide__ = True  # a pytest failure points at the test's line, not this one
        deadline = _deadline("expect_signal", timeout_ms)  # what the lookups below take is spent
        with _lib.state_lock:  # the message and signal of one run, which the wait then holds to
            msg = self._own("expect_signal", message)
            key = self._frame_key("expect_signal", msg, None)
            sig = self._signal_of("expect_signal", msg, signal)  # refused now, not after the wait
            run = _lib.state["run"]
        name = sig.name
        if sig.kind == "bytes":
            if not callable(want) and not isinstance(want, (bytes, bytearray)):
                raise TypeError(f"expect_signal: {name} decodes to bytes, so want is bytes or a predicate, "
                                f"not {want!r}")
            want = bytes(want) if isinstance(want, bytearray) else want
        elif want is None or isinstance(want, (str, bytes, bytearray)):
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
            if e2e:
                _passed(self.name, f)
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

    def value(self, message: "Message | str", signal: "Signal | str") -> float | None:
        """`signal`'s decoded physical value in the newest frame of `message` (latest's answer,
        current at the call); None before the first frame of it, or
        where that frame does not carry the signal (a multiplexed one its switch does not
        select). `message` and `signal` as expect_signal's. latest(message).t_ms says how old
        the value is."""
        with _lib.state_lock:
            msg = self._own("value", message)
            sig = self._signal_of("value", msg, signal)
            run = _lib.state["run"]
        f = self.latest(msg)
        if f is None:
            return None
        got = self._decode(f, run)
        if got is None or got[0] is not msg:
            return None
        return next((v for s, v in got[1] if s is sig), None)

    def _signal_of(self, who, msg, signal):
        """A Signal of `msg` in this run: one of msg.signals, or its name. Under the state lock."""
        if isinstance(signal, str):
            sig = msg.signals[signal]
        elif isinstance(signal, Signal):
            sig = signal
        else:
            raise TypeError(f"{who}: a signal is a Signal or its name, not {signal!r}")
        # the Signal itself, not its name: two signals of one name are two signals
        if not any(s is sig for s in msg.signals):
            raise ValueError(f"{who}: that {sig.name} is not a signal of {msg.name} in this "
                             f"run; take it from {msg.name}.signals, or name it")
        return sig

    def _frame_key(self, who, id, ext):
        """(id, ext) a wait matches: Bus's, or a Message's own."""
        if isinstance(id, Message):
            if ext is not None:
                raise TypeError(f"{who}: a Message carries its own kind; leave ext out")
            msg = self._own(who, id)
            return super()._frame_key(who, msg.id, msg.ext, f" (its database's {msg.name})")
        return super()._frame_key(who, id, ext)

    def _message_note(self):
        return f" or a Message of {self.name}"

    def _run(self):
        return _lib.state["run"]

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

    def _same_run(self, run):
        if _lib.state["run"] != run:
            raise BloblyError(f"{self.name}: the project was stopped or restarted during the wait",
                              _lib.BB_ERR_STATE)

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

    def decode(self, frame: Frame) -> dict[str, float | bytes] | None:
        """{signal: physical value} for what `frame` says in this row's databases — the message
        of its id and kind (else, for an extended frame, one of its J1939 PGN), each signal it
        carries (a multiplexed signal its switch does not select is left out, and so is one whose
        bits a short payload does not all hold, where a Lua script's decode() reads them as 0);
        a byte signal (Signal.kind "bytes") its bytes in payload order, and a signal wider than 64
        bits that is not one left out; None for a frame of no message, or a remote frame."""
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
            out = []
            for i, s in enumerate(msg.signals):
                v = values[i] if active[i] else None
                if v is not None and s.kind == "bytes":
                    v = _lib.bytes_of(lib.bb_decode_bytes, self._index, ctypes.byref(f), m.value, i)
                out.append((s, v))
            return msg, out

    def j1939(self, *, address: int | None = None) -> J1939Listener:
        """This channel's J1939 reading (J1939Listener): multi-packet messages rejoined from the
        transport protocol (BAM, RTS/CTS) and decoded by PGN, their faults, and the address
        directory, from the frames this channel's handle reads. Nothing decides a bus IS J1939, so
        a row reads it from its handle's first frame where its wire says so — a row on it ticked
        `j1939:`, or with a database declaring J1939 (VFrameFormat J1939PG) — and any other CAN row
        from this call on.
        It claims no address. With `address` (0x00..0xFD) it answers RTS/CTS connections aimed at
        that address as the node holding it (J1939Listener.answer), as the channel is read."""
        with _lib.state_lock:
            if self._j1939 is None:
                self._j1939 = J1939Listener(self)
            if self._h is not None:  # the handle already open listens from now on
                self._j1939._handle()
        if address is not None:
            self._j1939.answer(address)
        return self._j1939

    def nm(self, lo: int | None = None, hi: int | None = None, *, ext: bool = False,
           timeout_ms: int = 300) -> NmListener:
        """This channel's NM reading (NmListener): who reports in on its NM cluster and who keeps
        the network awake, from the frames this channel's handle reads. With no range, by its
        wire's configuration, the Network Management panel's rule (a system.toml bus named like a
        row on the wire, else the wire's ARXML NM-PDU frames, else a row's own `nm:`), read from
        the handle's first frame; Refused where the wire has none, since nothing guesses a frame
        is NM. With `lo` and `hi`, the inclusive id range the script states (29-bit where hi is
        past 0x7FF, or with ext) and its timeout_ms, naming no node, and a new reading from this
        call. While the project is started. The reading sends nothing; its release() and
        request() silence and wake the nodes the row simulates."""
        from .nm import _explicit
        cfg = None
        if lo is not None or hi is not None:
            if lo is None or hi is None:
                raise TypeError("nm: a range is lo and hi together")
            cfg = _explicit("nm", lo, hi, ext, timeout_ms)
        with _lib.state_lock:
            if cfg is None and self._nm is not None and self._nm.explicit is None:
                listener = self._nm
            else:
                listener = NmListener(self, cfg)
            h = self._handle()
            listener._attach(h)
            self._nm = listener
        return listener

    def uds(self, tx: int | None = None, rx: int | None = None, *, timeout_ms: int | None = None,
            p2_star_ms: int | None = None, margin_ms: int | None = None,
            pending_budget_ms: int | None = None, keep_alive_ms: int | None = None,
            padding: int | None = 0, block_size: int = 0, stmin_ms: float = 0, tx_dl: int = 8,
            format: FrameFormat | None = None) -> UdsClient:
        """A UdsClient on this row, by the rule the Lua uds.open opens by, while the project is
        started. On a CAN row UDS requests go out on CAN id `tx` and answers come back on `rx`:
        None is the default pair 0x7E0 / 0x7E8, 0 is an id like any other, and either id past
        0x7FF makes both 29-bit. On a DoIP row they ride a TCP connection to its entity, from the
        row's tester_address to its ecu_address, so tx and rx are refused; RoutingDenied when the
        entity will not route the tester, and one client at a time holds the row's connection
        (ISO 13400-2: one tester address, one connection) — a second is refused while it is open.
        The timing keywords state the client's waits (UdsClient.timeout_ms ...); None keeps the
        engine's. keep_alive_ms starts its keep-alive (UdsClient.keep_alive). On a CAN row padding,
        block_size, stmin_ms, tx_dl and format are its ISO-TP channel's, as isotp's; refused on a
        DoIP row."""
        return UdsClient(self, tx, rx, timeout_ms=timeout_ms, p2_star_ms=p2_star_ms, margin_ms=margin_ms,
                         pending_budget_ms=pending_budget_ms, keep_alive_ms=keep_alive_ms, padding=padding,
                         block_size=block_size, stmin_ms=stmin_ms, tx_dl=tx_dl, format=format)

    def isotp(self, tx: int, rx: int, *, padding: int | None = 0, block_size: int = 0,
              stmin_ms: float = 0, tx_dl: int = 8, format: FrameFormat | None = None) -> IsoTp:
        """A raw ISO-TP channel on this CAN row while the project is started: whole messages sent on
        CAN id `tx` and received on `rx`, either past 0x7FF making both 29-bit, with no UDS on top.
        Both ids are given: there is no default pair. Refused on a DoIP or SOME/IP row. padding is
        the byte frames are padded to 8 bytes with (0x00), None for frames as long as their content;
        block_size (0 .. 255) and stmin_ms (a whole 0 .. 127, or 0.1 .. 0.9) the Flow Control it
        answers a First Frame with — refused out of range before the channel opens. tx_dl (8, 12, 16,
        20, 24, 32, 48 or 64) is the length of the frames it sends in, above 8 CAN-FD (refused on a
        classic row unless format states fd), and format ("classic", "fd", "fd_brs"; None the row's
        declared format) is stated on every frame. Frames it receives are read at any length."""
        return IsoTp(self, tx, rx, padding=padding, block_size=block_size, stmin_ms=stmin_ms, tx_dl=tx_dl,
                     format=format)

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
            self._let_go_clients()
            h, self._h = self._h, None
            try:
                if h is not None:
                    _lib.check(lib.bb_bus_close(h))
            finally:  # after the close: a receive still inside it keeps its frame in the old table
                self._latest = {}

    def _let_go_clients(self) -> None:
        """Lets the connections of its UDS clients and ISO-TP channels go, the handle kept; their
        next use opens another."""
        with _lib.state_lock:
            _close_orphans()
            for c in list(self._uds):
                c._let_go()

    def _judge_afresh(self) -> None:
        """Gives the open handle a new E2E reader, the handle kept: the next frame of each message
        is judged on its CRC alone, as after an open, and no gap before it is a timeout."""
        h = self._handle()
        lib = _lib.lib()
        with _lib.state_lock:
            self._current()
            _lib.check(lib.bb_e2e_attach(h, self._index))

    def __repr__(self) -> str:
        return f"<Channel {self.name}>"


class _HasName(Protocol):
    name: str


_T = TypeVar("_T", bound=_HasName)


class Named(Generic[_T]):
    """Items by name: `c.X`, `c["X-1"]`, `c[0]` (by position), `"X" in c`, iteration in order, and
    dir() for completion. A name two items answer to is refused, and such items are reached by
    position. A name the collection itself has (`keys`, `_order`) is not an
    attribute of it: `c["keys"]` reaches that item."""
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
        own = set(dir(type(self))) | set(self.__dict__)  # what an attribute of that name reaches instead
        return [n for n, rows in self._by_name.items()
                if n.isidentifier() and len(rows) == 1 and n not in own] + ["keys"]

    def __contains__(self, key: object) -> bool:
        """A name an item has, or one of the items."""
        if isinstance(key, str):
            return key in self._by_name
        return key in self._order

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


# bb.h's enum bb_signal_kind, as Signal.kind reads it
_SIGNAL_KINDS = {0: "number", 1: "bytes", 2: "none"}


class Signal:
    """A signal of a message, as its database defines it. physical = raw * factor + offset, the
    raw value two's complement where `signed`; `byte_order` "little" (Intel) or "big" (Motorola),
    `start_bit` as the DBC numbers it; `minimum`/`maximum` the DBC's range (both 0 where it states
    none; encode does not apply it); `labels` the value table as decode's values name it,
    {physical value: text}, and `raw_labels` as the database keys it, {raw key: text} — the field's
    bits, two's complement for a signed signal; every entry is there, where two keys a double
    cannot tell apart (past 2**53) are one entry of `labels`. `start_raw` is the raw value a
    node sends before anything sets the signal (GenSigStartValue, else its default) as the field's
    bits, `start` the same physical — both None where the database states none; a simulated node
    and a generator send it for a signal nothing sets, encode does not. `kind` is what it reads as: "number"
    (1 .. 64 bits), "bytes" (wider, from a byte boundary and whole bytes long: decode and encode
    take bytes in payload order) or "none" (wider and not whole bytes: nothing is read or
    written)."""
    __slots__ = ("name", "start_bit", "length", "byte_order", "kind", "signed", "factor", "offset",
                 "minimum", "maximum", "unit", "multiplexor", "multiplexed", "mux_value", "labels",
                 "raw_labels", "start_raw", "start")
    name: str
    start_bit: int
    length: int
    byte_order: Literal["little", "big"]
    kind: Literal["number", "bytes", "none"]
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
    start_raw: int | None
    start: float | None

    def __repr__(self) -> str:
        unit = f" {self.unit!r}" if self.unit else ""
        return (f"<Signal {self.name} {self.start_bit}|{self.length} {self.byte_order} "
                f"x{self.factor:g}{self.offset:+g} [{self.minimum:g}..{self.maximum:g}]{unit}>")


class Message:
    """A message of a row's databases: `id`, `ext`, `dlc`, `j1939` (the database declares it),
    `format` (the frame format its database states: "classic", "fd", "fd_brs", or None where it
    states none), `signals`; encode / send by signal name. When its database says a node sends
    it: `cycle_ms` (GenMsgCycleTime, else its default), `send_type` (GenMsgSendType: "cyclic",
    "event", "mixed", "none" or "other", None where unstated), `cycle_fast_ms`, `repetitions`,
    `delay_ms` and `start_delay_ms` — each 0 where the file states none, so
    `msg.send_cyclic(msg.cycle_ms)` sends it on the file's period. It belongs to the run that
    listed it: after a stop
    and a start it goes on working while its row's database still has it at its position, and
    refuses otherwise."""
    name: str
    id: int
    ext: bool
    dlc: int
    j1939: bool
    format: FrameFormat | None
    cycle_ms: int
    send_type: Literal["cyclic", "event", "mixed", "none", "other"] | None
    cycle_fast_ms: int
    repetitions: int
    delay_ms: int
    start_delay_ms: int
    channel: Channel

    def __init__(self, channel: Channel, index: int, name: str) -> None:
        self.channel, self._index, self.name = channel, index, name
        self._signals = None

    def _fill(self, info, run):
        self.id, self.ext, self.dlc, self.j1939 = info.id, bool(info.ext), info.dlc, bool(info.j1939)
        self.format = _FORMAT_NAMES.get(info.format)
        self.cycle_ms, self.cycle_fast_ms = info.cycle_ms, info.cycle_fast_ms
        self.repetitions, self.delay_ms = info.repetitions, info.delay_ms
        self.start_delay_ms = info.start_delay_ms
        self.send_type = _lib.SEND_TYPES.get(info.send_type)  # type: ignore[assignment]
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
                    s.kind = _SIGNAL_KINDS.get(info.kind, "none")
                    s.signed, s.factor, s.offset = bool(info.is_signed), info.factor, info.offset
                    s.minimum, s.maximum = info.minimum, info.maximum
                    s.multiplexor, s.multiplexed = bool(info.multiplexor), bool(info.multiplexed)
                    s.mux_value = info.mux_value
                    s.start_raw = info.start_raw if info.has_start else None
                    s.start = info.start if info.has_start else None
                    s.labels, s.raw_labels = {}, {}
                    raw, value = ctypes.c_uint64(), ctypes.c_double()
                    for k in range(info.labels):
                        text = _lib.string(lib.bb_signal_label, row, m, i, k, ctypes.byref(raw), ctypes.byref(value))
                        s.raw_labels[raw.value] = text
                        s.labels.setdefault(value.value, text)
                    rows.append(s)
                self._signals = Signals(rows)
            return self._signals

    def encode(self, /, **signals: float | bytes) -> Frame:
        """The Frame this message sends with the named signals at these physical values and every
        other at raw 0, as a Lua script's bus.send_message encodes it: a name the message does not
        have is refused, and so is a number for a signal wider than 64 bits, which carries none; a
        byte signal (Signal.kind "bytes") takes bytes, length / 8 of them in payload order, and
        only it does; a value past what the signal's width holds is clamped to the nearer end.
        fd/brs are left unset, so a send takes its channel's declared format. Its E2E is not stamped:
        send() stamps it, and channel.send(f.id, f.data, ext=f.ext) sends an encoded frame as it is.
        A J1939 message may be longer than a CAN frame (up to 1785 bytes): send() sends it as a BAM."""
        p = self._encoded(signals)
        return Frame(p.id, bytes(memoryview(p.data)[:p.len]), bool(p.ext))

    def _encoded(self, signals):
        """encode's bb_payload."""
        names = []
        values = []
        spans = []  # (name, bytes) for the byte signals
        for k, v in signals.items():
            if "\0" in k:
                raise ValueError(f"{self.name}: a signal name cannot carry a NUL: C would read it cut short")
            if isinstance(v, (bytes, bytearray, memoryview)):
                spans.append((k.encode(), bytes(v)))
                continue
            names.append(k.encode())
            if not isinstance(v, numbers.Real):
                raise TypeError(f"{self.name}.{k}: a signal's value is a number or bytes, not {v!r}")
            values.append(float(v))
        n = len(names)
        p = _lib.BbPayload()
        lib = _lib.lib()
        with _lib.state_lock:
            self._live()
            _lib.check(lib.bb_encode_payload(self.channel._index, self._index, n, (ctypes.c_char_p * n)(*names),
                                             (ctypes.c_double * n)(*values), ctypes.byref(p)))
            if spans:
                if p.len > 64:
                    raise _lib.Refused(f"{self.name}: a byte signal is written into a message of at most "
                                       f"64 bytes, not {p.len}")
                f = _lib.BbFrame(id=p.id, ext=p.ext, len=p.len)
                ctypes.memmove(f.data, p.data, p.len)
                for k, b in spans:
                    _lib.check(lib.bb_encode_bytes(self.channel._index, self._index, k, b, len(b), ctypes.byref(f)))
                ctypes.memmove(p.data, f.data, p.len)
        return p

    def send(self, /, *, format: FrameFormat | None = None, timeout_ms: int | None = None,
             **signals: float | bytes) -> Frame:
        """Encodes this message (encode), stamps the E2E its database declares — the counter its
        next of this run's sends by name on the channel, from 0, then the CRC, over what the
        signals gave them, as a simulated sender stamps it — and sends it on its channel; returns
        the Frame sent. A declaration that cannot be applied raises Refused rather than go out
        unprotected; a send that fails after its stamp has used its counter, as a frame lost on
        the wire does. It goes out in `format` where given, as Channel.send's states one ("classic",
        "fd", "fd_brs"; a classic frame of more than 8 bytes refused), else in the format its
        database states (`self.format`), else in its channel's declared format — the returned
        Frame's fd/brs are what was stated.
        To send it unstamped (a corrupted frame on purpose), encode it and send the frame:
        channel.send(f.id, f.data, ext=f.ext). Encoded, stamped and the channel's handle taken
        under one hold of the state lock, so a stop and start on another thread cannot put this
        run's encoding on the next run's wire.
        A J1939 message (`j1939`) longer than 8 bytes going out classic is sent as the transport
        protocol's broadcast, a TP.CM BAM and its TP.DT packets 50 ms apart from the message's
        source address, and the call returns once the last is sent (50 ms a packet), after any
        other BAM this process is sending from that address on the wire; Ctrl-C ends it between
        packets, the rest unsent. One to a single node (a PDU1 group whose destination is not
        0xFF) is an RTS/CTS connection: the RTS, the packets each CTS clears, and the call returns
        once the node has acknowledged the message — each of its answers (a CTS, the
        acknowledgement) waited for `timeout_ms` (None: J1939-21's T3, 1250 ms; a hold waits 1050 ms
        for the next CTS), blobly.Timeout when one does not come (the connection aborted), Refused
        when the node aborts it; Ctrl-C aborts it. The Frame returned is the message's."""
        if timeout_ms is not None and (isinstance(timeout_ms, bool) or not isinstance(timeout_ms, int)):
            raise TypeError(f"{self.name}.send: timeout_ms is an integer number of milliseconds, not {timeout_ms!r}")
        if timeout_ms is not None and not 1 <= timeout_ms <= 3_600_000:
            raise ValueError(f"{self.name}.send: timeout_ms is 1 .. 3600000, not {timeout_ms}")
        tmo = timeout_ms or 0
        lib = _lib.lib()
        with _lib.state_lock:
            p = self._encoded(signals)  # its format the declared one (bb_encode_payload)
            if format is not None:
                p.format = _format(f"{self.name}.send", format)
            if p.format == _lib.FORMATS["classic"] and p.len > 8 and not self.j1939:  # before the stamp uses a counter
                raise _lib.Refused(f"{self.channel.name}: a classic frame carries at most 8 bytes, "
                                   f"{self.name} has {p.len} — choose FD")
            h = self.channel._handle()  # first: a channel that will not open uses no counter
            row, m = self.channel._index, self._index
            _lib.check(lib.bb_e2e_stamp_payload(row, m, ctypes.byref(p)))
        if self.j1939 and p.len > 8 and threading.current_thread() is threading.main_thread():
            # a BAM takes up to 12.75 s, a connection its answers: on a thread of its own, so
            # Ctrl-C cancels it (events._on_thread)
            _on_thread(lambda: _lib.check(lib.bb_message_send(h, row, m, ctypes.byref(p), tmo)), "blobly-send",
                       lambda: lib.bb_message_cancel(h))
        else:
            _lib.check(lib.bb_message_send(h, row, m, ctypes.byref(p), tmo))
        # the Frame returned says what was stated, or declared
        fd = p.format not in (0, _lib.FORMATS["classic"])
        brs = p.format == _lib.FORMATS["fd_brs"]
        return Frame(p.id, bytes(memoryview(p.data)[:p.len]), bool(p.ext), fd, brs)

    def send_cyclic(self, period_ms: int, /, *, e2e: bool = True, format: FrameFormat | None = None,
                    **signals: float) -> CyclicSender:
        """Sends this message every period_ms in the background, the first at once, encoded from
        the named signals (encode's rule) and its declared E2E stamped on every frame unless `e2e`
        is False — the counter the sender's own, from 0: a CyclicSender, which update(**signals)
        changes. In `format` as send() takes it, else the format its database states, else its
        channel's. Until its stop() or the project's; `with` stops it at the end of the block."""
        code = _format(f"{self.name}.send_cyclic", format)
        with _lib.state_lock:
            return _start_message(self, _period(period_ms), e2e, signals, code)

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


def _override_text(interfaces: Mapping[str, str]) -> str:
    """The overrides as bb_load_with reads them, `NAME=IFACE` a line; a pair that cannot be
    written that way is refused (TypeError, ValueError)."""
    out = []
    for name, iface in interfaces.items():
        if not isinstance(name, str) or not isinstance(iface, str):
            raise TypeError(f"interfaces: {name!r}: {iface!r} is not a row name and an interface string")
        if "=" in name or any(c in name + iface for c in "\0\r\n"):
            raise ValueError(f"interfaces: {name!r}: {iface!r}: a row name cannot carry '=', and neither "
                             "can carry a NUL or a line break")
        out.append(f"{name}={iface}\n")
    return "".join(out)


def _notes(lib) -> list[str]:
    """The library's notes of its last load (bb_note)."""
    return [_lib.text(lib.bb_note(i)) for i in range(lib.bb_note_count())]


class Project(EventLoop[Channel | str], Faults, Replays):
    """A .blobnet project in this process. `with Project(path) as net:` loads and starts it — its
    simulated ECUs, UDS servers, generators and DoIP entities run until the block ends. One run per
    process. Load, start and stop are serialised (_lib.state_lock), so threads may share a project;
    a channel is used from one thread at a time.
    Faults (fault, clear_fault) make its simulated ECUs misbehave on purpose; `generators` fires and
    cycles its generators; replay and record play a recording onto its channels and record them to a
    file.
    `interfaces` attaches rows elsewhere than the file says, by row name — {"BusA": "inproc:BusA"},
    an interface string without a rate or a mode (not `Channel.iface`'s `...@500000`): the row keeps its
    bitrate, framing and listen_only. Applied at every load before anything is checked or opened;
    a name no row has, or an interface of another kind than the row's, refuses the load.
    `strict=True` refuses a load (Refused, listing every line) when the file carries what this build
    does not read: a key no section of the .blobnet lists (in a file of a newer schema, noted, not
    refused) or a record of one of its DBCs the reader does not take. `notes` is what the last load
    said, either way."""
    path: str | bytes
    started: bool
    interfaces: dict[str, str]
    strict: bool

    def __init__(self, path: "str | bytes | os.PathLike[str] | os.PathLike[bytes]",
                 interfaces: Mapping[str, str] | None = None, strict: bool = False) -> None:
        super().__init__()
        p = os.fspath(path)
        if (b"\0" if isinstance(p, bytes) else "\0") in p:
            raise ValueError("a project path cannot carry a NUL: C would read it cut short")
        self.interfaces = dict(interfaces or {})
        _override_text(self.interfaces)
        self.strict = bool(strict)
        self._notes: list[str] = []
        self.path = os.path.abspath(path)
        self.started = False
        self._channels = None
        self._gen = None  # which load of the library is this project's
        self._rr = 0
        self._gens, self._gens_run = None, None  # the generators, as the run of _gens_run lists them
        self._nodes, self._nodes_run = None, None  # the system model's nodes, as the run of _nodes_run has them
        self._senders: list[CyclicSender] = []  # the background senders this run started
        self._lin, self._lin_run = None, None  # the run's LIN buses, as the run of _lin_run has them

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
            pairs = _override_text(self.interfaces)
            # the path in the filesystem's bytes, not UTF-8
            rc = lib.bb_load_flags(os.fsencode(self.path), pairs.encode(),
                                   _lib.BB_LOAD_STRICT if self.strict else 0)
            # the error first, since a note call clears it
            e = _lib.error(rc) if rc < 0 else None
            # this load's notes, a refused one's too: a strict refusal's lines, else none
            self._notes = _notes(lib)
            if e is not None:
                if self.strict and isinstance(e, Refused) and self._notes:
                    # every line the load refused: bb_last_error may be cut short
                    raise Refused(f"{self.path}: a strict load refuses what this build does not read:\n  "
                                  + "\n  ".join(self._notes), rc) from None
                raise e
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

    @property
    def notes(self) -> list[str]:
        """What the last load of this project said about the file, one line each: its unknown keys
        (`unknown key `cycle_msec` in channel "CAN1" / generator "G" (known: ...)`), references that
        resolve only from the working directory, and per DBC the records it did not
        read (`u.dbc: not read: SIG_VALTYPE_ × 3, attribute "GenSigSendType" × 40`). After a strict
        load's refusal, the lines it refused; after any other refusal, none. Empty before the first
        load."""
        return list(self._notes)

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
            # a sender an earlier stop left inside a send: its final status, read before bb_start
            # lets its handle go (bb_start refuses until it is out)
            if self._senders and lib.bb_wait_released(0) == 0:
                for c in list(self._senders):
                    c.stop()
            _lib.check(lib.bb_start())
            st["run"] += 1  # the rows' databases are this run's from here
            self.started = True
        return self

    def wait_ready(self, timeout_ms: float | None = 5000) -> None:
        """Waits until none of the run's loops that open a bus is still opening: each row's
        simulated nodes, each UDS node, the default UDS server, and each cyclic generator (up once
        the bus took its first frame; a generator that opens at its first fire is not waited for).
        start() returns before they have opened. Raises BloblyError naming every loop that failed
        when none is still opening, Timeout naming the ones still opening (and those that failed)
        when timeout_ms passes (None waits for ever). Ctrl-C ends the wait within 100 ms."""
        lib = _lib.lib()

        def ready(part):  # True when every loop is up, None while some are opening
            with _lib.state_lock:
                if not self.started:
                    raise BloblyError("the project is not started", _lib.BB_ERR_STATE)
                run = _lib.state["run"]
            # the wait outside the lock, as wait_released's: a stop meanwhile ends it as BB_ERR_STATE
            rc = lib.bb_wait_ready(part)
            with _lib.state_lock:  # a stop and a start meanwhile: the wait was another run's
                if _lib.state["run"] != run:
                    raise BloblyError("the run stopped", _lib.BB_ERR_STATE)
            if rc == 0:
                return True
            if rc == _lib.BB_ERR_TIMEOUT and part != 0:
                return None
            e = _lib.error(rc)
            raise BloblyError(str(e), rc) if rc == _lib.BB_ERR else e
        # a last look once the wait is over, which raises naming what is still opening
        if _sliced(ready, _ms(timeout_ms)) is None:
            ready(0)

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
            failed = self._stop_recordings()  # said once the project is stopped
            self.started = False
            _lib.state["run"] += 1  # the run's databases end with it
            # False: a loop outlived the stop's bound and still holds the process; a start refuses
            # until blobly.wait_released says it has let go
            free = _lib.check(lib.bb_stop()) != _lib.BB_RELEASING
            for c in list(self._senders):  # ended by the run's stop: what each did is kept
                c.stop()  # answered at once: the run's stop waited for them
        for e in failed:
            warnings.warn(f"a recording left running failed: {e}", RuntimeWarning, stacklevel=2)
        return free

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
        NodeClient on zone_a, its DIDs `net.nodes.zone_a.dids`: the system.toml's nodes, then those
        the rows name by ODX (a CAN row's `diagnostics:`), so a project with no system.toml (system
        is None) still has the latter. Empty when neither describes a node. BloblyError (code -3)
        when the project is not started."""
        with _lib.state_lock:
            if not self.started:
                raise BloblyError("the project is not started: its system model is the run's", _lib.BB_ERR_STATE)
            if self._nodes_run != _lib.state["run"]:
                from .nodes import listed  # nodes.py builds on this module's Named
                self._nodes = listed(self, list(self._nodes) if self._nodes is not None else None)
                self._nodes_run = _lib.state["run"]
            return self._nodes

    @property
    def lin(self) -> "LinBuses":
        """The run's LIN buses (blobly.LinBuses), the project's LIN rows: `net.lin.BODY` is a
        LinBus. Empty for a project with none. BloblyError (code -3) when the
        project is not started."""
        with _lib.state_lock:
            if not self.started:
                raise BloblyError("the project is not started: its LIN buses are the run's", _lib.BB_ERR_STATE)
            if self._lin_run != _lib.state["run"]:
                from .lin import listed as listed_lin  # lin.py builds on this module's Named
                self._lin = listed_lin(self, list(self._lin) if self._lin is not None else None)
                self._lin_run = _lib.state["run"]
            return self._lin

    def _stop_senders(self) -> None:
        """Stops every background sender the run started (the pytest plugin, after a test)."""
        with _lib.state_lock:
            for c in list(self._senders):
                c.stop()

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

    def _open(self):
        # the channels whose handle is open: each a CAN row of this load (no other kind opens one)
        return [c for c in self._channels or [] if c._h is not None]

    def _health_needs_reader(self, c):
        return c._health_needs_reader()

    def _wait_frame(self, channels, timeout_ms):
        got, self._rr = wait_on(channels, timeout_ms, self._rr, monotonic_ms, sleep_ms)
        return got

    def __repr__(self) -> str:
        return f"<Project {self.path}{' started' if self.started else ''}>"
