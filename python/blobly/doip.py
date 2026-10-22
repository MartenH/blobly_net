"""doip — DoIP (ISO 13400) discovery through libblobly, as the Lua doip.discover and doip.listen:
a channel's entity asked who it is, and the announcements entities send unasked, heard for a
window. UDS over a DoIP channel is its UdsClient (Channel.uds)."""
import ctypes
from dataclasses import dataclass

from . import _lib
from ._lib import BloblyError

# room for every announcement a window hears in one call; one past it is said, not dropped silently
_CAP = 1024


@dataclass(frozen=True)
class DoipAnnouncement:
    """What a DoIP entity says about itself, asked (Channel.discover) or unasked (doip_listen):
    `vin` (None when it has none: ISO 13400 fills an unconfigured one with 0x00 or 0xFF), its
    `logical_address`, `eid` (entity id, often its MAC address) and `gid` (group id), 6 bytes
    each, and `source`, the "host:port" it came from — which a tester dials, since a VIN and a
    logical address are not routable."""
    vin: str | None
    logical_address: int
    eid: bytes
    gid: bytes
    source: str


def _announcement(a: _lib.BbDoipAnnouncement) -> DoipAnnouncement:
    vin = _lib.text(a.vin)
    return DoipAnnouncement(vin or None, a.logical_address, bytes(a.eid), bytes(a.gid), _lib.text(a.source))


def _ms(who: str, ms: object) -> int:
    """A wait in whole milliseconds: bounded, so a number from 0 up."""
    if isinstance(ms, bool) or not isinstance(ms, (int, float)) or ms != ms or ms in (float("inf"), float("-inf")):
        raise TypeError(f"{who}: a wait is a finite number of milliseconds, not {ms!r}")
    if not 0 <= ms <= 0x7FFF_FFFF:
        raise ValueError(f"{who}: a wait of {ms} ms")
    return int(ms)


def _row(who: str, channel) -> tuple[int, int]:
    """(channel's row, the run) of a started project: the library reads the row as the run has it,
    so neither a stop nor a load waits for the call (checked again after it, _same_run)."""
    with _lib.state_lock:
        channel._current()
        if not channel._project.started:
            raise BloblyError(f"{who}: {channel.name}: the project is not started", _lib.BB_ERR_STATE)
        return channel._index, _lib.state["run"]


def discover(channel, timeout_ms: float = 1200) -> DoipAnnouncement:
    """Channel.discover."""
    wait = _ms("discover", timeout_ms)
    lib = _lib.lib()
    out = _lib.BbDoipAnnouncement()
    index, run = _row("discover", channel)
    _lib.check(lib.bb_doip_discover(index, wait, ctypes.byref(out)))
    channel._same_run(run)  # a restart meanwhile may have put another row at its index
    return _announcement(out)


def doip_listen(window_ms: float = 1000, *, port: int | None = None, ip6: bool = False,
                channel=None) -> list[DoipAnnouncement]:
    """The announcements DoIP entities send unasked (ISO 13400-2), heard for `window_ms`, in the
    order heard — the way a tester finds ECUs nobody told it about: every one, an entity repeating
    itself included. Nothing is queued for a listener that is not there, so it hears only what is
    sent within its window.

    `port` is the UDP port (None: 13400); `ip6` listens over IPv6, joining ff02::1. `channel`, a
    DoIP Channel of the started project, listens on the port its entity is on in the run, and over
    IPv6 when its address is IPv6 (a `port` that contradicts it is refused). Refused while a
    listener of this process holds the port exclusively (a SOME/IP row)."""
    window = _ms("doip_listen", window_ms)
    if port is not None and (isinstance(port, bool) or not isinstance(port, int)):
        raise TypeError(f"doip_listen: a port is an int, not {port!r}")
    if not isinstance(ip6, bool):
        raise TypeError(f"doip_listen: ip6 is True or False, not {ip6!r}")
    lib = _lib.lib()
    out = (_lib.BbDoipAnnouncement * _CAP)()
    p = 0 if port is None else port
    if not 0 <= p <= 0xFFFF:
        raise ValueError(f"doip_listen: {port} is not a port")
    if channel is None:
        n = _lib.check(lib.bb_doip_listen(p, window, int(ip6), None, out, _CAP))
    else:
        from .project import Channel  # project imports this module
        if not isinstance(channel, Channel):
            raise TypeError(f"doip_listen: channel is a Channel, not {channel!r}")
        index, run = _row("doip_listen", channel)
        n = _lib.check(lib.bb_doip_listen(p, window, int(ip6), ctypes.byref(ctypes.c_int(index)), out, _CAP))
        channel._same_run(run)
    if n > _CAP:
        raise BloblyError(f"doip_listen: {n} announcements in {window} ms, more than the {_CAP} kept; "
                          "listen for a shorter window")
    return [_announcement(out[i]) for i in range(n)]
