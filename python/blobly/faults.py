"""faults — making a started project's simulated ECUs misbehave on purpose, as Lua's sim.fault does:
a message dropped, its checksum broken, its E2E counter frozen, or a signal forced past its declared
range. Which faults may be armed is the engine's rule (sim.FaultTarget.arm, the one Lua asks):
this module carries the call and types the refusal."""
import enum
import math
import numbers
from typing import TYPE_CHECKING

from . import _lib
from ._lib import Refused

if TYPE_CHECKING:
    from .project import Channel, Message, Signal


class FaultKind(enum.StrEnum):
    """What a fault does to a simulated message. Its plain string ("drop", ...) works as well."""
    DROP = "drop"                      # not sent: the receiver's timeout handling
    BAD_CRC = "bad_crc"                # sent with its E2E checksum inverted
    FREEZE_COUNTER = "freeze_counter"  # sent, its E2E alive counter stopped
    OUT_OF_RANGE = "out_of_range"      # sent with one signal past its declared range


class FaultRefused(Refused):
    """The engine refused a fault that could not take effect, rather than arm one that changes
    nothing: a DoIP or SOME/IP channel, an unknown kind, a node not simulated on that channel, a
    message the node does not send, bad_crc where the node stamps no checksum, freeze_counter where it stamps no E2E
    counter, out_of_range where no signal can carry a value outside its range. Nothing was armed."""


class Faults:
    """Fault injection on the project's run, for Project (it supplies _resolve). The faults are the
    process's: a start clears them, and otherwise they last until cleared or their time runs
    out."""

    def fault(self, channel: "Channel | str", node: str, message: "Message | str", kind: FaultKind | str,
              ms: float | None = None, signal: "Signal | str | None" = None) -> None:
        """Arms `kind` on the simulated `node`'s `message` on `channel` (a Channel or its name; a
        Message or its name): for `ms` milliseconds, rounded up, or until cleared (None). A fault
        is keyed by the message's name, so a name the node sends at two ids reaches both: a Message
        whose name another message of its channel shares is refused (ValueError) rather than
        broadened.
        `signal` (a Signal or its name) is the one out_of_range forces; None lets the engine choose
        one that can carry the violation. Raises FaultRefused where the fault could not take
        effect, and BloblyError (code -3) when the project is not started."""
        self._arm(channel, node, message, kind, _duration(ms), signal)

    def clear_fault(self, channel: "Channel | str", node: str, message: "Message | str") -> None:
        """Lifts the fault on the simulated `node`'s `message` on `channel`."""
        self._arm(channel, node, message, "clear", 0, None)

    def clear_faults(self) -> None:
        """Lifts every fault."""
        _lib.check(_lib.lib().bb_sim_clear_faults())

    def _arm(self, channel, node, message, kind, ms, signal):
        from .project import Message, Signal
        lib = _lib.lib()
        with _lib.state_lock:
            c = self._resolve(channel)
            if isinstance(message, Message):
                if message.channel is not c:
                    raise ValueError(f"{message.name} is a message of {message.channel.name}, not of {c.name}")
                message._live()  # a Message of an earlier run its database no longer has refuses
                # the fault table keys a message by name: one of a shared name would reach them all
                if sum(m.name == message.name for m in c.messages) > 1:
                    raise ValueError(f"{c.name} has more than one message named {message.name}, and a "
                                     "fault is keyed by name, so it would reach every one; pass the "
                                     "name to mean all of them")
                message = message.name
            if isinstance(signal, Signal):
                signal = signal.name
            rc = lib.bb_sim_fault(c._index, _text("node", node), _text("message", message),
                                  _text("kind", kind), ms, None if signal is None else _text("signal", signal))
            if rc == _lib.BB_ERR:
                raise FaultRefused(_lib.text(lib.bb_last_error()), rc)
            _lib.check(rc)


def _text(name, v):
    if not isinstance(v, str):
        raise TypeError(f"{name} must be a string, not {v!r}")
    if "\0" in v:
        raise ValueError(f"{name} cannot carry a NUL: C would read it cut short")
    return v.encode()


def _duration(ms):
    """A fault's lifetime as bb_sim_fault takes it: whole milliseconds rounded UP (a fault lasts
    at least what was asked; down, a fraction would be 0, which is until cleared), 0 for None."""
    if ms is None:
        return 0
    if isinstance(ms, bool) or not isinstance(ms, numbers.Real) or not math.isfinite(ms):
        raise TypeError("ms must be a finite number of milliseconds, or None for until cleared")
    if ms <= 0:
        raise ValueError(f"ms {ms}: a fault lasts more than 0 ms, or None for until cleared")
    whole = math.ceil(ms)
    if whole > 2**31 - 1:
        raise ValueError(f"ms {ms} is longer than a fault can last (2**31 - 1 ms); use None for until cleared")
    return whole
