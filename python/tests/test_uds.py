"""UDS from Python against projects/sim-demo.blobnet's simulated ECUs, the coverage of the Lua
suites tests/diag_basic.lua and tests/diag_advanced.lua (sessions, DIDs, 0x27, 0x11, 0x14, 0x28,
0x85, suppressed requests, the refusals), plus what only a host sees: typed errors, the timing of
the last exchange, a connection let go and reopened across a stop, a close from another thread,
and the failures sim-demo cannot produce (responsePending then silence, an undecodable answer),
answered by a fake ECU on an in-process bus."""
import os
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
# the source tree, unless the run is of an installed wheel (BLOBLY_TEST_INSTALLED)
if not os.environ.get("BLOBLY_TEST_INSTALLED"):
    sys.path.insert(0, os.path.join(HERE, ".."))
import blobly  # noqa: E402
from blobly import _lib  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
SIM_DEMO = os.path.join(REPO, "projects", "sim-demo.blobnet")
DEMO = os.path.join(REPO, "projects", "demo.blobnet")

# one in-process row and no simulation: the tests' own fake ECU answers on it
BARE = """project:
  name: bare
  version: 8
channels:
  - name: B
    type: can
    interface: inproc:PY_UDS_FAKE
"""


def setUpModule():
    try:
        _lib.lib()
    except blobly.BloblyError as e:
        if os.environ.get("BLOBLY_LIB") or os.environ.get("BLOBLY_TEST_INSTALLED"):
            raise
        raise unittest.SkipTest(str(e))


