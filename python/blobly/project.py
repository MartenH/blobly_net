"""project — a .blobnet project brought up in this process through libblobly (blobly.headless),
its enabled channels as objects that complete in a REPL, and the event loop over them."""
import ctypes
import math
import numbers
import os
import warnings
import weakref

from . import _lib
from ._lib import BloblyError
from .events import EventLoop, monotonic_ms, sleep_ms, wait_on
from .uds import UdsClient, _close_orphans


class Frame:
    """A CAN frame. `data` is the payload; `length` its length, or for a remote frame (`rtr`, no
    payload) the length it asks for; `fd`/`brs` CAN-FD and its bit-rate switch; `esi` CAN-FD's
    error-state indicator."""
    __slots__ = ("id", "data", "length", "ext", "fd", "brs", "rtr", "esi")

    def __init__(self, id, data=b"", ext=False, fd=False, brs=False, rtr=False, esi=False, length=None):
        self.id, self.data, self.ext = id, bytes(data), ext
        self.fd, self.brs, self.rtr, self.esi = fd, brs, rtr, esi
        self.length = len(self.data) if length is None else length

    def __eq__(self, other):
        return isinstance(other, Frame) and all(getattr(self, k) == getattr(other, k) for k in self.__slots__)

    def __repr__(self):
        flags = "".join(f" {k}" for k in ("ext", "fd", "brs", "rtr", "esi") if getattr(self, k))
        return f"Frame(0x{self.id:X} [{self.data.hex(' ').upper()}]{flags})"


def frame_of(f):
    """A Frame from a bb_frame: a remote frame's len is the length it asks for, with no payload."""
    data = b"" if f.rtr else bytes(f.data[:f.len])
    return Frame(f.id, data, bool(f.ext), bool(f.fd), bool(f.brs), bool(f.rtr), bool(f.esi), f.len)


def _bb_frame(who, id, data, ext=False, fd=False, brs=False, rtr=False):
    """A bb_frame from a frame's parts, refusing what no CAN frame is."""
    if isinstance(id, bool) or not isinstance(id, int) or not 0 <= id <= 0x1FFF_FFFF:
        raise ValueError(f"{who}: a CAN id is an integer of at most 29 bits, not {id!r}")
    data = bytes(data)
    if len(data) > 64:
        raise ValueError(f"{who}: {len(data)} bytes is more than a CAN-FD frame carries")
    f = _lib.BbFrame(id=id, len=len(data), ext=int(bool(ext)), fd=int(bool(fd)), brs=int(bool(brs)),
                     rtr=int(bool(rtr)))
    for i, b in enumerate(data):
        f.data[i] = b
    return f


