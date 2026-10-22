"""e2e — AUTOSAR E2E Profile 1 for frames a script builds itself, as Lua's e2e.p01_crc and
e2e.p01_protect: computed by the engine's one implementation (sim.p01_frame_crc, sim.p01_protect),
the one the simulation stamps with, pinned to vectors from an independent implementation.

    from blobly import e2e
    frame = e2e.p01_protect(bytes.fromhex("E8035A000000"), 0x1244, 4, 5, counter=3)

Positions are 0-based bytes, as blobly_emb's [[frame]].e2e writes them. `mode` is the Data ID
mode: "both" (low byte, then high), "low", or "alt" (low for an even counter, high for an odd)."""
import ctypes
import numbers

from . import _lib

__all__ = ["p01_crc", "p01_protect"]


def p01_crc(data: bytes, data_id: int, crc_pos: int, counter_pos: int, mode: str = "both") -> int:
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


def p01_protect(data: bytes, data_id: int, crc_pos: int, counter_pos: int, counter: int,
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
    """A frame: bytes, bytearray, memoryview, or a sequence of byte values."""
    if isinstance(data, (str, numbers.Integral)):
        raise TypeError(f"data must be bytes, not {type(data).__name__}")
    try:
        return bytes(data)
    except (TypeError, ValueError) as e:
        raise TypeError(f"data must be bytes: {e}") from None


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

