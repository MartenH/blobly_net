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


__all__ = ["BloblyError", "Channel", "Channels", "EventLoop", "Frame", "Project", "init", "version"]
