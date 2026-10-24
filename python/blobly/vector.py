"""vector — Vector XL application channels (docs/scripting_python.md, "Vector channel assignment"):
the XL library opens APPLICATION channels (`vector:<n>`), which must be mapped to a physical
channel first, as Vector Hardware Manager or the GUI's Discover dialog does. These are that
dialog's reads and its Assign, with its refusals. Windows only: elsewhere driver() says why,
assignments() is [] and slot() and assign() are refused.

    from blobly import vector
    hw = next(h for h in vector.assignments() if h.can and h.app == 0)
    vector.assign(1, hw)             # vector:1 now reaches it"""
import ctypes
from dataclasses import dataclass

from . import _lib

__all__ = ["VectorHardware", "assign", "assignments", "driver", "slot"]

# enum bb_vector_slot
SLOTS = {0: "unreadable", 1: "absent", 2: "empty", 3: "taken"}
# enum bb_vector_text
_NAME, _TRANSCEIVER = 0, 1


@dataclass(frozen=True)
class VectorHardware:
    """One physical channel the Vector driver lists, and the application channel pointing at it.
    `app` is that channel (vector:<app>), 0 when none; `owner_known` False says some application
    channel would not answer, so app 0 is no proof it is free (assign refuses it then). `can` says
    it is a CAN channel (only those can be assigned); `fd_iso` ISO CAN-FD, which this backend
    speaks, `fd_bosch` Bosch CAN-FD; `bitrate` and `on_bus` what it is configured for now.
    `hw_type`, `hw_index` and `hw_channel` are the driver's identity of it."""
    name: str
    transceiver: str
    hw_type: int
    hw_index: int
    hw_channel: int
    serial: int
    bitrate: int
    app: int
    owner_known: bool
    can: bool
    fd_iso: bool
    fd_bosch: bool
    on_bus: bool


def driver() -> str | None:
    """None when the Vector XL driver can be used here; otherwise why not (vxlapi64.dll missing,
    no hardware, or not Windows)."""
    return _lib.string(_lib.lib().bb_vector_driver) or None


def assignments() -> list[VectorHardware]:
    """Every physical channel the driver lists, with the application channel pointing at it; []
    where the driver cannot be used (driver() says why)."""
    lib = _lib.lib()
    listing = _lib.check(lib.bb_vector_hardware())
    try:
        out = []
        for i in range(_lib.check(lib.bb_listing_count(listing))):
            h = _lib.BbVectorHw()
            _lib.check(lib.bb_vector_info(listing, i, ctypes.byref(h)))
            out.append(VectorHardware(_lib.string(lib.bb_vector_text, listing, i, _NAME),
                                      _lib.string(lib.bb_vector_text, listing, i, _TRANSCEIVER),
                                      h.hw_type, h.hw_index, h.hw_channel, h.serial, h.bitrate, h.app,
                                      bool(h.owner_known), bool(h.can), bool(h.fd_iso), bool(h.fd_bosch),
                                      bool(h.on_bus)))
        return out
    finally:
        lib.bb_listing_free(listing)


def _app(app):
    if isinstance(app, bool) or not isinstance(app, int):
        raise TypeError(f"a Vector application channel is an int 1..64, not {app!r}")
    return app


def slot(app: int) -> str:
    """What the driver says of application channel `app` (1..64): "taken" (pointing at hardware),
    "empty" (registered, pointing at nothing), "absent" (not registered: assigning it creates it)
    or "unreadable" (the driver would not say). Refused where the driver cannot be used."""
    return SLOTS[_lib.check(_lib.lib().bb_vector_slot(_app(app)))]


def assign(app: int, hw: VectorHardware, *, create: bool = False) -> None:
    """Points application channel `app` (1..64, vector:<app>) at `hw`, a row of assignments(), as
    the Discover dialog's Assign does; the mapping persists across reboots. Refused (Refused,
    nothing written) where the driver cannot be used, `hw` is not a CAN channel or is already
    assigned (or may be: an application channel would not answer), `app` is taken or unreadable,
    or `app` is absent — not registered — unless create=True says creating it is what you mean:
    the driver reports "not registered" with the same generic error a momentary read failure on an
    occupied channel gives, so creating is never assumed."""
    if not isinstance(hw, VectorHardware):
        raise TypeError(f"assign: hw is a VectorHardware from vector.assignments(), not {hw!r}")
    _lib.check(_lib.lib().bb_vector_assign(_app(app), hw.hw_type, hw.hw_index, hw.hw_channel, int(bool(create))))
