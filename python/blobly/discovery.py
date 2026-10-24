"""discovery — the interfaces present to open, as the GUI's Discover dialog lists them, and a bus
opened by its address with no project row:

    import blobly
    for i in blobly.interfaces():
        print(i.address, i.kind, i.description)
    with blobly.open("vcan0") as bus:
        bus.send(0x123, b"\\x01")

Vector application-channel assignment is blobly.vector."""
import ctypes
import warnings
from dataclasses import dataclass

from . import _lib
from .events import _on_thread
from .project import Bus

__all__ = ["Interface", "discover_cansub", "interfaces", "open"]

# enum bb_iface_text
_ADDRESS, _KIND, _DESC, _STATE = 0, 1, 2, 3
# enum bb_fd
_FD = {-1: None, 0: False, 1: True}


@dataclass(frozen=True)
class Interface:
    """One interface present now. `address` is what blobly.open (and a project row's interface)
    takes; `kind` is "socketcan", "vcan", "pcan", "kvaser", "vector", "cansub", "bridge", "udp" or
    "inproc"; `description` is for a person; `fd` whether it carries CAN-FD, None where nothing
    asked could say; `bitrate` the nominal rate it is configured for where the system says (a
    SocketCAN link that is up), else 0; `virtual` a software bus (a vcan too) or a vendor's virtual channel;
    `state` a Vector application channel's, "assigned" or "hardware not present", else ""."""
    address: str
    kind: str
    description: str
    fd: bool | None
    bitrate: int
    virtual: bool
    state: str


def _read(listing):
    """The rows of listing `listing`, which is freed; and its note."""
    lib = _lib.lib()
    try:
        out = []
        for i in range(_lib.check(lib.bb_listing_count(listing))):
            info = _lib.BbIface()
            _lib.check(lib.bb_iface_info(listing, i, ctypes.byref(info)))
            out.append(Interface(*(_lib.string(lib.bb_iface_text, listing, i, w) for w in (_ADDRESS, _KIND, _DESC)),
                                 _FD.get(info.fd), info.bitrate, bool(info.is_virtual),
                                 _lib.string(lib.bb_iface_text, listing, i, _STATE)))
        return out, _lib.string(lib.bb_listing_note, listing)
    finally:
        lib.bb_listing_free(listing)


def interfaces() -> list[Interface]:
    """Every interface known without a network wait: SocketCAN links (down ones too), the vendor
    channels the installed drivers report (PCAN, Kvaser, Vector application channels with hardware
    assigned — on Windows), the software buses, and the channels of a connected CAN bridge. A
    CANsub is found by discover_cansub, which waits."""
    return _read(_lib.check(_lib.lib().bb_ifaces()))[0]


def discover_cansub(window_ms: int = 700) -> list[Interface]:
    """The CANsub channels an mDNS browse finds in window_ms (1 to 10000), which it waits in full;
    a row per channel. Refused when no browse was possible (no network interface could be asked),
    which is not the same as nothing attached; a RuntimeWarning names the interfaces that could
    not be asked when some could. Ctrl-C ends the wait (the browse finishes on its thread)."""
    if isinstance(window_ms, bool) or not isinstance(window_ms, int):
        raise TypeError(f"discover_cansub: window_ms is a whole number of milliseconds, not {window_ms!r}")
    if not -2**31 <= window_ms < 2**31:  # a C int: wider would wrap into the range
        raise ValueError(f"discover_cansub: a window is 1 to 10000 ms, not {window_ms}")
    lib = _lib.lib()
    rows, note = _on_thread(lambda: _read(_lib.check(lib.bb_ifaces_cansub(window_ms))), "blobly-cansub")
    if note:
        warnings.warn(f"CANsub browse: {note}", RuntimeWarning, stacklevel=2)
    return rows


def open(address: str) -> Bus:  # noqa: A001 — blobly.open, as the builtin opens a file
    """A Bus on `address` — any interface a project row could name ("vcan0", "inproc:X",
    "pcan:PCAN_USBBUS1@500000", "vector:1@500000/2000000", "cansub:<id>/<ch>", "bridge:<distro>/vcan0"),
    with or without a project loaded. Its sends are checked against the loaded project's wire
    policy, as a row's are. Refused (BloblyError) when it will not open; a DoIP or SOME/IP endpoint
    carries no CAN frames and is refused too. Close it, or use it as a context manager."""
    return Bus(address)
