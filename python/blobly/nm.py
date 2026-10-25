"""nm — CAN network management on a channel, through libblobly (blobly/nm): who reports in on the
channel's NM cluster and who keeps the network awake, read from the frames the channel's own handle
reads (Channel.nm). A listener: it sends nothing."""
import ctypes
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from typing import TYPE_CHECKING

from . import _lib
from ._lib import Refused, Timeout
from .events import SLICE_MS

if TYPE_CHECKING:
    from .project import Channel

STATES = ("awake", "releasing", "asleep")
_ASK_NS = 5_000_000  # how far a wait lets the reading's moment move before it asks again


@dataclass(frozen=True)
class NmBits:
    """A node's latest control bit vector, by name: `repeat_request` (0x01), `ready_to_sleep`
    (0x08: it has released the network), `active_wakeup` (0x10), `pn_info` (0x40: the frame
    carries a partial-network request); `raw` the byte."""
    raw: int
    repeat_request: bool
    ready_to_sleep: bool
    active_wakeup: bool
    pn_info: bool

    @property
    def wants_network(self) -> bool:
        """It asks for the network: ready to sleep is clear."""
        return not self.ready_to_sleep


@dataclass(frozen=True)
class NmNode:
    """One node of an NM reading: a reporter, or a node the configuration declares that has never
    reported (`missing`). `name` is its declaration's, else "NID 0x13"; `nid` and `can_id` None
    where not known; `last_heard_ms` on the host's monotonic clock (blobly.now_ms), None for a
    missing node; `cadence_ms` the mean interval between its frames within the timeout (a longer
    gap is the network asleep, not its cycle), None before two; `bits` its latest control bits,
    None for a missing node; `pn` the partial-network mask its latest frame requests, None where
    it requests none. `live`: heard within the timeout; `keeps_awake`: live and asking for the
    network; `unknown`: it reports and the configuration declares its members and not it."""
    name: str
    nid: int | None
    can_id: int | None
    ext: bool
    missing: bool
    unknown: bool
    live: bool
    keeps_awake: bool
    count: int
    last_heard_ms: float | None
    cadence_ms: float | None
    last_interval_ms: float | None
    bits: NmBits | None
    pn: int | None


@dataclass(frozen=True)
class NmReading:
    """A channel's NM cluster as read up to its handle's latest read (`t_ms`, blobly.now_ms).
    `state` is "awake" (a node heard within the timeout asks for the network), "releasing" (every
    such node is ready to sleep) or "asleep" (nothing heard within the timeout, or nothing yet).
    `kept_awake_by` names the nodes asking, declared ones in declaration order, then the others in
    the order first heard; `woken_by` the node whose frame ended the last silence (None before any)
    and `woken_active` whether it said active wake-up; `repeat_requested_by` the live nodes asking
    for a repeat. `nodes` are the reporters in the order first heard, then the missing ones;
    `missing` and `unknown` their names. `source` is where the configuration came from
    ("system.toml", "ARXML", "project" or "script"), `origin` what it was read from, `cluster`
    its frames in words, `timeout_ms` the timeout (`timeout_default`: the configuration states
    none)."""
    state: str
    kept_awake_by: list[str]
    woken_by: str | None
    woken_active: bool
    woken_ms: float | None
    repeat_requested_by: list[str]
    nodes: list[NmNode]
    missing: list[str]
    unknown: list[str]
    heard: bool
    last_heard_ms: float | None
    frames: int
    malformed: int
    last_error: str
    dropped: int
    timeout_ms: int
    timeout_default: bool
    source: str
    origin: str
    cluster: str
    t_ms: float

    def node(self, name: str) -> NmNode | None:
        """The node of that name, None for none."""
        return next((n for n in self.nodes if n.name == name), None)


def _ms_or_none(ns):
    return _lib.ms_of(ns) if ns else None


def _node(n):
    missing = bool(n.missing)
    cbv = n.cbv
    bits = None if missing else NmBits(cbv, bool(cbv & 0x01), bool(cbv & 0x08), bool(cbv & 0x10), bool(cbv & 0x40))
    return NmNode(_lib.text(n.name), n.nid if n.nid >= 0 else None, n.id if n.has_id else None, bool(n.ext),
                  missing, bool(n.unknown), bool(n.live), n.keeper >= 0, n.count, _ms_or_none(n.last_ns),
                  n.cadence_ms or None, n.last_interval_ms or None, bits, n.pn if n.has_pn else None)