class TestSimDemo(unittest.TestCase):
    """diag_basic.lua and diag_advanced.lua, from Python."""

    @classmethod
    def setUpClass(cls):
        cls.net = blobly.Project(SIM_DEMO).start()
        cls.can1 = cls.net.channels.CAN1

    @classmethod
    def tearDownClass(cls):
        cls.net.stop()

    def setUp(self):
        self.diag = self.can1.uds(tx=0x7E0, rx=0x7E8)
        self.addCleanup(self.diag.close)

    def test_sessions_and_dids(self):
        params = self.diag.session(0x01)
        self.assertEqual(params[:1], b"\x01", "the answer starts with the session")
        self.assertEqual(self.diag.read_did(0xF190), b"BLOBLYNETV0SUT001")  # multi-frame
        self.assertEqual(self.diag.read_did(0xF18C), b"SN-0001")
        self.assertEqual(self.diag.read_did(0xF195), b"\x01\x00")
        self.diag.tester_present()
        time.sleep(0.02)
        self.diag.tester_present()

    def test_the_default_ids_and_the_ecus_apart(self):
        d = self.can1.uds()
        self.addCleanup(d.close)
        self.assertEqual((d.tx, d.rx, d.ext), (0x7E0, 0x7E8, False))
        with self.can1.uds(tx=0x7E1, rx=0x7E9) as chassis:
            self.assertEqual(chassis.read_did(0xF190), b"BLOBLY-CHASSIS-01")
        with self.can1.uds(tx=0x18DA10F1, rx=0x18DAF110) as wide:
            self.assertTrue(wide.ext, "an id past 0x7FF makes the pair 29-bit")

    def test_a_negative_response_is_typed_and_carries_its_nrc(self):
        with self.assertRaises(blobly.NegativeResponse) as e:
            self.diag.read_did(0xABCD)
        self.assertEqual(e.exception.nrc, 0x31)
        self.assertEqual(e.exception.nrc_name, "requestOutOfRange")
        self.assertEqual(e.exception.code, _lib.BB_ERR_NEGATIVE)
        self.assertIsInstance(e.exception, blobly.BloblyError)
        self.assertEqual(e.exception.exchange.answer, b"\x7f\x22\x31")
        self.assertEqual(self.diag.last.nrc, 0x31)

    def test_id_zero_is_an_id_and_nothing_answers_it(self):
        with self.can1.uds(tx=0, rx=0) as zero:
            self.assertEqual((zero.tx, zero.rx), (0, 0), "0 was replaced by the default")
            t = time.monotonic()
            with self.assertRaises(blobly.Timeout) as e:
                zero.read_did(0xF190)
            self.assertLess(time.monotonic() - t, 5, "the wait is bounded")
            self.assertIn("no answer to 0x22", str(e.exception))
            self.assertTrue(zero.last.sent)
            self.assertEqual(zero.last.answer, b"")

    def test_an_id_that_is_not_a_can_identifier_is_refused(self):
        for bad in ({"tx": -2}, {"rx": 0x2000_0000}):
            with self.subTest(bad), self.assertRaises(blobly.Refused) as e:
                self.can1.uds(**bad)
            self.assertIn("is not a CAN identifier", str(e.exception))
        with self.assertRaises(TypeError):
            self.can1.uds(tx=1.5)
        with self.assertRaises(TypeError):
            self.can1.uds(tx=True)

    def test_a_doip_row_is_refused_by_name(self):
        with self.assertRaises(blobly.Refused) as e:
            self.net.channels.DoIP1.uds()
        self.assertIn("DoIP1", str(e.exception))
        self.assertIn("not in this library yet", str(e.exception))

    def test_write_then_read_back(self):
        self.diag.write_did(0xF1AA, b"\xca\xfe")
        self.assertEqual(self.diag.read_did(0xF1AA), b"\xca\xfe")

    def test_security_access(self):
        self.diag.session(0x01)  # locked
        seed = self.diag.security_access(0x01)  # the reference key
        self.assertEqual(seed, b"\x11\x22\x33\x44")

        def no_key(s):
            raise AssertionError("a key was computed for an all-zero seed")
        self.assertEqual(self.diag.security_access(0x01, no_key), b"\x00\x00\x00\x00")
        self.diag.session(0x01)  # relock: a session change locks the server again
        with self.assertRaises(blobly.NegativeResponse) as e:
            self.diag.security_access(0x01, lambda s: s)  # the seed is not the key
        self.assertEqual(e.exception.nrc, 0x35)
        self.assertEqual(e.exception.exchange.request[:2], b"\x27\x02", "the key went out at level + 1")
        self.assertEqual(blobly.reference_key(b"\x11\x22"), b"\xee\xdd")

    def test_reset_dtc_setting_and_comm_control(self):
        self.assertEqual(self.diag.reset(0x01), b"\x01")
        with self.assertRaises(blobly.NegativeResponse) as e:
            self.diag.reset(0x09)
        self.assertEqual(e.exception.nrc, 0x12)
        self.diag.dtc_setting(False)
        self.diag.dtc_setting(True)
        for v in (None, 1, "on"):
            with self.subTest(v), self.assertRaises(TypeError):
                self.diag.dtc_setting(v)
        with self.assertRaises(blobly.NegativeResponse) as e:
            self.diag.comm_control(0x03)  # the simulated ECU cannot gate its traffic, so it refuses
        self.assertEqual(e.exception.nrc, 0x11)

    def test_a_suppressed_positive_response_is_silence(self):
        self.assertFalse(self.diag.raw_suppressed(b"\x3e\x00"))
        self.assertEqual(self.diag.last.request, b"\x3e\x80", "the bit went out set")
        self.assertFalse(self.diag.raw_suppressed(b"\x10\x01"))
        with self.assertRaises(blobly.NegativeResponse) as e:
            self.diag.raw_suppressed(b"\x11\x05")
        self.assertEqual(e.exception.nrc, 0x12)
        with self.assertRaises(blobly.Refused):
            self.diag.raw_suppressed(b"\x22\xf1\x90")  # no sub-function to suppress with

    def test_clear_refuses_what_it_cannot_clear(self):
        with self.assertRaises(blobly.NegativeResponse) as e:
            self.diag.clear_dtcs(0x000001)  # no such DTC
        self.assertEqual(e.exception.nrc, 0x31)
        with self.assertRaises(blobly.NegativeResponse) as e:
            self.diag.raw(b"\x14\xff\xff")  # a group is three bytes
        self.assertEqual(e.exception.nrc, 0x13)
        before = self.diag.last
        for g in (-1, 0x1FFFFFF):
            with self.subTest(g), self.assertRaises(blobly.Refused) as e:
                self.diag.clear_dtcs(g)
            self.assertIn("24-bit", str(e.exception))
        self.assertEqual(self.diag.last, before, "a refused group was sent")
        for g in (1.5, False):
            with self.subTest(g), self.assertRaises(TypeError):
                self.diag.clear_dtcs(g)
        with self.assertRaises(ValueError):
            self.diag.reset(2**32 + 1)  # would arrive as 1

    def test_raw_and_the_timing_of_the_last_exchange(self):
        self.assertIsNone(self.can1.uds().last, "a fresh client has no exchange yet")
        self.assertEqual(self.diag.raw(b"\x22\xf1\x8c"), b"\x62\xf1\x8cSN-0001")
        x = self.diag.last
        self.assertEqual((x.request, x.answer, x.nrc), (b"\x22\xf1\x8c", b"\x62\xf1\x8cSN-0001", None))
        self.assertTrue(x.sent)
        self.assertGreater(x.rtt_us, 0)
        self.assertEqual((x.pending, x.pending_us), (0, 0))
        with self.assertRaises(blobly.Refused):
            self.diag.raw(b"")
        self.assertFalse(self.diag.last.sent, "an empty request reached the carrier")
        with self.assertRaises(blobly.Refused):
            self.diag.raw(bytes(4096))  # past ISO-TP's 4095
        with self.assertRaises(TypeError):
            self.diag.raw("22 F1 90")

    def test_a_closed_client_refuses(self):
        d = self.can1.uds()
        with d:
            d.tester_present()
        with self.assertRaises(blobly.BloblyError) as e:
            d.tester_present()
        self.assertEqual(e.exception.code, _lib.BB_ERR_HANDLE)
        d.close()  # twice is nothing

    def test_security_access_is_one_operation_for_threads_sharing_a_client(self):
        self.diag.session(0x01)  # locked
        in_key, other = threading.Event(), []

        def slow_key(seed):
            in_key.set()
            time.sleep(0.1)  # another thread's call must wait, not change the session under the seed
            return blobly.reference_key(seed)
        t = threading.Thread(target=lambda: other.append(self.diag.session(0x01)))
        worker = threading.Thread(target=lambda: other.append(self.diag.security_access(0x01, slow_key)))
        worker.start()
        in_key.wait(5)
        t.start()
        worker.join(5)
        t.join(5)
        self.assertEqual(other[0], b"\x11\x22\x33\x44", "the key was refused: a call came between seed and key")

    def test_a_client_on_a_worker_thread(self):
        got = []
        t = threading.Thread(target=lambda: got.append(self.diag.read_did(0xF190)))
        t.start()
        t.join(10)
        self.assertEqual(got, [b"BLOBLYNETV0SUT001"])

    def test_close_from_another_thread_ends_a_call_in_progress(self):
        silent = self.can1.uds(tx=0x6F0, rx=0x6F8)  # nothing answers there
        out = []

        def ask():
            try:
                silent.read_did(0xF190)
            except blobly.BloblyError as e:
                out.append(e)
        t = threading.Thread(target=ask)
        t.start()
        time.sleep(0.15)  # inside the 1000 ms wait
        start = time.monotonic()
        silent.close()
        t.join(5)
        self.assertLess(time.monotonic() - start, 0.5, "the close waited out the call")
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0].code, _lib.BB_ERR_HANDLE)


