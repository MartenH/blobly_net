"""replay — a recording played onto channels of a started project, and channels recorded to a
candump file, as the Lua replay.start and record.start (blobly/replay through libblobly).

    with net.replay(net.channels.REPLAY1, speed=4, loop=False) as r:
        r.wait_done(5000)
    with net.record("capture.log", net.channels.CAN1) as rec:
        net.run(1000)
    print(rec.counts())

A replay is blobly/player's, the GUI Replay panel's: one clock over every channel it plays onto,
the ECU under test subtracted by DBC sender as each row's `replay:` block says."""
import ctypes
import math
import os
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING, Literal, TypeAlias

from . import _lib
from .events import _sliced

if TYPE_CHECKING:
    from .project import Channel, Project

# what a replay or a recording takes as its channels: a Channel or its name, or several
Targets: TypeAlias = "Channel | str | Sequence[Channel | str]"
# a file's path, as open() takes it
Path: TypeAlias = "str | os.PathLike[str]"


@dataclass(frozen=True)
class ReplayStatus:
    """What a replay is doing: `state` ("playing", "paused", or "finished": a non-looping replay ran
    out), `position_s` and `duration_s` in seconds of the recording, `speed`, `loop`,
    `passes` (complete passes, the last of a non-looping replay included), `sent` and `failed`
    (frames the drivers took and refused since it last started), `error` (the first refusal, ""
    without one) and `ended` (stopped: its buses are let go)."""
    state: str
    position_s: float
    duration_s: float
    speed: float
    loop: bool
    passes: int
    sent: int
    failed: int
    error: str
    ended: bool


@dataclass(frozen=True)
class RecordCounts:
    """What a recording holds: `frames` written, of them `ours` (sent by this process — the tester,
    a simulated ECU or a replay: a ` T` line) and `theirs` (` R`), and `missed`, frames this
    process sent that never came back to the recorder (not written), and `dropped`, frames the
    recorder's own handles lost before it read them (it fell behind)."""
    frames: int
    ours: int
    theirs: int
    missed: int
    dropped: int


def _rows(project: "Project", channels: Targets) -> "tuple[list[Channel], ctypes.Array[ctypes.c_int]]":
    """The Channels `channels` names (a Channel, a name, or a list of them) and their row indexes."""
    from .project import Channel
    many = [channels] if isinstance(channels, (str, Channel)) else list(channels)
    if not many:
        raise ValueError("no channel")
    chans = [project._resolve(c) for c in many]
    return chans, (ctypes.c_int * len(chans))(*[c._index for c in chans])


def _absolute(path: Path) -> str:
    """`path` made absolute by joining, not normalising: `link/..` stays for the filesystem to walk,
    which goes to the link's target's parent."""
    p = os.fspath(path)
    return p if os.path.isabs(p) else os.path.join(os.getcwd(), p)


def _text(name: str, v: "Path | None", path: bool = False) -> bytes | None:
    """`v` as C takes it: a path in the filesystem's encoding (its bytes, undecodable ones too),
    any other text as UTF-8."""
    if v is None:
        return None
    if not isinstance(v, (str, os.PathLike)):
        raise TypeError(f"{name} must be a string, not {v!r}")
    b = os.fsencode(v) if path or isinstance(v, os.PathLike) else v.encode()
    if b"\0" in b:
        raise ValueError(f"{name} cannot carry a NUL: C would read it cut short")
    return b


def _rate(v: object) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0:
        raise ValueError(f"speed {v!r}: a finite rate above 0")
    return float(v)


