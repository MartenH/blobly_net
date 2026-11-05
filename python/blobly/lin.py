"""lin — LIN through libblobly (blobly/lin, docs/lin.md): a project's LIN buses (Project.lin) and a
LIN bus by its address (blobly.lin.open). A LIN bus is not a Channel: it is the project's `lin:`
list, its frames LinFrames, decoded through its LDF.

    import blobly
    with blobly.Project("projects/lin-demo.blobnet") as net:
        body = net.lin.BODY
        f = body.expect("CEM_Frm2", 500)
        print(f.signals)          # {'CabinTemp': 20.0, 'VehicleSpeed': 15.625}
        body.set("IntTest", "passed")"""
import collections
import ctypes
import math
import os
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Literal, Self

from . import _lib
from ._lib import BloblyError, Timeout
from .events import SLICE_MS, _sliced, monotonic_ms, sleep_ms
from .metrics import BusDiagnostics
from .project import Named, _deadline, _ms
from .uds import _close_orphans, _orphans

if TYPE_CHECKING:
    from .project import Project

__all__ = ["open"]

# a LIN bus's role, by the name the project file and the Lua lin.open take
Role = Literal["master", "slave", "monitor"]


@dataclass(frozen=True)
class LinFrame:
    """One frame a LIN bus carried, or a bus event. `id` 0..63 and `pid` the protected identifier
    read (0 where none was); `data` the response's bytes (for one cut short, every byte read);
    `checksum` the checksum byte read and `model` its kind, "classic" or "enhanced"; `errs` what
    went wrong, by name ("sync", "parity", "checksum", "framing", "short", "no_response",
    "collision", "bit", "long"; empty for an error-free frame); `event` "frame", "wakeup" (a
    pulse, with no id) or "sleep" (the go-to-sleep command); `origin` the trace's origin column:
    "TX-S" sent by this app's simulated node, "TX" by its tester, "RX" by a node outside it.

    Decoded through the bus's LDF: `name` the LDF's frame name ("" where it names none),
    `signals` {signal: value} — the physical value where the signal's encoding has a physical
    range for it, else its logical value's or an ascii / bcd array's text, else a byte array's
    bytes, else the raw value — and `raw` {signal: raw value} for the scalars; both empty for a
    frame with an error flag. `t_ms` is when it was read, on blobly.now_ms()'s clock. A frame's
    value (==, hash) is what it carries: id, pid, data, errs, event, origin, checksum and model."""
    id: int
    pid: int
    data: bytes
    errs: frozenset[str]
    event: str
    origin: str
    checksum: int
    model: str
    name: str = field(default="", compare=False)
    signals: dict[str, float | int | str | bytes] = field(default_factory=dict, compare=False)
    raw: dict[str, int] = field(default_factory=dict, compare=False)
    t_ms: float = field(default=0.0, compare=False)


@dataclass(frozen=True)
class LinIdStatus:
    """What a LIN bus has seen of one frame id (LinStatus.frames): its LDF `name` ("" none),
    frames seen (`count`), those with an error flag (`errors`), and `cadence_ms`, the time between
    its last two error-free frames (None before two)."""
    id: int
    name: str
    count: int
    errors: int
    cadence_ms: float | None


@dataclass(frozen=True)
class LinStatus:
    """A LIN bus as it stands (LinBus.status): its `name`, `address` and `role`; `state` "active",
    "sleep" or "short" (hardware only); `schedule` the table its master runs (None for none) and
    the scheduler's `schedule_running`, `schedule_sent` (headers), `schedule_failed` (headers the
    bus refused) and `schedule_late` (slots that started late, the grid taken up from them);
    `load` the percent of bus time frames took in the last whole second; `dropped` the frames any
    reader's queue on the bus lost; `frames` {id: LinIdStatus} in id order; `notes` what the bus
    did not take as written (the LDF's notes, slots a schedule does not send)."""
    name: str
    address: str
    role: str
    state: str
    schedule: str | None
    schedule_running: bool
    schedule_sent: int
    schedule_failed: int
    schedule_late: int
    load: float
    dropped: int
    frames: dict[int, LinIdStatus]
    notes: list[str]


