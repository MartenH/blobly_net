"""flash.program from Python against the simulated bootloader (blobly/flash's BootSim, the one
blobly/script/flash_test.v flashes) on projects/sim-demo.blobnet's CAN1: the coverage of the Lua
flash suite — progress, a wrong key, a failing check, a raising callback, the arguments — through
the C ABI."""
import os
import struct
import sys
import zlib

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
# the source tree, unless the run is of an installed wheel (BLOBLY_TEST_INSTALLED)
if not os.environ.get("BLOBLY_TEST_INSTALLED"):
    sys.path.insert(0, os.path.join(HERE, ".."))
import blobly  # noqa: E402
from blobly import _lib, flash  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
SIM_DEMO = os.path.join(REPO, "projects", "sim-demo.blobnet")


def blbt(body: bytes, crc_ok: bool = True) -> bytes:
    """A wrapped image as mkimage writes one: the header states the body's length and CRC, and its
    first 28 bytes carry their own CRC."""
    h = bytearray(b"\xff" * 64)
    struct.pack_into("<IBBBBIIIII", h, 0, 0x54424C42, 1, 0, 0, 0, len(body),
                     zlib.crc32(body) ^ (0 if crc_ok else 0xFF), 1, 64, 0)
    struct.pack_into("<I", h, 28, zlib.crc32(bytes(h[:28])))
    return bytes(h) + body


@pytest.fixture(scope="module")
def net():
    try:
        _lib.lib()
    except blobly.BloblyError as e:
        if os.environ.get("BLOBLY_LIB") or os.environ.get("BLOBLY_TEST_INSTALLED"):
            raise
        pytest.skip(str(e))
    p = blobly.Project(SIM_DEMO).start()
    yield p
    p.stop()


@pytest.fixture
def can1(net):
    return net.channels.CAN1


@pytest.fixture
def boot(can1):
    b = flash.BootSim(can1)
    yield b
    b.stop()


def test_a_flash_with_progress(can1, boot):
    image = bytes(i * 7 & 0xFF for i in range(8000))
    calls = []
    r = flash.program(can1, image, sw_version=3, progress=lambda done, total: calls.append((done, total)), quiet=True)
    assert (r.auth, r.wrapped, r.reset_acknowledged, r.bytes) == ("authenticated", False, True, 8064)
    assert calls[-1] == (r.blocks, r.blocks), "the last call is the last block"
    assert len(calls) <= 101, "a call per whole percent, not per block"
    assert [d for d, _ in calls] == sorted(d for d, _ in calls)
    b = boot.stop()
    assert (b.authenticated, b.verified, b.erases, b.checks, b.resets) == (True, True, 1, 1, 1)
    assert (b.blocks, b.bytes) == (r.blocks, 8064)
    assert b.blocks > 101, "the image outruns a call per block"


def test_without_a_callback_a_line_per_tenth(can1, boot, capsys):
    r = flash.program(can1, bytes(6000))
    lines = capsys.readouterr().out.splitlines()
    assert 10 <= len([s for s in lines if s.startswith("flash: transfer ")]) <= 11, lines
    assert f"flash: transfer {r.blocks}/{r.blocks} blocks (100%)" in lines
    assert "flash: image verified + marked valid" in lines


def test_quiet_says_nothing(can1, boot, capsys):
    flash.program(can1, bytes(300), quiet=True)
    assert capsys.readouterr().out == ""


def test_a_wrong_key_is_refused_and_nothing_is_erased(can1, boot, tmp_path):
    with pytest.raises(blobly.NegativeResponse, match="send proof: NRC 0x35") as e:
        flash.program(can1, bytes(100), seed="11" * 32, quiet=True)
    assert e.value.nrc == 0x35 and e.value.exchange.nrc == 0x35
    seed = tmp_path / "other.seed"
    seed.write_text("11" * 32 + "\n")
    with pytest.raises(blobly.NegativeResponse):
        flash.program(can1, bytes(100), seed_file=seed, quiet=True)
    assert (boot.stop().erases, boot.report.blocks) == (0, 0)


def test_a_wrapped_image_goes_as_it_is_and_the_exchanges_are_the_clients(can1, boot):
    img = blbt(bytes(range(200)))
    with can1.uds(0x7B0, 0x7B8) as diag:
        r = flash.program(diag, img, quiet=True)
        assert (r.wrapped, r.bytes) == (True, len(img))
        assert diag.last.request == b"\x11\x01", "the session's last request is the client's last"
    b = boot.stop()
    assert b.verified and b.bytes == len(img)


def test_a_failing_check_is_a_flash_failure_and_no_reset(can1, boot, tmp_path):
    img = blbt(bytes(range(250)) * 2, crc_ok=False)
    path = tmp_path / "bad.img"
    path.write_bytes(img)
    with pytest.raises(blobly.FlashFailed, match="image check FAILED"):
        flash.program(can1, path, quiet=True)
    b = boot.stop()
    assert (b.erases, b.checks, b.verified, b.resets, b.bytes) == (1, 1, False, 0, len(img))


def test_a_raising_progress_stops_before_the_check_and_the_client_flashes_again(can1, boot):
    def wrong_ecu(done, total):
        if done >= 5:
            raise RuntimeError("wrong ECU")
    with can1.uds(0x7B0, 0x7B8) as diag:
        with pytest.raises(RuntimeError):
            flash.program(diag, bytes(3000), progress=wrong_ecu, quiet=True)
        assert flash.program(diag, bytes(3000), quiet=True).reset_acknowledged
    b = boot.stop()
    assert (b.erases, b.checks) == (2, 1), "the stopped transfer was never checked"


def test_a_progress_may_not_call_into_blobly(net, can1, boot):
    with can1.uds(0x7B0, 0x7B8) as diag:
        for call in (diag.tester_present, lambda: diag.last, diag.close, net.stop, can1.close,
                     lambda: can1.recv(None)):
            with pytest.raises(blobly.BloblyError) as e:
                flash.program(diag, bytes(300), progress=lambda done, total: call(), quiet=True)
            assert e.value.code == _lib.BB_ERR_STATE
        assert flash.program(diag, bytes(100), quiet=True).auth == "authenticated"
    assert net.started
    assert boot.stop().checks == 1, "only the flash nothing interrupted was checked"


@pytest.mark.parametrize("kw, err, why", [
    ({"seed": "a", "seed_file": "b"}, blobly.Refused, "seed and seed_file"),
    ({"auth": False, "seed": "11" * 32}, blobly.Refused, "auth = false"),
    ({"seed": "0x1234"}, blobly.Refused, "seed must be 64 hex"),
    ({"base": -1}, ValueError, "32-bit"),
    ({"seed_file": "a\0b"}, ValueError, "NUL"),
    ({"progress": 5}, TypeError, "progress"),
])
def test_bad_options_are_named(can1, boot, kw, err, why):
    with pytest.raises(err, match=why):
        flash.program(can1, bytes(10), quiet=True, **kw)
    assert boot.stop().erases == 0


@pytest.mark.parametrize("image, err", [(b"", blobly.Refused), ("no-such.bin", FileNotFoundError), (5, TypeError)])
def test_a_bad_image_is_refused(can1, boot, image, err):
    with pytest.raises(err):
        flash.program(can1, image, quiet=True)


def test_a_bad_target_is_refused(can1, boot):
    with can1.uds(0x7B0, 0x7B8) as diag, pytest.raises(blobly.Refused, match="drop tx/rx"):
        flash.program(diag, bytes(10), tx=0x7B0)
    with pytest.raises(TypeError):
        flash.program("CAN1", bytes(10))
