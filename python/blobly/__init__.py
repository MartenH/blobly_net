"""blobly — the Blobly Net engine in this Python process, through libblobly's C ABI (cmd/libblobly).

    import blobly
    with blobly.Project("projects/sim-demo.blobnet") as net:
        can1 = net.channels.CAN1
        net.on_message(can1, 0x102, lambda f: print("answer", f))
        net.on_timer(100, lambda: can1.send(0x101, b"\\x05"))
        net.run(1000)

See docs/scripting_python.md."""
from ._lib import BloblyError
from .events import EventLoop
from .project import Channel, Channels, Frame, Project


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


__all__ = ["BloblyError", "Channel", "Channels", "EventLoop", "Frame", "Project", "init", "version",
           "wait_released"]
