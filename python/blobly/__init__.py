"""blobly — the Blobly Net engine in this Python process, through libblobly's C ABI (cmd/libblobly).

    import blobly
    with blobly.Project("projects/sim-demo.blobnet") as net:
        can1 = net.channels.CAN1
        net.on_message(can1, can1.messages.Response, lambda f: print("answer", can1.decode(f)))
        net.on_timer(100, lambda: can1.messages.Request.send(ReqCode=5))
        net.run(1000)

See docs/scripting_python.md."""
from ._lib import (BloblyError, CarrierFailed, NegativeResponse, PendingExpired, Refused, Timeout,
                   UndecodableAnswer)
from . import e2e
from .events import EventLoop
from .faults import FaultKind, FaultRefused
from .project import Channel, Channels, Frame, Message, Messages, Project, Signal, Signals
from .uds import (Dtc, Exchange, Extended, FunctionalReply, Snapshot, SnapshotId, SnapshotRecord, UdsClient,
                  reference_key)

try:
    from ._version import __version__  # written into a wheel by scripts/build_wheel.py, from v.mod
except ImportError:  # a source checkout: version() says which engine it loaded
    __version__ = "0+source"


def init():
    """Loads the library. Call it on the main thread before any other thread calls in: bb.h
    requires the library be loaded there (any first call on the main thread does the same)."""
    from . import _lib
    _lib.lib()


def version():
    """libblobly's version (v.mod's)."""
    from . import _lib
    return _lib.text(_lib.lib().bb_version())


def wait_released(timeout_ms=None):
    """Waits until the process is free for a start (True), or timeout_ms passes (False; None
    waits for ever). A stop that returned False left a loop letting go of its wires."""
    from . import _lib
    from .project import _ms
    return _lib.check(_lib.lib().bb_wait_released(_ms(timeout_ms))) == 0


__all__ = ["BloblyError", "CarrierFailed", "Channel", "Channels", "Dtc", "EventLoop", "Exchange", "Extended",
           "Frame", "FunctionalReply", "Message", "Messages", "NegativeResponse", "PendingExpired", "Project",
           "Refused", "Signal", "Signals", "Snapshot", "SnapshotId", "SnapshotRecord", "Timeout", "UdsClient",
           "UndecodableAnswer", "init", "reference_key", "version", "wait_released"]
# fault injection and E2E Profile 1 (faults.py, e2e.py)
__all__ += ["FaultKind", "FaultRefused", "e2e"]
