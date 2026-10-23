"""flash — a blobly_emb bootloader's download session through libblobly, as the Lua flash.program:
0x10 02, 0x29 authentication, erase, 0x34/0x36/0x37, the check routine, 0x11 — the session
cmd/flash and the GUI's Flash panel run (blobly/flash), on a channel or a UdsClient.

    from blobly import flash
    report = flash.program(net.channels.CAN1, "app.bin", progress=lambda done, total: print(done, total))

BootSim is a simulated bootloader on a CAN channel, to rehearse a flash with no board."""
import ctypes
import os
import queue
import threading
from collections.abc import Callable
from dataclasses import dataclass

from . import _lib
from ._lib import Refused
from .events import _sliced
from .uds import UdsClient, _data, _int

__all__ = ["program"]


@dataclass(frozen=True)
class FlashReport:
    """What a completed flash did: `bytes` transferred (header and image), `blocks` (0x36
    requests), `wrapped` (the image was a BLBT .img, sent as it is), `auth` — "authenticated",
    "not required" (a keyless boot refused the challenge) or "skipped" (auth=False) — and
    `reset_acknowledged` (the 0x11 reset was answered; False when its answer was lost to the reset,
    which is normal)."""
    bytes: int
    blocks: int
    wrapped: bool
    auth: str
    reset_acknowledged: bool


@dataclass(frozen=True)
class BootReport:
    """What a simulated bootloader was asked to do (BootSim.stop): `authenticated` (the last 0x29
    proof verified against the dev tester key), `erases`, `blocks` taken, `bytes` the last download
    was sent (header included), `checks` of the image, `verified` (the last check passed: the CRC
    the image header states) and `resets`."""
    authenticated: bool
    verified: bool
    erases: int
    blocks: int
    bytes: int
    checks: int
    resets: int


class _FlashClient(UdsClient):
    """A UdsClient opened on the bootloader's default ids, 0x7B0 / 0x7B8."""
    _opener = "bb_flash_open"


def _image(image) -> bytes:
    if isinstance(image, (str, os.PathLike)):
        with open(image, "rb") as f:
            return f.read()
    return _data("image", image)


def _text(name: str, v) -> bytes | None:
    if v is None:
        return None
    if isinstance(v, os.PathLike):
        v = os.fspath(v)
    if not isinstance(v, str) or "\0" in v:
        raise TypeError(f"{name} must be a string, not {v!r}")
    return v.encode()


def program(target, image, *, base: int | None = None, sw_version: int | None = None, auth: bool = True,
            seed: str | None = None, seed_file: str | os.PathLike | None = None,
            progress: Callable[[int, int], None] | None = None, quiet: bool = False,
            tx: int | None = None, rx: int | None = None) -> FlashReport:
    """Flashes `image` (bytes, or the path of a raw .bin, which gets its header here, or a BLBT
    .img, sent as it is) into a blobly_emb bootloader and returns a FlashReport.

    `target` is a Channel of the started project — opened on `tx` / `rx` (None: 0x7B0 / 0x7B8) and
    closed after — or a UdsClient (its ids; the connection a handoff to the bootloader was made
    on). `base` is where the image goes (None: 0x08020000), `sw_version` a raw image's header
    version (None: 1). With `auth` the session signs the bootloader's 0x29 challenge with `seed`
    (64 hex characters), else the file `seed_file` names, else $BLOBLY_FLASH_SEED, else the dev
    tester seed. `progress(done, total)`, in blocks, is called at each whole percent, while the
    flash holds the engine: it may print or record, and a call into blobly from it is refused.
    Without it a `flash: transfer ...` line is printed per tenth. Each milestone prints a `flash: ...` line;
    `quiet` prints none.

    A step the bootloader refused raises NegativeResponse (its NRC), one it did not answer
    Timeout; FlashFailed when its own answers say the flash did not happen (the check routine
    failing: the image is not marked valid). A `progress` that raises stops the transfer before
    the check and its exception is raised; so does Ctrl-C, within 100 ms."""
    if isinstance(target, UdsClient):
        if tx is not None or rx is not None:
            raise Refused("flash.program: a UdsClient brings its own ids; drop tx/rx")
        return _program(target, image, base, sw_version, auth, seed, seed_file, progress, quiet)
    from .project import Channel  # project imports uds, which this imports
    if not isinstance(target, Channel):
        raise TypeError(f"flash.program: target is a Channel or a UdsClient, not {target!r}")
    with _FlashClient(target, tx, rx) as client:
        return _program(client, image, base, sw_version, auth, seed, seed_file, progress, quiet)