class Replay:
    """A recording playing onto `channels` (Project.replay). Every control is applied before it
    returns, so status() then says so; they, status() and wait_done() may come from any thread.
    `notes` is what the plan kept and withheld per channel. `with` stops it at the end of the
    block, and so does a stop of the project."""

    channels: "list[Channel]"
    notes: list[str]

    def __init__(self, project: "Project", channels: Targets, source: "Path | None", speed: float | None,
                 loop: bool | None, paused: bool, exclude: Iterable[str] | None, bus: str | None):
        self.channels, rows = _rows(project, channels)
        o = _lib.BbReplayOpts()
        lib = _lib.lib()
        _lib.check(lib.bb_replay_defaults(ctypes.byref(o)))
        o.source = None if source is None else _text("source", _absolute(source), path=True)
        if speed is not None:
            o.speed = _rate(speed)
        if loop is not None:
            o.loop = int(bool(loop))
        o.paused = int(bool(paused))
        if exclude is not None:
            if isinstance(exclude, str):
                raise TypeError("exclude is a list of node names, not one string")
            exclude = list(exclude)  # an iterator is read once
            if any(not isinstance(n, str) or not n or "\n" in n for n in exclude):
                raise ValueError("exclude: node names, each on one line")
            o.exclude = _text("exclude", "\n".join(exclude)) if exclude else b""
        o.bus = _text("bus", bus)
        with _lib.state_lock:
            for c in self.channels:
                c._current()
            self._h = _lib.check(lib.bb_replay_start(rows, len(rows), ctypes.byref(o)))
        self.notes = _lib.string(lib.bb_replay_notes, self._h).split("\n")

    def _call(self, fn: str, *args: int | float) -> None:
        _lib.check(getattr(_lib.lib(), fn)(self._h, *args))

    def pause(self) -> None:
        """Holds it where it is."""
        self._call("bb_replay_pause", 1)

    def resume(self) -> None:
        """Plays on from where it is; a finished replay again from the start."""
        self._call("bb_replay_pause", 0)

    def seek(self, position_s: float) -> None:
        """Moves to `position_s` seconds into the recording (clamped to it), playing or paused as it
        was; a finished replay is left paused there."""
        if isinstance(position_s, bool) or not isinstance(position_s, (int, float)) or not position_s >= 0:
            raise ValueError(f"position_s {position_s!r}: 0 or more seconds")
        self._call("bb_replay_seek", float(position_s))

    def set_speed(self, speed: float) -> None:
        """Changes the rate, the position kept."""
        self._call("bb_replay_speed", _rate(speed))

    def set_loop(self, on: bool) -> None:
        """Whether the end of the recording starts it again, decided at the end of a pass."""
        self._call("bb_replay_loop", int(bool(on)))

    def status(self) -> ReplayStatus:
        """What it is doing, as of its last tick (at most 20 ms ago); after stop(), what it did."""
        lib, i = _lib.lib(), _lib.BbReplayInfo()
        _lib.check(lib.bb_replay_status(self._h, ctypes.byref(i)))
        return ReplayStatus(_lib.REPLAY_STATES.get(i.state, str(i.state)), i.position_s, i.duration_s, i.speed,
                            bool(i.loop), i.passes, i.sent, i.failed, _lib.string(lib.bb_replay_error, self._h),
                            bool(i.ended))

    def wait_done(self, timeout_ms: float | None = 10000) -> bool:
        """Waits at most timeout_ms (None: for ever) for a non-looping replay to run out, or for it
        to be stopped: True when it did. Ctrl-C ends the wait within 100 ms."""
        from .project import _ms
        ms = _ms(timeout_ms)
        h, lib = self._h, _lib.lib()
        return _sliced(lambda part: True if _lib.check(lib.bb_replay_wait(h, part)) == 0 else None, ms) is True

    def stop(self) -> ReplayStatus:
        """Stops it and lets its buses go, and returns its last status; once stopped, its controls
        are refused and status() still says what it did."""
        _lib.check(_lib.lib().bb_replay_stop(self._h, None))
        return self.status()

    def __enter__(self) -> "Replay":
        return self

    def __exit__(self, *exc: object) -> Literal[False]:
        self.stop()
        return False

    def __repr__(self) -> str:
        return f"<Replay onto {', '.join(c.name for c in self.channels)}>"


