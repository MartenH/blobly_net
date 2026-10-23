"""flash.program from Python against the simulated bootloader (blobly/flash's BootSim, the one
blobly/script/flash_test.v flashes) on projects/sim-demo.blobnet's CAN1: the coverage of the Lua
flash suite — progress, a wrong key, a failing check, a raising callback, the arguments — through
the C ABI."""
import contextlib
import io
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
# the source tree, unless the run is of an installed wheel (BLOBLY_TEST_INSTALLED)
if not os.environ.get("BLOBLY_TEST_INSTALLED"):
    sys.path.insert(0, os.path.join(HERE, ".."))
import blobly  # noqa: E402
from blobly import _lib, flash  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
SIM_DEMO = os.path.join(REPO, "projects", "sim-demo.blobnet")


def setUpModule():
    try:
        _lib.lib()
    except blobly.BloblyError as e:
        if os.environ.get("BLOBLY_LIB") or os.environ.get("BLOBLY_TEST_INSTALLED"):
            raise
        raise unittest.SkipTest(str(e))


def blbt(body: bytes, crc_ok: bool = True) -> bytes:
    """A wrapped image as mkimage writes one: the header states the body's length and CRC."""
    import struct
    import zlib
    h = bytearray(b"\xff" * 64)
    struct.pack_into("<IBBBBIII", h, 0, 0x54424C42, 1, 0, 0, 0, len(body), zlib.crc32(body) ^ (0 if crc_ok else 0xFF), 1)
    return bytes(h) + body


class TestFlash(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.net = blobly.Project(SIM_DEMO).start()
        cls.can1 = cls.net.channels.CAN1

    @classmethod
    def tearDownClass(cls):
        cls.net.stop()

    def setUp(self):
        self.boot = flash.BootSim(self.can1)
        self.addCleanup(self.boot.stop)

    def test_a_flash_with_progress(self):
        image = bytes(i * 7 & 0xFF for i in range(8000))
        calls = []
        r = flash.program(self.can1, image, sw_version=3, progress=lambda done, total: calls.append((done, total)),
                          quiet=True)
        self.assertEqual((r.auth, r.wrapped, r.reset_acknowledged, r.bytes), ("authenticated", False, True, 8064))
        self.assertEqual(calls[-1], (r.blocks, r.blocks), "the last call is the last block")
        self.assertLessEqual(len(calls), 101, "a call per whole percent, not per block")
        self.assertEqual([d for d, _ in calls], sorted(d for d, _ in calls))
        b = self.boot.stop()
        self.assertEqual((b.authenticated, b.verified, b.erases, b.checks, b.resets), (True, True, 1, 1, 1))
        self.assertEqual((b.blocks, b.bytes), (r.blocks, 8064))
        self.assertGreater(b.blocks, 101, "the image outruns a call per block")

    def test_without_a_callback_a_line_per_tenth(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            r = flash.program(self.can1, bytes(6000))
        lines = out.getvalue().splitlines()
        transfer = [s for s in lines if s.startswith("flash: transfer ")]
        self.assertTrue(10 <= len(transfer) <= 11, lines)
        self.assertIn(f"flash: transfer {r.blocks}/{r.blocks} blocks (100%)", lines)
        self.assertIn("flash: image verified + marked valid", lines)

    def test_quiet_says_nothing(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            flash.program(self.can1, bytes(300), quiet=True)
        self.assertEqual(out.getvalue(), "")

    def test_a_wrong_key_is_refused_and_nothing_is_erased(self):
        with self.assertRaises(blobly.NegativeResponse) as e:
            flash.program(self.can1, bytes(100), seed="11" * 32, quiet=True)
        self.assertEqual(e.exception.nrc, 0x35)
        self.assertIn("send proof: NRC 0x35", str(e.exception))
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "other.seed")
            with open(path, "w") as f:
                f.write("11" * 32 + "\n")
            with self.assertRaises(blobly.NegativeResponse):
                flash.program(self.can1, bytes(100), seed_file=path, quiet=True)
        self.assertEqual((self.boot.stop().erases, self.boot.report.blocks), (0, 0))

    def test_a_failing_check_is_a_flash_failure_and_no_reset(self):
        img = blbt(bytes(range(250)) * 2, crc_ok=False)
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "bad.img")
            with open(path, "wb") as f:
                f.write(img)
            with self.assertRaises(blobly.FlashFailed) as e:
                flash.program(self.can1, path, quiet=True)
        self.assertIn("image check FAILED", str(e.exception))
        b = self.boot.stop()
        self.assertEqual((b.erases, b.checks, b.verified, b.resets, b.bytes), (1, 1, False, 0, len(img)))

    def test_a_raising_progress_stops_before_the_check_and_the_client_flashes_again(self):
        def wrong_ecu(done, total):
            if done >= 5:
                raise RuntimeError("wrong ECU")
        with self.can1.uds(0x7B0, 0x7B8) as diag:
            with self.assertRaises(RuntimeError):
                flash.program(diag, bytes(3000), progress=wrong_ecu, quiet=True)
            r = flash.program(diag, bytes(3000), quiet=True)
            self.assertTrue(r.reset_acknowledged)
        b = self.boot.stop()
        self.assertEqual((b.erases, b.checks), (2, 1), "the stopped transfer was never checked")

    def test_bad_arguments_are_named(self):
        with self.can1.uds(0x7B0, 0x7B8) as diag:
            with self.assertRaises(blobly.Refused):
                flash.program(diag, bytes(10), tx=0x7B0)
        for kw, err, why in (({"seed": "a", "seed_file": "b"}, blobly.Refused, "seed and seed_file"),
                             ({"auth": False, "seed": "11" * 32}, blobly.Refused, "auth = false"),
                             ({"seed": "0x1234"}, blobly.Refused, "seed must be 64 hex"),
                             ({"base": -1}, ValueError, "32-bit"), ({"progress": 5}, TypeError, "progress")):
            with self.subTest(kw), self.assertRaises(err) as e:
                flash.program(self.can1, bytes(10), quiet=True, **kw)
            self.assertIn(why, str(e.exception))
        for image, err in ((b"", blobly.Refused), ("no-such.bin", FileNotFoundError), (5, TypeError)):
            with self.subTest(image), self.assertRaises(err):
                flash.program(self.can1, image, quiet=True)
        with self.assertRaises(TypeError):
            flash.program("CAN1", bytes(10))
        self.assertEqual(self.boot.stop().erases, 0)


if __name__ == "__main__":
    unittest.main()