def _said(f: LinFrame) -> str:
    """How a frame is named in what expect says came instead (the Lua lin.expect's words)."""
    if f.event == "wakeup":
        return "wakeup"
    key = f"0x{f.id:02X}" + (f" {f.name}" if f.name else "")
    if f.event == "sleep":
        return key + "/sleep"
    if f.errs:
        return key + "/" + "+".join(n for n in _lib.LIN_ERRS if n in f.errs)
    return key


def _num(x: float) -> str:
    return str(int(x)) if float(x).is_integer() else repr(x)


def _text_arg(who: str, what: str, v: object) -> bytes:
    if not isinstance(v, str):
        raise TypeError(f"{who}: {what} is a string, not {v!r}")
    if "\0" in v:
        raise ValueError(f"{who}: {what} cannot carry a NUL: C would read it cut short")
    return v.encode()


class LinBus:
    """A LIN bus: one of the project's (Project.lin, a tap on the run's bus, its role, LDF and rate
    the project file's) or one of the script's own on an address (blobly.lin.open, stopped by
    close). It reads every frame the bus carries from the moment it first reads — its own included,
    told apart by `origin` — and controls the bus as its role allows: a monitor sends nothing, a
    slave no header and no go-to-sleep (Refused, nothing sent).

    A project's bus belongs to its project's run: after a stop and a start it reads the new run's
    bus while the run has one of its name at its position. `with` closes it. One thread at a time
    uses it; close() from another thread ends a wait in progress there within 20 ms."""
    name: str
    address: str
    role: str
    ldf: str | None
    baud: int

    def __init__(self, project: "Project | None", index: int, name: str) -> None:
        self._project, self._index, self.name = project, index, name
        self.address, self.role, self.ldf, self.baud = "", "monitor", None, 0
        self._h: int | None = None
        self._hrun = None  # the run whose bus the handle taps
        self._closed = False

    def _fill(self) -> None:
        """The run's word on this bus (under _lib.state_lock)."""
        lib = _lib.lib()
        info = _lib.BbLinBus()
        _lib.check(lib.bb_lin_info(self._index, ctypes.byref(info)))
        self.address = _lib.string(lib.bb_lin_text, self._index, _lib.LIN_TEXT_ADDRESS)
        self.ldf = _lib.string(lib.bb_lin_text, self._index, _lib.LIN_TEXT_LDF) or None
        self.role = next((n for n, v in _lib.LIN_ROLES.items() if v == info.role), "monitor")
        self.baud = info.baud

    def _handle(self) -> int:
        h = self._h
        if h is not None and (self._project is None or self._hrun == _lib.state["run"]):
            return h
        with _lib.state_lock:
            _close_orphans()
            if self._closed:
                raise BloblyError(f"{self!r} is closed", _lib.BB_ERR_HANDLE)
            if self._project is None:  # a bus of its own is opened at once and closed for good
                if self._h is None:
                    raise BloblyError(f"{self!r} is closed", _lib.BB_ERR_HANDLE)
                return self._h
            run = _lib.state["run"]
            if self._h is not None and self._hrun == run:
                return self._h
            self._let_go()  # a tap on an earlier run's bus
            p = self._project
            if _lib.state["owner"] is not p or not p.started:
                raise BloblyError(f"{self.name}: the project is not started: its LIN buses are the run's",
                                  _lib.BB_ERR_STATE)
            lib = _lib.lib()
            n = _lib.check(lib.bb_lin_count())
            if self._index >= n or _lib.string(lib.bb_lin_text, self._index, _lib.LIN_TEXT_NAME) != self.name:
                raise BloblyError(f"{self.name}: this run has no LIN bus of that name at its position; take it "
                                  "from net.lin again", _lib.BB_ERR_STATE)
            h = _lib.check(lib.bb_lin_open(self._index, None, _lib.LIN_ROLE_PROJECT, None, 0))
            self._h, self._hrun = h, run
            return h

    def _let_go(self) -> None:
        h, self._h = self._h, None
        if h is not None:
            _lib.lib().bb_lin_close(h)  # a handle already gone is closed enough

    def close(self) -> None:
        """Lets the bus go: a bus of the script's own is stopped, and a later call refuses; a
        project's is untapped, and its next use taps the run's bus again, as `net.lin` keeps one
        object per bus. Closing twice is nothing."""
        with _lib.state_lock:
            _close_orphans()
            if self._project is None:
                self._closed = True
            self._let_go()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc: object) -> Literal[False]:
        self.close()
        return False

    def __del__(self) -> None:
        # let go at the next call that opens or closes a handle (uds._orphans): nothing is called
        # into here, since this may run between another call and its error
        try:
            if self._h is not None:
                _orphans.append(("bb_lin_close", self._h))
        except Exception:
            pass

    def _frame(self, h: int, f: _lib.BbLinFrame) -> LinFrame:
        """A received bb_lin_frame as a LinFrame, decoded through the bus's LDF."""
        lib = _lib.lib()
        n = ctypes.c_int()
        name, signals, raw = "", {}, {}
        if _lib.check(lib.bb_lin_decode(h, ctypes.byref(f), ctypes.byref(n))) == 0:
            name = _lib.string(lib.bb_lin_frame_name, h)
            s = _lib.BbLinSignal()
            for k in range(n.value):
                _lib.check(lib.bb_lin_signal_info(h, k, ctypes.byref(s)))
                sname = _lib.string(lib.bb_lin_signal_text, h, k, _lib.LIN_SIGNAL_NAME)
                text = _lib.string(lib.bb_lin_signal_text, h, k, _lib.LIN_SIGNAL_TEXT)
                if s.has_physical:
                    signals[sname] = s.physical
                elif text:
                    signals[sname] = text
                elif s.is_array:
                    signals[sname] = _lib.bytes_of(lib.bb_lin_signal_bytes, h, k)
                else:
                    signals[sname] = s.raw
                if not s.is_array:
                    raw[sname] = s.raw
        errs = frozenset(e for i, e in enumerate(_lib.LIN_ERRS) if f.errs & (1 << i))
        return LinFrame(f.id, f.pid, bytes(f.data[:f.len]), errs, _lib.LIN_EVENTS.get(f.event, "frame"),
                        _lib.LIN_ORIGINS.get(f.origin, "RX"), f.checksum, _lib.LIN_MODELS.get(f.model, "enhanced"),
                        name, signals, raw, _lib.ms_of(f.t_ns))

    def _receive(self, h: int, ms: int) -> LinFrame | None:
        f = _lib.BbLinFrame()
        if _lib.check(_lib.lib().bb_lin_recv(h, ms, ctypes.byref(f))) == _lib.BB_NONE:
            return None
        return self._frame(h, f)

    def recv(self, timeout_ms: float | None = 1000) -> LinFrame | None:
        """The next frame the bus carries, waiting at most timeout_ms (0 only looks; None: for ever);
        None when none came. Ctrl-C ends the wait within 100 ms."""
        ms = _ms(timeout_ms)
        h = self._handle()  # one handle for the whole wait: a close or stop meanwhile ends it
        return _sliced(lambda part: self._receive(h, part), ms)

    def _id_of(self, h: int, want: object) -> int:
        if isinstance(want, str):
            return _lib.check(_lib.lib().bb_lin_frame_id(h, _text_arg("expect", "a frame name", want)))
        if isinstance(want, bool) or not isinstance(want, int):
            raise TypeError(f"expect: a LIN frame is its id (an int) or its LDF name, not {want!r}")
        if not 0 <= want <= 0x3F:
            raise ValueError(f"expect: a LIN id is 0..63, not {want}")
        return want

    def _name_of(self, h: int, id: int) -> str:
        """The LDF's name for frame `id`, "" where it names none."""
        lib = _lib.lib()
        f = _lib.BbLinFrame(id=id)
        n = ctypes.c_int()
        if _lib.check(lib.bb_lin_decode(h, ctypes.byref(f), ctypes.byref(n))) != 0:
            return ""
        return _lib.string(lib.bb_lin_frame_name, h)

    def expect(self, frame: int | str, timeout_ms: float = 1000) -> LinFrame:
        """The first error-free frame of `frame` — an id 0..63, or the LDF's frame name (a
        go-to-sleep is a MasterReq, 0x3C) — waited for at most timeout_ms in all; blobly.Timeout
        otherwise, its message saying what came instead. Every frame read while waiting is
        consumed. Ctrl-C ends the wait within 100 ms."""
        __tracebackhide__ = True  # a pytest failure points at the test's line, not this one
        deadline = _deadline("expect", timeout_ms)
        h = self._handle()
        want = self._id_of(h, frame)
        came: collections.Counter[str] = collections.Counter()
        first = True
        while True:
            left = deadline - monotonic_ms()
            if left <= 0 and not first:
                break
            first = False
            f = self._receive(h, max(0, min(math.floor(left), SLICE_MS)))
            if f is None:
                if left < 1:  # what the library cannot be asked for is slept, not read
                    rest = deadline - monotonic_ms()
                    if rest > 0:
                        sleep_ms(rest)
                    break
                continue
            if f.id == want and f.event != "wakeup" and not f.errs:
                return f
            came[_said(f)] += 1
        what = self._name_of(h, want)
        if not came:
            instead = "nothing came"
        else:
            shown = list(came.items())
            instead = ("came instead: " + ", ".join(f"{k} x{c}" for k, c in shown[:8])
                       + (", ..." if len(shown) > 8 else ""))
        raise Timeout(f"{self.name}: no 0x{want:02X}{' ' + what if what else ''} within {_num(timeout_ms)} ms; "
                      + instead, _lib.BB_ERR_TIMEOUT)

    def header(self, id: int) -> None:
        """One header for frame `id` (0..63), from the bus's master."""
        if isinstance(id, bool) or not isinstance(id, int):
            raise TypeError(f"header: a LIN id is an int, not {id!r}")
        if not 0 <= id <= 0x3F:
            raise ValueError(f"header: a LIN id is 0..63, not {id}")
        _lib.check(_lib.lib().bb_lin_header(self._handle(), id))

    def set(self, signal: str, value: float | str | bytes, *, raw: bool = False) -> None:
        """What a node this bus simulates publishes for `signal`, from its next response. A number
        is the physical value where the signal's encoding has a physical range, else the raw one
        (raw=True: always raw, a whole number); a string a logical value, or an ascii / bcd array's
        text; bytes a byte array."""
        name = _text_arg("set", "a signal name", signal)
        lib = _lib.lib()
        if isinstance(value, bool):
            raise TypeError(f"set: {signal} is set to a number, a string or bytes, not {value!r}")
        if isinstance(value, (int, float)):
            if isinstance(value, int) and not -2**63 <= value < 2**64:
                raise ValueError(f"set: {value} is past what a LIN signal holds")
            kind, number, data = (_lib.LIN_RAW if raw else _lib.LIN_NUMBER), float(value), b""
        elif isinstance(value, str):
            kind, number, data = _lib.LIN_TEXT, 0.0, value.encode()
        elif isinstance(value, (bytes, bytearray, memoryview)):
            kind, number, data = _lib.LIN_BYTES, 0.0, bytes(value)
        else:
            raise TypeError(f"set: {signal} is set to a number, a string or bytes, not {value!r}")
        _lib.check(lib.bb_lin_set_signal(self._handle(), name, kind, number, data, len(data)))

    def schedule(self, name: str) -> None:
        """Runs the LDF schedule table `name` (master): started, or switched to at the end of the
        slot running now."""
        _lib.check(_lib.lib().bb_lin_schedule(self._handle(), _text_arg("schedule", "a table name", name)))

    def stop_schedule(self) -> bool:
        """Stops the running schedule: no header follows. False when the scheduler was still inside
        a header call at its bound."""
        return _lib.check(_lib.lib().bb_lin_stop_schedule(self._handle())) != _lib.BB_RELEASING

    def wakeup(self) -> None:
        """A wakeup pulse."""
        _lib.check(_lib.lib().bb_lin_wakeup(self._handle()))

    def sleep(self) -> None:
        """The go-to-sleep command (master)."""
        _lib.check(_lib.lib().bb_lin_sleep(self._handle()))

    def status(self) -> LinStatus:
        """The bus as it stands: a LinStatus."""
        lib = _lib.lib()
        h = self._handle()
        st = _lib.BbLinStatus()
        _lib.check(lib.bb_lin_read_status(h, ctypes.byref(st)))
        frames = {}
        row = _lib.BbLinId()
        for k in range(st.frames):
            _lib.check(lib.bb_lin_status_id(h, k, ctypes.byref(row)))
            frames[row.id] = LinIdStatus(row.id, _lib.string(lib.bb_lin_status_text, h, _lib.LIN_STATUS_FRAME, k),
                                         row.count, row.errors, row.cadence_ms or None)
        notes = [_lib.string(lib.bb_lin_status_text, h, _lib.LIN_STATUS_NOTE, k) for k in range(st.notes)]
        return LinStatus(
            _lib.string(lib.bb_lin_status_text, h, _lib.LIN_STATUS_NAME, 0),
            _lib.string(lib.bb_lin_status_text, h, _lib.LIN_STATUS_ADDRESS, 0),
            next((n for n, v in _lib.LIN_ROLES.items() if v == st.role), "monitor"),
            _lib.LIN_STATES.get(st.state, f"unknown ({st.state})"),
            _lib.string(lib.bb_lin_status_text, h, _lib.LIN_STATUS_SCHEDULE, 0) or None,
            bool(st.sched_running), st.sched_sent, st.sched_failed, st.sched_late, st.load, st.dropped, frames, notes)

    def diagnostics(self) -> BusDiagnostics:
        """The bus's own handle's counts — dropped, controller-error and undecodable records (a
        serial port's framing, parity and overrun counts) — with the frames this LinBus's queue
        lost added to `dropped`."""
        out = _lib.BbDiagnostics()
        _lib.check(_lib.lib().bb_lin_diagnostics(self._handle(), ctypes.byref(out)))
        return BusDiagnostics(out.dropped, out.bus_errors, out.decode_errors)

    def __repr__(self) -> str:
        return f"<LinBus {self.name}{' closed' if self._closed else ''}>"


