"""e2e — AUTOSAR E2E Profile 1 for frames a script builds itself, as Lua's e2e.p01_crc and
e2e.p01_protect: computed by the engine's one implementation (sim.p01_frame_crc, sim.p01_protect),
the one the simulation stamps with, pinned to vectors from an independent implementation.

    from blobly import e2e
    frame = e2e.p01_protect(bytes.fromhex("E8035A000000"), 0x1244, 4, 5, counter=3)

Positions are 0-based bytes, as blobly_emb's [[frame]].e2e writes them. `mode` is the Data ID
mode: "both" (low byte, then high), "low", or "alt" (low for an even counter, high for an odd).

Also here, exported from blobly: E2eStatus, a received frame's verdict (Frame.e2e), and E2eError,
what an expectation raises for a frame that fails it."""
import ctypes
import enum
import numbers
from typing import TYPE_CHECKING

from . import _lib
from ._lib import BloblyError, ByteData

if TYPE_CHECKING:
    from .project import Frame

__all__ = ["p01_crc", "p01_protect"]


class E2eStatus(enum.StrEnum):
    """A received frame's E2E verdict (Frame.e2e), by its message's E2E on its channel: the
    channel's verify: entry for it, else what its database declares. Its plain string ("ok", ...)
    works as well."""
    OK = "ok"                # the CRC matches, and the counter is the next one
    BAD_CRC = "bad_crc"      # the CRC does not match the frame's bytes
    REPEATED = "repeated"    # the counter repeated the previous frame's: no new data
    SKIPPED = "skipped"      # the counter jumped (frames lost, the sender restarted), or is one never sent (15)
    TRUNCATED = "truncated"  # shorter than its message: its E2E fields are not all there
    TIMEOUT = "timeout"      # later than its message's E2ETimeout after the last valid frame


# enum bb_e2e by code; BB_E2E_NONE (0) is no verdict
_BY_CODE = {1: E2eStatus.OK, 2: E2eStatus.BAD_CRC, 3: E2eStatus.REPEATED, 4: E2eStatus.SKIPPED,
            5: E2eStatus.TRUNCATED, 6: E2eStatus.TIMEOUT}

# what each failing verdict means, for an E2eError's message
_MEANING = {E2eStatus.BAD_CRC: "its CRC does not match its bytes",
            E2eStatus.REPEATED: "its counter repeated the previous frame's",
            E2eStatus.SKIPPED: "its counter jumped: frames were lost, or the sender restarted",
            E2eStatus.TRUNCATED: "it is shorter than its message, so its E2E fields are not all there",
            E2eStatus.TIMEOUT: "it came later than its message's E2ETimeout after the last valid frame"}


def status_of(code: int) -> E2eStatus | None:
    """A bb_frame's e2e as the E2eStatus it names; None for no verdict."""
    return _BY_CODE.get(code)


class E2eError(BloblyError):
    """A received frame failed its E2E check where an expectation required it to pass
    (expect(..., e2e=True), expect_signal(..., e2e=True)): `status` is its verdict, None where its
    message has no E2E to check, and `frame` the frame. Code -12."""
    status: E2eStatus | None
    frame: "Frame | None"

    def __init__(self, message: str, code: int = _lib.BB_ERR_E2E, status: E2eStatus | None = None,
                 frame: "Frame | None" = None) -> None:
        super().__init__(message, code)
        self.status, self.frame = status, frame


def _passed(who: str, f: "Frame") -> None:
    """Raises E2eError unless `f` passed its E2E check."""
    __tracebackhide__ = True
    if f.e2e is E2eStatus.OK:
        return
    if f.e2e is None:
        raise E2eError(f"{who}: {f!r} has no E2E to check: no verify: entry or database declaration "
                       "describes its message", frame=f)
    raise E2eError(f"{who}: {f!r} failed its E2E check: {f.e2e.value} ({_MEANING[f.e2e]})",
                   status=f.e2e, frame=f)


def p01_crc(data: ByteData, data_id: int, crc_pos: int, counter_pos: int, mode: str = "both") -> int:
    """The Profile 1 CRC byte for `data` as it stands: CRC-8 (poly 0x1D, start 0, no final XOR)
    over the Data ID bytes `mode` names, then every byte but the CRC's own; the counter is read
    from the low nibble of `counter_pos` (alt mode's byte choice depends on it). It answers the
    CRC only: a counter of 15, which Profile 1 never sends, is the caller's to catch. Raises
    ValueError for what Profile 1 cannot be: a data_id past 16 bits, an unknown mode, positions
    that are not two distinct bytes of the frame."""
    d = _bytes(data)
    lib = _lib.lib()
    rc = lib.bb_e2e_p01_crc(d, len(d), _int("data_id", data_id), _int("crc_pos", crc_pos),
                            _int("counter_pos", counter_pos), _mode(mode))
    return _answer(lib, rc)


def p01_protect(data: ByteData, data_id: int, crc_pos: int, counter_pos: int, counter: int,
                mode: str = "both") -> bytes:
    """`data` with `counter` (0..14) in the low nibble of `counter_pos` (its high nibble kept) and
    then the CRC of p01_crc stamped at `crc_pos`. Raises ValueError as p01_crc does, and for a
    counter outside 0..14."""
    d = _bytes(data)
    buf = ctypes.create_string_buffer(d, len(d))
    lib = _lib.lib()
    rc = lib.bb_e2e_p01_protect(buf, len(d), _int("data_id", data_id), _int("crc_pos", crc_pos),
                                _int("counter_pos", counter_pos), _int("counter", counter), _mode(mode))
    _answer(lib, rc)
    return buf.raw


def _answer(lib, rc):
    """The call's answer; the engine's refusal of a value as a ValueError."""
    if rc == _lib.BB_ERR:
        raise ValueError(_lib.text(lib.bb_last_error()))
    return _lib.check(rc)


def _bytes(data):
    return _lib.byte_data("data", data)


def _int(name, v):
    """An integer argument as a C int: what it may hold is the engine's to say, but past 32 bits
    it would arrive as another number."""
    if isinstance(v, bool) or not isinstance(v, numbers.Integral):
        raise TypeError(f"{name} must be an integer, not {v!r}")
    if not -2**31 <= v < 2**31:
        raise ValueError(f"{name} {v} is past what a 32-bit C integer holds")
    return int(v)


def _mode(mode):
    if not isinstance(mode, str):
        raise TypeError(f"mode must be a string, not {mode!r}")
    if "\0" in mode:
        raise ValueError("mode cannot carry a NUL: C would read it cut short")
    return mode.encode()