def _int(who, what, v, lo, hi):
    if isinstance(v, bool) or not isinstance(v, int):
        raise TypeError(f"{who}: {what} is an int, not {v!r}")
    if not lo <= v <= hi:
        raise ValueError(f"{who}: {what} is {lo}..{hi}, not {v}")
    return v


def _state(who, state):
    if state not in STATES:
        raise ValueError(f"{who}: an NM state is one of {', '.join(STATES)}, not {state!r}")
    return state


class NmListener:
    """The NM reading of a channel's frames (Channel.nm): every frame its handle reads — by recv,
    expect, the event loop or the waits here — goes through it, so a frame is consumed once and what
    the channel sends is never in it. A reading is as of the handle's latest read, never the wall
    clock's now: a channel nobody has read for a while reads as it was then, not as asleep, since
    what it carried meanwhile is still queued. From the thread that uses the channel. A stop and a
    start of the project, or the channel's close, begin a new reading."""
    channel: "Channel"
    explicit: tuple[int, int, bool, int] | None

    def __init__(self, channel: "Channel", explicit: tuple[int, int, bool, int] | None) -> None:
        self.channel = channel
        self.explicit = explicit  # (lo, hi, ext, timeout_ms) the script stated, None: the wire's own
        self._h = None

    def _attach(self, h):
        """Binds handle `h` to this reading's configuration; Refused where the wire has none."""
        lib = _lib.lib()
        if self.explicit is None:
            if _lib.check(lib.bb_nm_attach(h, self.channel._index)) == 0:
                raise Refused(f"{self.channel.name}: its wire has no NM configuration (a system.toml bus named "
                              "like a row on it, the wire's ARXML NM-PDU frames, or a row's nm:); give "
                              "nm(lo, hi) a range", _lib.BB_ERR)
        else:
            lo, hi, ext, timeout_ms = self.explicit
            _lib.check(lib.bb_nm_attach_range(h, self.channel._index, lo, hi, int(ext), timeout_ms))
        self._h = h

    def _handle(self):
        h = self.channel._handle()
        if h != self._h:
            with _lib.state_lock:
                self._attach(h)
        return h

    def _view(self, h):
        v = _lib.BbNmView()
        _lib.check(_lib.lib().bb_nm_read_view(h, ctypes.byref(v)))
        return v

    def _reading(self, h, v=None):
        lib = _lib.lib()
        if v is None:
            v = self._view(h)
        nodes, ranks, repeaters = [], [], []
        n = _lib.BbNmNode()
        for k in range(v.nodes):
            _lib.check(lib.bb_nm_node_info(h, k, ctypes.byref(n)))
            nodes.append(_node(n))
            ranks.append(n.keeper)
            if n.repeater:
                repeaters.append(nodes[-1].name)
        keepers = [nodes[i].name for i in sorted((i for i in range(len(nodes)) if ranks[i] >= 0),
                                                 key=lambda i: ranks[i])]
        woken = nodes[v.woke].name if 0 <= v.woke < len(nodes) else None
        return NmReading(
            _lib.NM_STATES.get(v.state, f"unknown ({v.state})"), keepers, woken, bool(v.woke_active),
            _ms_or_none(v.woke_ns) if woken else None,
            repeaters,
            nodes, [nd.name for nd in nodes if nd.missing], [nd.name for nd in nodes if nd.unknown],
            bool(v.heard), _ms_or_none(v.last_ns), v.frames, v.malformed, _lib.text(v.last_error), v.dropped,
            v.timeout_ms, bool(v.timeout_default), _lib.NM_SOURCES.get(v.source, f"unknown ({v.source})"),
            _lib.text(v.origin), _lib.text(v.frames_text), _lib.ms_of(v.t_ns))

    def reading(self, window_ms: float = 0) -> NmReading:
        """The cluster as read up to the handle's latest read. With window_ms the channel is read
        for that long first (every frame consumed); 0 reads nothing."""
        from .project import _deadline
        if window_ms:
            deadline = _deadline("reading", window_ms)
            with _lib.state_lock:
                run = _lib.state["run"]
            self._handle()
            for _ in self.channel._frames_until(deadline, run, idle=True):
                pass
        return self._reading(self._handle())

    @property
    def state(self) -> str:
        """"awake", "releasing" or "asleep", as of the latest read (NmReading.state)."""
        return _lib.NM_STATES.get(self._view(self._handle()).state, "unknown")

    @property
    def kept_awake_by(self) -> list[str]:
        """The nodes keeping the network awake, as of the latest read (NmReading.kept_awake_by)."""
        return self.reading().kept_awake_by

    @property
    def woken_by(self) -> str | None:
        """The node whose frame ended the last silence, None before any (NmReading.woken_by)."""
        return self.reading().woken_by

    @property
    def nodes(self) -> list[NmNode]:
        """The reporters in the order first heard, then the declared nodes never heard."""
        return self.reading().nodes

    @property
    def missing(self) -> list[str]:
        """The declared nodes never heard."""
        return self.reading().missing

    @property
    def unknown(self) -> list[str]:
        """The reporters the configuration does not declare (a configuration declaring members)."""
        return self.reading().unknown

    def expect(self, predicate: Callable[[NmReading], bool], timeout_ms: float = 1000, *,
               what: str = "the NM condition") -> NmReading:
        """The first reading `predicate` holds for, the channel read until it does or timeout_ms has
        passed in all (one deadline, as Channel.expect's): asked after every read, a frame or a read
        that found nothing, so a state reached by silence is seen. blobly.Timeout otherwise, its
        message saying what the reading was. Every frame read is consumed."""
        __tracebackhide__ = True  # a pytest failure points at the test's line, not this one
        return self._until("expect", predicate, timeout_ms, what, False)

    def _until(self, who, predicate, timeout_ms, what, state_only):
        __tracebackhide__ = True
        from .project import _deadline
        deadline = _deadline(who, timeout_ms)
        with _lib.state_lock:
            run = _lib.state["run"]
        h = self._handle()
        self.channel._receive(0, h)  # a look first: the reading brought up to now, waiting for nothing
        v = self._view(h)
        last = self._reading(h, v)
        if predicate(last):
            return last
        asked = (v.frames, v.malformed, v.dropped, v.t_ns // _ASK_NS)
        # each read waits at most the cluster's timeout, so a node going silent is read at once
        slice_ms = max(1, min(SLICE_MS, v.timeout_ms))
        for _ in self.channel._frames_until(deadline, run, idle=True, slice_ms=slice_ms):
            v = self._view(h)
            # asked again once an NM frame came or time moved on: a frame of another id moves
            # the reading only by its time
            mark = (v.frames, v.malformed, v.dropped, v.t_ns // _ASK_NS)
            if mark == asked:
                continue
            asked = mark
            if state_only is not False and _lib.NM_STATES.get(v.state) != state_only:
                continue
            last = self._reading(h, v)
            if predicate(last):
                return last
        last = self._reading(h)
        if predicate(last):
            return last
        raise Timeout(f"{self.channel.name}: expected {what} within {timeout_ms:g} ms; " + _said(last),
                      _lib.BB_ERR_TIMEOUT)

    def expect_state(self, state: str, timeout_ms: float = 1000, *,
                     kept_awake_by: Iterable[str] | None = None) -> NmReading:
        """The first reading in `state` ("awake", "releasing", "asleep") — and, given
        `kept_awake_by`, kept awake by exactly those nodes, in any order — waited for at most
        timeout_ms in all; blobly.Timeout otherwise, saying what the reading was."""
        __tracebackhide__ = True
        _state("expect_state", state)
        want = None if kept_awake_by is None else sorted(kept_awake_by)
        what = f"NM state {state}" + ("" if want is None else f", kept awake by {', '.join(want) or 'nobody'}")
        return self._until("expect_state", lambda r: r.state == state and (want is None or sorted(r.kept_awake_by) == want),
                           timeout_ms, what, state)

    def expect_asleep(self, timeout_ms: float = 1000) -> NmReading:
        """expect_state("asleep", timeout_ms): nothing heard within the cluster's timeout."""
        __tracebackhide__ = True
        return self.expect_state("asleep", timeout_ms)

    def __repr__(self) -> str:
        return f"<NmListener {self.channel.name}>"


def _said(r):
    """What a reading was, for a Timeout's message."""
    if not r.heard:
        return f"it was {r.state}, no NM frame read ({r.cluster}, from {r.origin})"
    text = f"it was {r.state}"
    if r.kept_awake_by:
        text += f", kept awake by {', '.join(r.kept_awake_by)}"
    if r.missing:
        text += f"; missing: {', '.join(r.missing)}"
    return text


def _explicit(who, lo, hi, ext, timeout_ms):
    """A range a script states, checked before the library is asked."""
    _int(who, "lo", lo, 0, 0x1FFF_FFFF)
    _int(who, "hi", hi, 0, 0x1FFF_FFFF)
    if lo > hi:
        raise ValueError(f"{who}: lo 0x{lo:X} is above hi 0x{hi:X}")
    _int(who, "timeout_ms", timeout_ms, 1, 60000)
    return lo, hi, bool(ext), timeout_ms
