"""metrics — a channel's bus metrics during a run (Channel.load, Channel.diagnostics), as its bus
handle counts them: the engine's transport.LoadMeter and the backend's diagnostics counts."""
import ctypes
from typing import NamedTuple

from . import _lib


class BusLoad(NamedTuple):
    """The load of the frames a channel's handle carried: DECODED frames only, both directions —
    what it received (counted when read: a frame left queued lands in the second it is read) and
    what it sent. Error frames, retransmissions and overrun drops occupied the wire and are not in
    it. A frame costs its bit-times with worst-case stuffing, the GUI's bus load."""
    percent: float | None  # over the last whole second; None until one has passed
    average: float | None  # since the handle opened; None until one second has passed
    frames: int  # counted since open
    bits: float  # their nominal bit-times
    nominal: int  # the arbitration rate they are priced at, bit/s


class BusDiagnostics(NamedTuple):
    """What the backend counted since the handle opened that no frame carried; on a wire shared
    through one driver handle (PCAN, CANsub, the CAN bridge), the wire's since it opened."""
    dropped: int  # records lost before delivery: a reader that fell behind, a driver overrun
    bus_errors: int  # controller error records the device reported
    decode_errors: int  # records the backend could not decode


def load_of(h):
    """BusLoad of bus handle h."""
    out = _lib.BbBusload()
    _lib.check(_lib.lib().bb_bus_load(h, ctypes.byref(out)))
    return BusLoad(None if out.percent < 0 else out.percent, None if out.average < 0 else out.average, out.frames, out.bits, out.nominal)


def diagnostics_of(h):
    """BusDiagnostics of bus handle h."""
    out = _lib.BbDiagnostics()
    _lib.check(_lib.lib().bb_bus_diagnostics(h, ctypes.byref(out)))
    return BusDiagnostics(out.dropped, out.bus_errors, out.decode_errors)
