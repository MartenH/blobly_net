"""generators — a started project's generators (its `senders:`), as Lua's gen.* has them: fire one,
start and stop its cycle, change the cycle, and put a signal at a value or on a value source. The
rules are the engine's (blobly/headless/generators.v, blobly/sim/gencontrol.v); this module carries
the calls and types the refusals."""
import ctypes
import math
import numbers

from . import _lib
from ._lib import BloblyError, Refused
from .events import _on_thread


class GeneratorRefused(Refused):
    """The engine refused a generator call that could not take effect: a cycle outside 1 .. 3600000
    ms, a start with no cycle, a signal the message does not have (or a raw frame's), a non-finite
    value, a source that cannot be evaluated, a generator with nothing to send on, or a send its
    bus refused (a listen-only row). Nothing changed."""


class Generator:
    """One generator of the run: `name`, `channel` (the name of the channel it is written under),
    `message` (its DBC message, "" for a raw frame) and `trigger` ("manual", "key" or "cyclic", as
    the project writes it) are fixed; `id`, `ext`, `running`, `cycle_ms`, `sent` (frames its bus
    took), `target` (the interface it sends on) and `note` (why it cannot send, "" when it can) are
    read from the run as they are now. It belongs to the run that listed it: after a stop and a
    start it goes on working while the run has a generator of its name and channel at its
    position, and refuses otherwise."""

    def __init__(self, project, index, name, channel, run):
        self._project, self._index, self.name, self.channel, self._run = project, index, name, channel, run
        lib = _lib.lib()
        self.message = _lib.string(lib.bb_gen_text, index, _lib.GEN_MESSAGE)
        self.trigger = _lib.string(lib.bb_gen_text, index, _lib.GEN_TRIGGER)

    def _live(self):
        """Refuses unless this generator is the current run's."""
        self._project.generators  # re-read after a start: keeps this object if it is still there
        if self._run != _lib.state["run"]:
            raise BloblyError(f"generator {self.name!r} is not in this run; take it from "
                              "project.generators again", _lib.BB_ERR_STATE)

    def _call(self, fn, *args):
        lib = _lib.lib()
        with _lib.state_lock:  # a stop and start on another thread cannot move this index
            self._live()
            rc = fn(lib)(self._index, *args)
            if rc == _lib.BB_ERR:
                raise GeneratorRefused(_lib.text(lib.bb_last_error()), rc)
            return _lib.check(rc)

    def _info(self):
        info = _lib.BbGenerator()
        self._call(lambda lib: lib.bb_gen_info, ctypes.byref(info))
        return info

    @property
    def id(self) -> int:
        return self._info().id

    @property
    def ext(self) -> bool:
        return bool(self._info().ext)

    @property
    def running(self) -> bool:
        """Sending on its cycle now."""
        return bool(self._info().running)

    @property
    def sent(self) -> int:
        """Frames its bus took, fired and cyclic alike."""
        return self._info().sent

    @property
    def cycle_ms(self) -> int:
        """Its cycle in ms, 0 for none. Set it (1 .. 3600000) to change it from the next frame."""
        return self._info().cycle_ms

    @cycle_ms.setter
    def cycle_ms(self, ms: int) -> None:
        self._call(lambda lib: lib.bb_gen_cycle, _cycle(ms))

    @property
    def target(self) -> str:
        return self._text(_lib.GEN_TARGET)

    @property
    def note(self) -> str:
        return self._text(_lib.GEN_NOTE)

    def _text(self, which):
        lib = _lib.lib()
        with _lib.state_lock:
            self._live()
            return _lib.string(lib.bb_gen_text, self._index, which)

    def fire(self, timeout_ms: float = 5000) -> None:
        """Sends its current frame once, returning once the bus took it. Raises GeneratorRefused
        for a bus that refused it, Timeout when the bus did not take it within timeout_ms (at most
        5000, from this call; a first fire opens the bus), BloblyError (code -3) when a stop
        overtook it. The message says whether the frame went out: one the generator had not taken
        up by the deadline is never sent. Ctrl-C ends the wait within 100 ms; the fire then ends
        on its own, within its deadline."""
        if isinstance(timeout_ms, bool) or not isinstance(timeout_ms, numbers.Real) or not math.isfinite(timeout_ms):
            raise TypeError(f"timeout_ms is a finite number of ms, not {timeout_ms!r}")
        if not 0 < timeout_ms <= 5000:
            raise ValueError(f"timeout_ms {timeout_ms}: a fire waits more than 0 and at most 5000 ms")
        lib = _lib.lib()
        until = lib.bb_now_ns() + int(timeout_ms * 1_000_000)  # one deadline for all of it

        def call():
            # the state lock is waited for within the deadline too, and held only to read which
            # run this generator is of: the fire names that run, which the engine refuses once
            # another is started, so a stop waits for nothing here
            left = (until - lib.bb_now_ns()) / 1e9
            if left <= 0 or not _lib.state_lock.acquire(timeout=left):
                raise _lib.Timeout(f"generator {self.name!r}: the project was busy on another thread "
                                   "past the wait; nothing was sent")
            try:
                self._live()
                run = self._engine_run
            finally:
                _lib.state_lock.release()
            rc = lib.bb_gen_fire(self._index, run, until)
            if rc == _lib.BB_ERR:
                raise GeneratorRefused(_lib.text(lib.bb_last_error()), rc)
            _lib.check(rc)
        _on_thread(call, "blobly-fire")

    def start(self, cycle_ms: int | None = None) -> None:
        """Sends it on its cycle from now: `cycle_ms`, or its own for None or 0 (refused when it has
        none)."""
        self._call(lambda lib: lib.bb_gen_start, 0 if cycle_ms is None else _cycle(cycle_ms))

    def stop(self) -> None:
        """Ends its cycle; fire still sends it."""
        self._call(lambda lib: lib.bb_gen_stop)

    def set(self, signal, value: float) -> None:
        """Sends `signal` (a Signal or its name) at the static `value` from the next frame, its value
        source (if it had one) dropped. A signal the generator did not list is added."""
        if isinstance(value, bool) or not isinstance(value, numbers.Real):
            raise TypeError(f"{self.name}: a signal's value is a number, not {value!r}")
        self._call(lambda lib: lib.bb_gen_set, _name(signal), float(value))

    def source(self, signal, kind: str, **params: float) -> None:
        """Puts `signal` (a Signal or its name) on a value source from the next frame: `kind` is
        "const", "sine", "sawtooth", "counter" or "stepmod", with the parameters a project writes
        (const: value; sine: offset, amplitude, freq, phase; sawtooth: min, max, period in s;
        counter: start, step (1 when omitted), modulo; stepmod: period in s, count, base), every
        other 0. One the source cannot be evaluated with (an unknown kind, a zero period or count)
        is refused."""
        w = _lib.BbWave(kind=_text("kind", kind), step=1.0)
        for k, v in params.items():
            if k not in _lib.WAVE_PARAMS:
                raise TypeError(f"no source parameter {k!r}; there are: {', '.join(_lib.WAVE_PARAMS)}")
            if isinstance(v, bool) or not isinstance(v, numbers.Real) or not math.isfinite(v):
                raise TypeError(f"{k} is a finite number, not {v!r}")
            setattr(w, k, float(v))
        self._call(lambda lib: lib.bb_gen_source, _name(signal), ctypes.byref(w))

    def __repr__(self):
        what = self.message or "raw"
        return f"<Generator {self.name!r} {what} on {self.channel} ({self.trigger})>"


