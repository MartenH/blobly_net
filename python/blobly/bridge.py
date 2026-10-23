"""bridge — the CAN bridge into WSL (docs/wsl_bridge.md), as the GUI's Discover dialog drives it:
on Windows, `canbridge` run inside a WSL distribution carries that distribution's CAN interfaces to
this process as `bridge:<distribution>/<interface>` channels. Opening such a channel starts its
bridge by itself; these functions do it explicitly. On Linux there are no distributions and start
is refused, saying so.

    from blobly import bridge
    bridge.distributions()            # ['Ubuntu-24.04']
    bridge.start("Ubuntu-24.04")      # ['bridge:Ubuntu-24.04/vcan0', 'bridge:Ubuntu-24.04/vcan1']
    bridge.stop("Ubuntu-24.04")"""
import ctypes
import time

from . import _lib
from ._lib import BloblyError

__all__ = ["distributions", "program", "rows", "start", "state", "stop"]

# enum bb_bridge_state, as the GUI's Discover dialog names the states
STATES = {0: "idle", 1: "starting", 2: "connected", 3: "failed"}

# how often start(wait=True) looks at the bridge while it starts
_POLL_S = 0.05


def _lines(s: str) -> list[str]:
    return [x for x in s.split("\n") if x]


def _name(distro: str) -> bytes:
    if not isinstance(distro, str) or not distro:
        raise TypeError(f"a WSL distribution is a non-empty name, not {distro!r}")
    return distro.encode()


def distributions() -> list[str]:
    """The WSL distributions installed for this user, sorted; [] where WSL is not (Linux too)."""
    return _lines(_lib.string(_lib.lib().bb_wsl_distros))


def program() -> str | None:
    """The `canbridge` a start runs: the one beside the library (a wheel carries it), else beside
    the executable; None when there is none, and a start then runs the distribution's own from its
    PATH. Always None on Linux."""
    return _lib.string(_lib.lib().bb_bridge_program) or None


def state(distro: str) -> tuple[str, str]:
    """Where the bridge of `distro` stands, and why when it failed ("" otherwise): "idle",
    "starting", "connected" or "failed"."""
    lib, name = _lib.lib(), _name(distro)
    st = ctypes.c_int()
    why = _lib.string(lambda buf, cap: lib.bb_bridge_state(name, ctypes.byref(st), buf, cap))
    return STATES.get(st.value, f"state {st.value}"), why


def rows(distro: str) -> list[str]:
    """The channels a connected bridge offers, as interfaces a project row or Channel opens
    ("bridge:<distro>/vcan0"); [] when it is not connected."""
    lib, name = _lib.lib(), _name(distro)
    return _lines(_lib.string(lambda buf, cap: lib.bb_bridge_rows(name, buf, cap)))


def start(distro: str, wait: bool = True) -> list[str] | None:
    """Starts the bridge in `distro` (as root, so it can create vcan0 and vcan1), unless it is
    connected or starting. With `wait`, returns its rows() once it has dialled in, and raises
    BloblyError with its reason if it fails — the engine gives it 20 s; without, returns None once
    it is launched, and state() follows it. Raises Refused where it cannot be launched: no such
    distribution, wsl.exe missing, or not on Windows."""
    lib, name = _lib.lib(), _name(distro)
    _lib.check(lib.bb_bridge_start(name))
    if not wait:
        return None
    while True:
        st, why = state(distro)
        if st == "connected":
            return rows(distro)
        if st == "failed":
            raise BloblyError(f'bridge "{distro}": {why}')
        if st == "idle":  # dialled in and went again between two looks, or stopped elsewhere
            raise BloblyError(f'bridge "{distro}" dialled in and is gone again')
        time.sleep(_POLL_S)


def stop(distro: str) -> None:
    """Disconnects the bridge of `distro`, which ends it, and returns once it has gone: every
    channel open on it fails. Raises BloblyError (code -3) when it is not connected (one still
    starting cannot be reached until it dials in), or while a project is started; Timeout when its
    connection was cut but it had not gone within 2 s."""
    lib, name = _lib.lib(), _name(distro)
    with _lib.state_lock:
        _lib.check(lib.bb_bridge_stop(name))