class Recording:
    """What `channels` carry, written to the candump .log at `path` (Project.record): a line per
    frame, `(t) <channel> <id>#<data> T` for a frame this process sent and R for the rest, t the
    host's monotonic clock in seconds (blobly.now_ms() / 1000). `with` stops it at the end of the
    block."""

    channels: "list[Channel]"
    path: str

    def __init__(self, project: "Project", path: Path, channels: Targets):
        self._project = project
        self.channels, rows = _rows(project, channels)
        self.path = _absolute(path)
        lib = _lib.lib()
        with _lib.state_lock:
            for c in self.channels:
                c._current()
            self._h = _lib.check(lib.bb_record_start(rows, len(rows), _text("path", self.path, path=True)))
        self._last = None

    @staticmethod
    def _counts(r: _lib.BbRecordReport) -> RecordCounts:
        return RecordCounts(r.frames, r.ours, r.theirs, r.missed, r.dropped)

    def counts(self) -> RecordCounts:
        """What it holds so far."""
        with _lib.state_lock:  # a stop on another thread lets the handle go
            if self._h is None:
                return self._last
            r = _lib.BbRecordReport()
            _lib.check(_lib.lib().bb_record_counts(self._h, ctypes.byref(r)))
            return self._counts(r)

    def stop(self) -> RecordCounts:
        """Ends it, once, closes the file and returns what it holds. Refused when a write or a
        receive failed on the way, the file keeping what was written before."""
        with _lib.state_lock:
            if self._h is None:
                return self._last
            r = _lib.BbRecordReport()
            rc = _lib.lib().bb_record_stop(self._h, ctypes.byref(r))  # the handle stays readable
            self._last = self._counts(r)
            self._project.__dict__.get("_recordings", set()).discard(self)
            if rc >= 0:
                self._h = None
            # else kept: a writer that outlived the stop still adds to its counts, which counts()
            # and another stop() then read
            _lib.check(rc)
        return self._last

    def __enter__(self) -> "Recording":
        return self

    def __exit__(self, *exc: object) -> Literal[False]:
        self.stop()
        return False

    def __repr__(self) -> str:
        return f"<Recording {self.path}>"


class Replays:
    """Replay and recording on the project's run, for Project (it supplies _resolve)."""

    def replay(self, channels: Targets, source: "Path | None" = None, *, speed: float | None = None,
               loop: bool | None = None, paused: bool = False, exclude: Iterable[str] | None = None,
               bus: str | None = None) -> Replay:
        """Plays a recording onto `channels` (a Channel or its name, or a list of them, on one
        clock) of the started project, and returns its Replay. What is left None their rows'
        `replay:` blocks say: `source` (a .log or .mf4), `speed`, `loop`, and `exclude`, the nodes
        subtracted by DBC sender (the ECU under test); `bus` names the recorded bus, for one
        channel. `paused` starts it paused at the beginning. Refused (Refused) where it would play
        something other than asked: no source, a recorded bus that does not resolve, an exclusion
        no channel's database declares, two channels on one wire, nothing left to play, or rows
        disagreeing about what was left None."""
        return Replay(self, channels, source, speed, loop, paused, exclude, bus)

    def record(self, path: Path, channels: Targets) -> Recording:
        """Records what `channels` (a Channel or its name, or a list of them, one per wire) of the
        started project carry to the candump .log at `path`, created or truncated, and returns
        its Recording."""
        with _lib.state_lock:  # started and held in one hold: a stop on another thread sees it
            rec = Recording(self, path, channels)
            # held until stopped, so a stop of the project can say what went wrong with one nobody kept
            self.__dict__.setdefault("_recordings", set()).add(rec)
        return rec

    def _stop_recordings(self) -> list[str]:
        """Stops the recordings this project started and left running (its stop), answering what
        went wrong with them, which the stop then says."""
        errs = []
        live = self.__dict__.get("_recordings", set())
        for rec in list(live):
            try:
                rec.stop()
            except _lib.BloblyError as e:
                errs.append(f"{rec.path}: {e}")
            live.discard(rec)
        return errs