class Generators:
    """The run's generators, every CAN channel's in project order (a disabled channel's too: its
    generator may send on an enabled one): `gens["Ping ECU"]` by name, else "channel/name" (a name
    two generators share is refused, naming both forms), `gens[0]` by position, iteration, len."""

    def __init__(self, items, run):
        self._order, self._run = items, run

    def __getitem__(self, key):
        if isinstance(key, int):
            return self._order[key]
        lib = _lib.lib()
        with _lib.state_lock:
            if self._run != _lib.state["run"]:  # the engine's index is the current run's
                raise BloblyError("these are the generators of an earlier run; take project.generators "
                                  "again", _lib.BB_ERR_STATE)
            rc = lib.bb_gen_find(_text("name", key))
            if rc == _lib.BB_ERR:
                raise KeyError(_lib.text(lib.bb_last_error()))
            return self._order[_lib.check(rc)]

    def __iter__(self):
        return iter(self._order)

    def __len__(self):
        return len(self._order)

    def __repr__(self):
        return "<Generators " + ", ".join(repr(g.name) for g in self._order) + ">"


def listed(project, old):
    """The current run's generators, keeping each of `old` still at its position under its name and
    channel; the caller holds the state lock."""
    lib = _lib.lib()
    run = _lib.state["run"]
    engine_run = ctypes.c_int64()
    _lib.check(lib.bb_gen_run(ctypes.byref(engine_run)))  # what a fire names, so it holds no lock
    out = []
    for i in range(_lib.check(lib.bb_gen_count())):
        name = _lib.string(lib.bb_gen_text, i, _lib.GEN_NAME)
        channel = _lib.string(lib.bb_gen_text, i, _lib.GEN_CHANNEL)
        keep = old[i] if old is not None and i < len(old) else None
        if keep is not None and (keep.name, keep.channel) == (name, channel):
            keep._run, keep._engine_run = run, engine_run.value
            keep.message = _lib.string(lib.bb_gen_text, i, _lib.GEN_MESSAGE)  # the project may be edited
            keep.trigger = _lib.string(lib.bb_gen_text, i, _lib.GEN_TRIGGER)
            out.append(keep)
        else:
            g = Generator(project, i, name, channel, run)
            g._engine_run = engine_run.value
            out.append(g)
    return Generators(out, run)


def _cycle(ms):
    """A cycle as the C int it travels in; its range is the engine's to refuse."""
    if isinstance(ms, bool) or not isinstance(ms, numbers.Integral):
        raise TypeError(f"a cycle is a whole number of ms, not {ms!r}")
    if not -2**31 <= ms < 2**31:
        raise GeneratorRefused(f"cycle {ms} ms: a cycle is 1 .. 3600000 ms", _lib.BB_ERR)
    return int(ms)


def _name(signal):
    from .project import Signal
    return _text("signal", signal.name if isinstance(signal, Signal) else signal)


def _text(what, v):
    if not isinstance(v, str):
        raise TypeError(f"{what} must be a string, not {v!r}")
    if "\0" in v:
        raise ValueError(f"{what} cannot carry a NUL: C would read it cut short")
    return v.encode()