def _program(client, image, base, sw_version, auth, seed, seed_file, progress, quiet) -> FlashReport:
    if progress is not None and not callable(progress):
        raise TypeError(f"flash.program: progress is a function(done, total), not {progress!r}")
    if not isinstance(auth, bool) or not isinstance(quiet, bool):
        raise TypeError("flash.program: auth and quiet are True or False")
    img = _image(image)
    if len(img) > 0x7FFF_FFFF:
        raise ValueError(f"flash.program: an image of {len(img)} bytes, past what the C ABI carries")
    lib = _lib.lib()
    opts = _lib.BbFlashOpts()
    _lib.check(lib.bb_flash_defaults(ctypes.byref(opts)))
    if base is not None:
        opts.base = _u32("base", base)
    if sw_version is not None:
        opts.sw_version = _u32("sw_version", sw_version)
    opts.auth, opts.quiet = int(auth), int(quiet)
    opts.seed, opts.seed_file = _text("seed", seed), _text("seed_file", seed_file)
    # the engine calls these on the flashing thread, and this thread reports: a note is queued, a
    # progress call waits until it was made here, so a progress that raises (cancelling) stops the
    # transfer before the next block
    events: queue.SimpleQueue = queue.SimpleQueue()
    released = threading.Event()  # this thread no longer reports: a waiting progress call returns

    def on_progress(_ctx, done, total):
        handled = threading.Event()
        events.put(("progress", done, total, handled))
        while not handled.wait(0.1) and not released.is_set():
            pass
    opts.note = _lib.FLASH_NOTE(lambda _ctx, line: events.put(("note", _lib.text(line))))
    opts.progress = _lib.FLASH_PROGRESS(on_progress) if progress is not None else _lib.FLASH_PROGRESS()
    rep = _lib.BbFlashReport()
    box: dict = {}

    def report(part):
        """What the flashing thread said, waiting at most part ms for the first; True once it ended."""
        timeout = part / 1000
        while True:
            try:
                e = events.get(timeout=timeout)
            except queue.Empty:
                return None
            timeout = 0
            if e[0] == "end":
                return True
            if e[0] == "note":
                print(f"flash: {e[1]}", flush=True)
                continue
            _lib.in_progress(True)
            try:
                progress(e[1], e[2])
            except BaseException:
                _lib.in_progress(False)
                lib.bb_flash_cancel(h)  # before the flashing thread goes on
                raise
            finally:
                _lib.in_progress(False)
                e[3].set()

    with client._lock:  # calls on one client are serialised: the session holds it throughout
        h = client._handle()

        def run():
            try:
                _lib.lib()  # attaches this thread
                rc = lib.bb_flash_program(h, img, len(img), ctypes.byref(opts), ctypes.byref(rep))
                if rc < 0:  # read on this thread, whose error and NRC they are
                    box["error"] = client._enrich(h, _lib.error(rc))
            except BaseException as e:
                box["error"] = e
            events.put(("end",))
        t = threading.Thread(target=run, name="blobly-flash", daemon=True)
        try:
            client._flashing = True  # a call on it from `progress` would wait for the session: refused
            t.start()
            _sliced(report, -1)
        except BaseException:  # Ctrl-C, or progress raising: stop before the check, then say it
            released.set()
            while t.is_alive():  # asked again until it lands: the session may not have begun yet
                lib.bb_flash_cancel(h)
                t.join(0.02)
            raise
        finally:
            client._flashing = False
        t.join()
    if "error" in box:
        raise box["error"]
    return FlashReport(rep.bytes, rep.blocks, bool(rep.wrapped), _lib.FLASH_AUTH.get(rep.auth, str(rep.auth)),
                       bool(rep.reset_acknowledged))


def _u32(name: str, v) -> int:
    v = _int(name, v, 64)
    if not 0 <= v <= 0xFFFF_FFFF:
        raise ValueError(f"{name} {v} is not a 32-bit value")
    return v


class BootSim:
    """A simulated blobly_emb bootloader on a CAN channel of the started project, to rehearse a
    flash with no board: it hears requests on `tx` and answers on `rx` (the tester's ids; None:
    0x7B0 / 0x7B8), by the rules of blobly_emb's boot/prog.v: 0x29, erase and download only in the
    programming session, relocked by a session change or a reset; the 0x29 proof verified against
    the dev tester key; a download only after an erase, its blocks in sequence; the check routine
    passing only for a valid BLBT header and the body CRC it states. Nothing is written anywhere.

    `with BootSim(can1) as boot:` stops it at the end of the block, and `report` (a BootReport)
    says what it was asked; stop() does the same and returns it. Stop it before the project."""

    def __init__(self, channel, tx: int | None = None, rx: int | None = None):
        from .project import Channel
        if not isinstance(channel, Channel):
            raise TypeError(f"BootSim: channel is a Channel, not {channel!r}")
        self.channel = channel
        self.report: BootReport | None = None
        ids = [None if v is None else ctypes.byref(ctypes.c_int64(_int(n, v, 64))) for n, v in (("tx", tx), ("rx", rx))]
        with _lib.state_lock:
            channel._current()
            self._h = _lib.check(_lib.lib().bb_boot_sim(channel._index, ids[0], ids[1]))

    def stop(self) -> BootReport:
        """Stops it, once, and returns what it was asked."""
        with _lib.state_lock:  # a stop of the project cannot overtake it
            if self._h is None:
                return self.report
            h, self._h = self._h, None
            r = _lib.BbBootReport()
            _lib.check(_lib.lib().bb_boot_sim_stop(h, ctypes.byref(r)))
            self.report = BootReport(bool(r.authenticated), bool(r.verified), r.erases, r.blocks, r.bytes,
                                     r.checks, r.resets)
        return self.report

    def __enter__(self) -> "BootSim":
        return self

    def __exit__(self, *exc) -> bool:
        self.stop()
        return False

    def __repr__(self) -> str:
        return f"<BootSim on {self.channel.name}>"