class TestLifecycle(unittest.TestCase):
    def test_a_stop_and_start_reopen_the_connection(self):
        net = blobly.Project(SIM_DEMO)
        with net:
            d = net.channels.CAN1.uds()
            self.assertEqual(d.read_did(0xF18C), b"SN-0001")
        self.assertIsNone(d.last, "the stop let the connection go")
        with self.assertRaises(blobly.BloblyError):
            d.read_did(0xF18C)  # not started
        with net:
            self.assertEqual(d.read_did(0xF18C), b"SN-0001", "the client did not reopen")
            d.close()

    def test_a_client_of_another_projects_load_refuses(self):
        with blobly.Project(SIM_DEMO) as net:
            d = net.channels.CAN1.uds()
        blobly.Project(DEMO).load()
        with self.assertRaises(blobly.BloblyError):
            d.read_did(0xF18C)

    def test_a_project_not_started_opens_nothing(self):
        net = blobly.Project(SIM_DEMO).load()
        with self.assertRaises(blobly.BloblyError) as e:
            net.channels.CAN1.uds()
        self.assertEqual(e.exception.code, _lib.BB_ERR_STATE)


class FakeEcu:
    """Answers single-frame requests on `ch` (physical 0x700 in, 0x708 out) from `script`, a
    list of answers in order, each a list of single-frame payloads to send for one request."""

    def __init__(self, ch, script):
        self.ch, self.script, self.seen = ch, list(script), []
        ch.look()  # its handle open before the client's first request: opened later, it misses it
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        try:
            while self.script:
                f = self.ch.recv(3000)
                if f is None:
                    return
                if f.id != 0x700:
                    continue
                self.seen.append(f.data[1:1 + f.data[0]])
                for answer in self.script.pop(0):
                    self.ch.send(0x708, bytes([len(answer)]) + answer)
        except blobly.BloblyError:
            pass  # the test ended and its project stopped under the wait