def _ms(timeout_ms):
    """A timeout as bb_bus_recv takes it: whole milliseconds rounded DOWN (a receive waits at most
    what was asked), None for forever."""
    if timeout_ms is None:
        return -1
    if isinstance(timeout_ms, bool) or not isinstance(timeout_ms, (int, float)) or not math.isfinite(timeout_ms):
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

    def __init__(self, project, index, name, gen):
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
    def iface(self):
        """What the row opens: after start, as the run has it (a hosted DoIP row moves onto a port
        this process could bind)."""
        lib = _lib.lib()
        with _lib.state_lock:
            self._current()
            return _lib.text(lib.bb_channel_iface(self._index))

    @property
    def kind(self):
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

    def send(self, id, data=b"", ext=False, fd=False, brs=False):
        """Puts a frame on the wire. fd/brs left False let the wire's declared format decide."""
        self._send_on(self._handle(), _bb_frame(self.name, id, data, ext, fd, brs))

    def _send_on(self, h, f):
        lib = _lib.lib()
        _lib.check(lib.bb_bus_send(h, ctypes.byref(f)))

    def recv(self, timeout_ms=1000):
        """The next frame other nodes sent, waiting at most timeout_ms (None: forever); None when
        nothing came."""
        frame, _ = self._receive(_ms(timeout_ms))
        return frame

    def look(self):
        """One look at what is already queued: (frame or None, spent). `spent` says the look
        stopped at its bound with records still queued behind it, so a poller looks again at once
        rather than sleeping."""
        return self._receive(0)

    def _receive(self, ms):
        f = _lib.BbFrame()
        lib = _lib.lib()
        rc = _lib.check(lib.bb_bus_recv(self._handle(), ms, ctypes.byref(f)))
        if rc in (_lib.BB_NONE, _lib.BB_SPENT):
            return None, rc == _lib.BB_SPENT
        return frame_of(f), False

    def health(self):
        """The controller's ladder now: "ok", "error warning", "ERROR-PASSIVE", "BUS-OFF", or ""
        where the backend cannot say (the software buses)."""
        lib = _lib.lib()
        return _lib.HEALTH_NAMES.get(_lib.check(lib.bb_bus_health(self._handle())), "")

    @property
    def messages(self):
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

    def decode(self, frame):
        """{signal: physical value} for what `frame` says in this row's databases — the message
        of its id and kind (else, for an extended frame, one of its J1939 PGN), each signal it
        carries (a multiplexed signal its switch does not select is left out) — as a Lua script's
        decode() reads it; None for a frame of no message, or a remote frame."""
        f = _bb_frame(self.name, frame.id, frame.data, getattr(frame, "ext", False),
                      rtr=getattr(frame, "rtr", False))
        lib = _lib.lib()
        with _lib.state_lock:
            msgs = self.messages
            values, active, m = msgs._decoded  # the lock is held: one decode at a time uses them
            rc = _lib.check(lib.bb_decode(self._index, ctypes.byref(f), ctypes.byref(m), values, active,
                                          msgs._most))
            if rc == _lib.BB_NONE:
                return None
            return {s.name: values[i] for i, s in enumerate(msgs[m.value].signals) if active[i]}

    def uds(self, tx=None, rx=None):
        """A UdsClient on this row: UDS requests out on CAN id `tx`, answers back on `rx`, by the
        rule the Lua uds.open opens by — None is the default pair 0x7E0 / 0x7E8, 0 is an id like
        any other, and either id past 0x7FF makes both 29-bit. Only on a CAN row (a DoIP row is
        refused by name: UDS over DoIP is not in the package yet), and while the project is
        started."""
        return UdsClient(self, tx, rx)

    def close(self):
        """Lets the handle go, and the connections of its UDS clients; the next use opens another."""
        lib = _lib.lib()
        with _lib.state_lock:
            _close_orphans()
            for c in list(self._uds):
                c._let_go()
            if self._h is not None:
                h, self._h = self._h, None
                _lib.check(lib.bb_bus_close(h))

    def __repr__(self):
        return f"<Channel {self.name}>"


class Named:
    """Items by name: `c.X`, `c["X-1"]`, `c[0]` (by position), iteration in order, and dir() for
    completion. A name two items answer to is refused, and such items are reached by position."""
    _noun = "item"

    def __init__(self, items):
        self._by_name = {}
        for c in items:
            self._by_name.setdefault(c.name, []).append(c)
        self._order = items

    def _one(self, name):
        rows = self.__dict__["_by_name"].get(name)
        if not rows:
            return None
        if len(rows) > 1:
            raise BloblyError(f"{name!r} names {len(rows)} {self._noun}s here; reach them by "
                              f"position ([i]) or rename one")
        return rows[0]

    def __getattr__(self, name):
        c = self._one(name)
        if c is None:
            raise AttributeError(f"no {self._noun} named {name!r}; there are: "
                                 + ", ".join(self.__dict__["_by_name"]))
        return c

    def __getitem__(self, key):
        if isinstance(key, int):
            return self._order[key]
        c = self._one(key)
        if c is None:
            raise KeyError(f"no {self._noun} named {key!r}")
        return c

    def __dir__(self):
        return [n for n, rows in self._by_name.items() if n.isidentifier() and len(rows) == 1] + ["keys"]

    def __iter__(self):
        return iter(self._order)

    def __len__(self):
        return len(self._order)

    def keys(self):
        return list(self._by_name)