def open(address: str, role: Role = "monitor", *, ldf: "str | os.PathLike[str] | None" = None,  # noqa: A001
         baud: int = 0) -> LinBus:
    """A LIN bus of the script's own on `address` — "inproc:<name>", or on Linux
    "tty:<path>[@baud]" and "pty:<path>[@baud]" — with or without a project loaded: `role`
    "master", "slave" or "monitor"; `ldf` the description file its frames are read by (relative
    to the working directory; None: none); `baud` 0 for the address's rate, else the LDF's
    LIN_speed, else 19200 (or 1000..20000). Refused (Refused) when it will not open — a second
    master on one bus included. Close it, or use it as a context manager. A project's LIN bus is
    Project.lin's."""
    if not isinstance(address, str) or not address:
        raise TypeError(f"lin.open: an address is a non-empty string, not {address!r}")
    a = _text_arg("lin.open", "an address", address)
    if ":" not in address:
        raise ValueError(f"lin.open: {address!r} is not an address (inproc:<name>, tty:<path>, pty:<path>); "
                         "a LIN bus of the run is net.lin's")
    if role not in _lib.LIN_ROLES:
        raise ValueError(f"lin.open: a role is master, slave or monitor, not {role!r}")
    if isinstance(baud, bool) or not isinstance(baud, int):
        raise TypeError(f"lin.open: baud is an int, not {baud!r}")
    if not -2**31 <= baud < 2**31:  # a C int: wider would wrap into the range
        raise ValueError(f"lin.open: baud is 0 or 1000..20000, not {baud}")
    path = None if ldf is None else os.fsencode(os.path.abspath(ldf))
    if path is not None and b"\0" in path:
        raise ValueError("lin.open: an LDF path cannot carry a NUL: C would read it cut short")
    bus = LinBus(None, -1, address)
    bus.address, bus.role, bus.ldf, bus.baud = address, role, None if ldf is None else os.path.abspath(ldf), baud
    lib = _lib.lib()
    with _lib.state_lock:
        _close_orphans()
        bus._h = _lib.check(lib.bb_lin_open(-1, a, _lib.LIN_ROLES[role], path, baud))
    return bus


class LinBuses(Named[LinBus]):
    """The run's LIN buses (Project.lin): `net.lin.BODY`, `net.lin["BODY"]`, by position, iterated
    in the project's order, completed by dir()."""
    _noun = "LIN bus"


def listed(project: "Project", old: list[LinBus] | None) -> LinBuses:
    """The current run's LIN buses, keeping each of `old` still at its position under its name; the
    caller holds the state lock."""
    lib = _lib.lib()
    out = []
    for i in range(_lib.check(lib.bb_lin_count())):
        name = _lib.string(lib.bb_lin_text, i, _lib.LIN_TEXT_NAME)
        keep = old[i] if old is not None and i < len(old) else None
        if keep is None or keep.name != name:
            keep = LinBus(project, i, name)
        keep._fill()
        out.append(keep)
    return LinBuses(out)