class TestFailures(unittest.TestCase):
    """The failures sim-demo's ECUs never produce."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        path = os.path.join(self.dir.name, "bare.blobnet")
        with open(path, "w") as f:
            f.write(BARE)
        self.net = blobly.Project(path).start()
        self.addCleanup(self.net.stop)
        self.ch = self.net.channels.B
        self.diag = self.ch.uds(tx=0x700, rx=0x708)
        self.addCleanup(self.diag.close)

    def test_pending_then_silence(self):
        # a 0x10 answer announcing P2* = 10 ms, so the wait after 0x78 is 1010 ms, not 6 s
        ecu = FakeEcu(self.ch, [[b"\x50\x01\x00\x32\x00\x01"], [b"\x7f\x31\x78"]])
        self.diag.session(0x01)
        t = time.monotonic()
        with self.assertRaises(blobly.PendingExpired):
            self.diag.raw(b"\x31\x01\x02\x03")
        self.assertLess(time.monotonic() - t, 3)
        x = self.diag.last
        self.assertEqual(x.pending, 1)
        self.assertGreater(x.pending_us, 0)
        ecu.thread.join(1)

    def test_an_answer_that_cannot_be_read(self):
        FakeEcu(self.ch, [[b"\x62\xf1"]])  # too short to echo the DID
        with self.assertRaises(blobly.UndecodableAnswer):
            self.diag.read_did(0xF190)
        self.assertEqual(self.diag.last.answer, b"\x62\xf1")

    def test_a_listen_only_wire_refuses_the_request(self):
        silent = os.path.join(self.dir.name, "silent.blobnet")
        with open(silent, "w") as f:
            f.write(BARE.replace("PY_UDS_FAKE", "PY_UDS_SILENT") + "    listen_only: true\n")
        self.net.stop()
        with blobly.Project(silent) as net, net.channels.B.uds() as diag:
            with self.assertRaises(blobly.Refused) as e:
                diag.tester_present()
            self.assertIn("listen-only", str(e.exception))
            self.assertFalse(diag.last.sent)
        self.net.start()

    def test_a_late_answer_to_another_request_is_skipped(self):
        FakeEcu(self.ch, [[b"\x62\xf1\x8cOLD", b"\x62\xf1\x90NEW"]])
        self.assertEqual(self.diag.read_did(0xF190), b"NEW")


if __name__ == "__main__":
    unittest.main()