class Channels(Named):
    """The project's enabled rows: `net.channels.CAN1`, `net.channels["CAN-1"]`, `net.channels[0]`.
    Names are not unique in a project: two rows of one name are reached by position."""
    _noun = "enabled channel"


class Messages(Named):
    """A row's messages (Channel.messages)."""
    _noun = "message"

    def __init__(self, items):
        super().__init__(items)
        self._most = max((m._count for m in items), default=0)
        # bb_decode's out arrays, as wide as the widest message, made once
        n = max(self._most, 1)
        self._decoded = ((ctypes.c_double * n)(), (ctypes.c_uint8 * n)(), ctypes.c_int(-1))


class Signals(Named):
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

    def __repr__(self):
        unit = f" {self.unit!r}" if self.unit else ""
        return (f"<Signal {self.name} {self.start_bit}|{self.length} {self.byte_order} "
                f"x{self.factor:g}{self.offset:+g} [{self.minimum:g}..{self.maximum:g}]{unit}>")


class Message:
    """A message of a row's databases: `id`, `ext`, `dlc`, `j1939` (the database declares it),
    `signals`; encode / send by signal name. It belongs to the run that listed it: after a stop
    and a start it goes on working while its row's database still has it at its position, and
    refuses otherwise."""

    def __init__(self, channel, index, name):
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
    def signals(self):
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

    def encode(self, /, **signals):
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

    def send(self, /, **signals):
        """Encodes this message (encode) and sends it on its channel; returns the encoded Frame. Its
        fd/brs are unset, so what goes out takes the wire's declared format. Encoded and the
        channel's handle taken under one hold of the state lock, so a stop and start on another
        thread cannot put this run's encoding on the next run's wire."""
        with _lib.state_lock:
            f = self.encode(**signals)
            h = self.channel._handle()
        self.channel._send_on(h, _bb_frame(self.channel.name, f.id, f.data, f.ext))
        return f

    def __repr__(self):
        return f"<Message {self.name} 0x{self.id:X}{' ext' if self.ext else ''} [{self.dlc}] on {self.channel.name}>"


class Project(EventLoop):
    """A .blobnet project in this process. `with Project(path) as net:` loads and starts it — its
    simulated ECUs, UDS servers, generators and DoIP entities run until the block ends. One run per
    process, and one thread drives load, start and stop (bb.h); send and recv may run on others."""

    def __init__(self, path):
        super().__init__()
        p = os.fspath(path)
        if (b"\0" if isinstance(p, bytes) else "\0") in p:
            raise ValueError("a project path cannot carry a NUL: C would read it cut short")
        self.path = os.path.abspath(path)
        self.started = False
        self._channels = None
        self._gen = None  # which load of the library is this project's
        self._rr = 0

    def load(self):
        """Reads the project into the library, which holds one load at a time: another project's
        channels refuse from here on. A reload of this project KEEPS each Channel whose row is
        still at its position under its name — so a variable, a timer's closure and a handler all
        go on working — and drops the handlers of rows that went, naming them."""
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
        gone = self._drop_gone(rows)
        if gone:
            raise BloblyError("handlers dropped: their rows are not in this load of the project ("
                              + ", ".join(gone) + "); register them again", _lib.BB_ERR_STATE)
        return self

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

    def start(self):
        """Starts this project — reloaded first if the library holds another load now."""
        lib = _lib.lib()
        with _lib.state_lock:
            st = _lib.state
            if st["owner"] is not self or st["gen"] != self._gen:
                self.load()
            _lib.check(lib.bb_start())
            st["run"] += 1  # the rows' databases are this run's from here
            self.started = True
        return self

    def stop(self):
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

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        if not self.stop():
            warnings.warn(f"{self.path}: a loop outlived the stop's bound and still holds the "
                          "process; blobly.wait_released() waits for it before the next start",
                          RuntimeWarning, stacklevel=2)
        return False

    @property
    def channels(self):
        if self._channels is None:
            raise BloblyError("the project is not loaded", _lib.BB_ERR_STATE)
        return self._channels

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

    def __repr__(self):
        return f"<Project {self.path}{' started' if self.started else ''}>"
