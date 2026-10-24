"""blobly — the Blobly Net engine in this Python process, through libblobly's C ABI (cmd/libblobly).

    import blobly
    with blobly.Project("projects/sim-demo.blobnet") as net:
        can1 = net.channels.CAN1
        net.on_message(can1, can1.messages.Response, lambda f: print("answer", can1.decode(f)))
        net.on_timer(100, lambda: can1.messages.Request.send(ReqCode=5))
        net.run(1000)

See docs/scripting_python.md."""
from ._lib import (BloblyError, Cancelled, CarrierFailed, ConnectionLost, FlashFailed, NegativeResponse,
                   PendingExpired, Refused, RoutingDenied, Timeout, UndecodableAnswer)
from . import e2e, flash, someip
from .doip import DoipAnnouncement, doip_listen
from .flash import BootReport, BootSim, FlashReport
from .someip import SomeipHeard, SomeipMessage
from .events import EventLoop
from .faults import FaultKind, FaultRefused
from .project import Channel, Channels, Frame, Message, Messages, Project, Signal, Signals
from .uds import (Dtc, Exchange, Extended, FunctionalReply, Snapshot, SnapshotId, SnapshotRecord, UdsClient,
                  reference_key)

__version__: str
try:
    # written into a wheel by scripts/build_wheel.py, from v.mod; `as` re-exports it to a type checker
    from ._version import __version__ as __version__
except ImportError:  # a source checkout: version() says which engine it loaded
    __version__ = "0+source"


def init() -> None:
    """Loads the library. Call it on the main thread before any other thread calls in: bb.h
    requires the library be loaded there (any first call on the main thread does the same)."""
    from . import _lib
    _lib.lib()


def version() -> str:
    """libblobly's version (v.mod's)."""
    from . import _lib
    return _lib.text(_lib.lib().bb_version())


def now_ms() -> float:
    """The host's monotonic clock in ms: the clock of a received Frame's t_ms."""
    from . import _lib
    return _lib.ms_of(_lib.lib().bb_now_ns())


def wait_released(timeout_ms: float | None = None) -> bool:
    """Waits until the process is free for a start (True), or timeout_ms passes (False; None
    waits for ever). A stop that returned False left a loop letting go of its wires. Ctrl-C ends
    the wait within 100 ms."""
    from . import _lib
    from .events import _sliced
    from .project import _ms
    ms = _ms(timeout_ms)
    lib = _lib.lib()

    def free(part):  # True, or None while a loop is still letting go; any other answer is False
        rc = _lib.check(lib.bb_wait_released(part))
        return None if rc == _lib.BB_RELEASING else rc == 0
    # a last look once the wait is over: unlike a frame, a release is not consumed by asking
    return _sliced(free, ms) is True or free(0) is True


__all__ = ["BloblyError", "Cancelled", "CarrierFailed", "Channel", "Channels", "Dtc", "EventLoop", "Exchange",
           "Extended", "Frame", "FunctionalReply", "Message", "Messages", "NegativeResponse", "PendingExpired", "Project",
           "Refused", "Signal", "Signals", "Snapshot", "SnapshotId", "SnapshotRecord", "Timeout", "UdsClient",
           "UndecodableAnswer", "init", "now_ms", "reference_key", "version", "wait_released"]
# fault injection and E2E Profile 1 (faults.py, e2e.py)
__all__ += ["FaultKind", "FaultRefused", "e2e"]
# DoIP (doip.py; UDS over DoIP is UdsClient)
__all__ += ["ConnectionLost", "DoipAnnouncement", "RoutingDenied", "doip_listen"]
# SOME/IP (someip.py) and flashing (flash.py)
__all__ += ["SomeipHeard", "SomeipMessage", "someip"]
__all__ += ["BootReport", "BootSim", "FlashFailed", "FlashReport", "flash"]
# replay and recording (replay.py)
from .replay import RecordCounts, Recording, Replay, ReplayStatus  # noqa: E402
__all__ += ["RecordCounts", "Recording", "Replay", "ReplayStatus"]
# the CAN bridge into WSL (bridge.py)
from . import bridge  # noqa: E402
__all__ += ["bridge"]
# bus metrics (metrics.py; Channel.load, Channel.diagnostics)
from .metrics import BusDiagnostics, BusLoad  # noqa: E402
__all__ += ["BusDiagnostics", "BusLoad"]
# generator control (generators.py)
from .generators import Generator, GeneratorRefused, Generators  # noqa: E402
__all__ += ["Generator", "GeneratorRefused", "Generators"]
# the system model: nodes, their DIDs by name (nodes.py)
from ._lib import WriteGated  # noqa: E402
from .nodes import Did, DidPart, Dids, Fault, Gate, Node, NodeClient, NodeFaults, Nodes, NodeTarget  # noqa: E402
__all__ += ["Did", "DidPart", "Dids", "Fault", "Gate", "Node", "NodeClient", "NodeFaults", "NodeTarget", "Nodes",
            "WriteGated"]
# raw ISO-TP (isotp.py; Channel.isotp)
from .isotp import IsoTp  # noqa: E402
__all__ += ["IsoTp"]
# E2E verdicts on received frames (e2e.py; Frame.e2e, expect(..., e2e=True))
from .e2e import E2eError, E2eStatus  # noqa: E402
__all__ += ["E2eError", "E2eStatus"]
# interfaces present, a bus by its address, Vector assignment (discovery.py, vector.py)
from .project import Bus  # noqa: E402
from .discovery import Interface, discover_cansub, interfaces  # noqa: E402
# blobly.open, re-exported but not in __all__: `from blobly import *` must not replace the builtin
from .discovery import open as open  # noqa: E402
from . import vector  # noqa: E402
from .vector import VectorHardware  # noqa: E402
__all__ += ["Bus", "Interface", "VectorHardware", "discover_cansub", "interfaces", "vector"]
# background cyclic senders (cyclic.py; Channel.send_cyclic, Message.send_cyclic) and the UDS keep-alive
from .cyclic import CyclicSender, CyclicStatus  # noqa: E402
from .uds import KeepAliveStatus, KeepAliveWarning  # noqa: E402
__all__ += ["CyclicSender", "CyclicStatus", "KeepAliveStatus", "KeepAliveWarning"]
# J1939: the transport protocol rejoined and the address directory (j1939.py; Channel.j1939)
from .j1939 import J1939Address, J1939Fault, J1939Listener, J1939Message, J1939Name  # noqa: E402
__all__ += ["J1939Address", "J1939Fault", "J1939Listener", "J1939Message", "J1939Name"]
