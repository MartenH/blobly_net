"""project — a .blobnet project brought up in this process through libblobly (blobly.headless),
its enabled channels as objects that complete in a REPL, and the event loop over them."""
import ctypes
import math
import os

from . import _lib
from ._lib import BloblyError
from .events import EventLoop, monotonic_ms, sleep_ms, wait_on


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


def _ms(timeout_ms):
    """A timeout as bb_bus_recv takes it: whole milliseconds rounded up, None for forever."""
    if timeout_ms is None:
        return -1
    if isinstance(timeout_ms, bool) or not isinstance(timeout_ms, (int, float)):
        raise TypeError("timeout_ms must be a number of milliseconds or None")
    ms = max(0, math.ceil(timeout_ms))
    if ms > 2**31 - 1:  # a C int: wider would wrap to 'forever' or to 0
        raise ValueError(f"timeout_ms {timeout_ms} is longer than one wait can be (2**31 - 1 ms); use None to wait for ever")
    return ms


class Channel:
    """One enabled row of the project. Its bus handle is opened on first use and is the one send,
    recv, health and the event loop all use, so what this channel sends is never heard back. It
    belongs to one load of its project: after another load (its own or another project's) it
    refuses, rather than reach whatever row now has its index."""

    def __init__(self, project, index, name, gen):
        self._project, self._index, self.name, self._gen = project, index, name, gen
        self._h = None

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
        self._current()
        return _lib.text(lib.bb_channel_iface(self._index))

    def _handle(self):
        if self._h is None:
            self._current()
            if not self._project.started:
                raise BloblyError(f"{self.name}: the project is not started", _lib.BB_ERR_STATE)
            lib = _lib.lib()
            # the library's own bytes: what it named, not a re-encoding of it
            self._h = _lib.check(lib.bb_bus_open(lib.bb_channel_iface(self._index)))
        return self._h

    def send(self, id, data=b"", ext=False, fd=False, brs=False):
        """Puts a frame on the wire. fd/brs left False let the wire's declared format decide."""
        if isinstance(id, bool) or not isinstance(id, int) or not 0 <= id <= 0x1FFF_FFFF:
            raise ValueError(f"{self.name}: a CAN id is an integer of at most 29 bits, not {id!r}")
        data = bytes(data)
        if len(data) > 64:
            raise ValueError(f"{self.name}: {len(data)} bytes is more than a CAN-FD frame carries")
        f = _lib.BbFrame(id=id, len=len(data), ext=int(bool(ext)), fd=int(bool(fd)), brs=int(bool(brs)))
        for i, b in enumerate(data):
            f.data[i] = b
        lib = _lib.lib()
        _lib.check(lib.bb_bus_send(self._handle(), ctypes.byref(f)))

    def recv(self, timeout_ms=1000):
        """The next frame other nodes sent, waiting at most timeout_ms (None: forever); None when
        nothing came."""
        f = _lib.BbFrame()
        lib = _lib.lib()
        rc = _lib.check(lib.bb_bus_recv(self._handle(), _ms(timeout_ms), ctypes.byref(f)))
        if rc == 1:
            return None
        return frame_of(f)

    def health(self):
        """The controller's ladder now: "ok", "error warning", "ERROR-PASSIVE", "BUS-OFF", or ""
        where the backend cannot say (the software buses)."""
        lib = _lib.lib()
        return _lib.HEALTH_NAMES.get(_lib.check(lib.bb_bus_health(self._handle())), "")

    def close(self):
        """Lets the handle go; the next use opens another."""
        if self._h is not None:
            lib = _lib.lib()
            h, self._h = self._h, None
            _lib.check(lib.bb_bus_close(h))

    def __repr__(self):
        return f"<Channel {self.name}>"


class Channels:
    """The project's enabled rows: `net.channels.CAN1`, `net.channels["CAN-1"]`, `net.channels[0]`
    (by position), iteration in project order, and dir() for completion. Names are not unique in a
    project: a name two rows answer to is refused, and such rows are reached by position."""

    def __init__(self, channels):
        self._by_name = {}
        for c in channels:
            self._by_name.setdefault(c.name, []).append(c)
        self._order = channels

    def _one(self, name):
        rows = self.__dict__["_by_name"].get(name)
        if not rows:
            return None
        if len(rows) > 1:
            raise BloblyError(f"{name!r} names {len(rows)} channels in this project; reach them by "
                              "position (net.channels[i]) or rename one")
        return rows[0]

    def __getattr__(self, name):
        c = self._one(name)
        if c is None:
            raise AttributeError(f"no enabled channel named {name!r}; there are: "
                                 + ", ".join(self.__dict__["_by_name"]))
        return c

    def __getitem__(self, key):
        if isinstance(key, int):
            return self._order[key]
        c = self._one(key)
        if c is None:
            raise KeyError(f"no enabled channel named {key!r}")
        return c

    def __dir__(self):
        return [n for n, rows in self._by_name.items() if n.isidentifier() and len(rows) == 1] + ["keys"]

    def __iter__(self):
        return iter(self._order)

    def __len__(self):
        return len(self._order)

    def keys(self):
        return list(self._by_name)


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
        """Reads the project into the library, which holds one at a time: channels of an earlier
        load, this project's or another's, refuse from here on."""
        lib = _lib.lib()
        _lib.check(lib.bb_load(os.fsencode(self.path)))  # the filesystem's bytes, not UTF-8
        if self._channels is not None:
            for c in self._channels:
                try:
                    c.close()
                except BloblyError:
                    pass
        st = _lib.state
        st["gen"] += 1
        st["owner"] = self
        self._gen = st["gen"]
        n = _lib.check(lib.bb_channel_count())
        rows = [Channel(self, i, _lib.text(lib.bb_channel_name(i)), st["gen"]) for i in range(n)]
        self._channels = Channels(rows)
        gone = self._rebind(rows)
        if gone:
            raise BloblyError("handlers dropped: their rows are not in this load of the project ("
                              + ", ".join(gone) + "); register them again", _lib.BB_ERR_STATE)
        return self

    def _rebind(self, rows):
        """Moves every registration onto the row this load has at its position, where the name
        still matches; drops the rest and names them, rather than leave a handler that hears
        nothing."""
        gone = []

        def moved(key):
            if not isinstance(key, Channel):
                return key
            if key._index < len(rows) and rows[key._index].name == key.name:
                return rows[key._index]
            gone.append(f"{key.name} (row {key._index})")
            return None
        self._listened = [k for k in (moved(k) for k in self._listened) if k is not None]
        self._on_msg = [(k, i, fn) for k, i, fn in ((moved(k), i, fn) for k, i, fn in self._on_msg) if k is not None]
        kept = []
        for h in self._on_health:
            k = moved(h.channel)
            if k is not None:
                h.channel = k
                kept.append(h)
        self._on_health = kept
        return sorted(set(gone))

    def start(self):
        """Starts this project — reloaded first if the library holds another load now."""
        st = _lib.state
        if st["owner"] is not self or st["gen"] != self._gen:
            self.load()
        lib = _lib.lib()
        _lib.check(lib.bb_start())
        self.started = True
        return self

    def stop(self):
        if not self.started:
            return
        for c in self._channels:
            try:
                c.close()
            except BloblyError:
                pass  # a handle already gone is closed enough
        lib = _lib.lib()
        self.started = False
        _lib.check(lib.bb_stop())

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()
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

    def _wait_frame(self, channels, timeout_ms):
        got, self._rr = wait_on(channels, timeout_ms, self._rr, monotonic_ms, sleep_ms)
        return got

    def __repr__(self):
        return f"<Project {self.path}{' started' if self.started else ''}>"
