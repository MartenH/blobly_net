"""DTCs and functional addressing from Python against projects/sim-demo.blobnet's simulated ECUs,
the coverage of the Lua suites tests/diag_advanced.lua (0x19 01 / 02 / 0A), tests/diag_functional.lua
and blobly/script/records_test.v (0x19 03 / 04 / 06 against CAN2's built-in server), plus answers
sim-demo never gives, from a fake ECU on an in-process bus."""
import os
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
# the source tree, unless the run is of an installed wheel (BLOBLY_TEST_INSTALLED)
if not os.environ.get("BLOBLY_TEST_INSTALLED"):
    sys.path.insert(0, os.path.join(HERE, ".."))
import blobly  # noqa: E402
from blobly import _lib  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
SIM_DEMO = os.path.join(REPO, "projects", "sim-demo.blobnet")

BARE = """project:
  name: bare
  version: 8
channels:
  - name: B
    type: can
    interface: inproc:PY_UDS_DTC_FAKE
"""


def setUpModule():
    try:
        _lib.lib()
    except blobly.BloblyError as e:
        if os.environ.get("BLOBLY_LIB") or os.environ.get("BLOBLY_TEST_INSTALLED"):
            raise
        raise unittest.SkipTest(str(e))


class TestDtcs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.net = blobly.Project(SIM_DEMO).start()
        # CAN1's SUT is configured with two DTCs; CAN2 runs the built-in server, which also
        # stores a snapshot and extended data
        cls.sut = cls.net.channels.CAN1.uds()
        cls.builtin = cls.net.channels.CAN2.uds()

    @classmethod
    def tearDownClass(cls):
        cls.sut.close()
        cls.builtin.close()
        cls.net.stop()

    def test_dtcs_as_records_with_named_status_bits(self):
        self.assertEqual(self.sut.dtc_count(), 2)
        every = self.sut.supported_dtcs()
        self.assertEqual([d.name for d in every], ["P1234-56", "B2BCD-EF"])
        first = every[0]
        self.assertEqual((first.code, first.status), (0x123456, 0x09))
        self.assertTrue(first.bits["confirmedDTC"] and first.bits["testFailed"])
        self.assertFalse(every[1].bits["testFailed"])
        self.assertEqual(len(self.sut.dtcs(0x01)), 1, "only one has testFailed")
        self.assertEqual(len(self.sut.dtcs()), 2)

    def test_a_bit_outside_the_availability_mask_is_not_reported(self):
        every = self.sut.supported_dtcs()
        for d in every:
            for mask, name in ((0x01, "testFailed"), (0x80, "warningIndicatorRequested")):
                if d.availability & mask:
                    self.assertIn(name, d.bits)
                else:
                    self.assertNotIn(name, d.bits)

    def test_snapshots_and_extended_data(self):
        ids = self.builtin.snapshot_ids()
        self.assertEqual([(i.name, i.record) for i in ids], [("P1234-56", 0x01)])
        s = self.builtin.snapshot("P1234-56")  # the DIDs' sizes learned by reading them (0x22)
        self.assertTrue(s.dtc.bits["confirmedDTC"] and s.dtc.bits["testFailed"], "the status rides along")
        self.assertEqual(len(s.records), 1)
        self.assertEqual(s.records[0].number, 0x01)
        self.assertEqual(s.records[0].dids, {0xF195: b"\x01\x00", 0xF18C: b"SN-0001"})
        self.assertEqual(list(s.records[0].dids), [0xF195, 0xF18C], "the ECU's order")
        self.assertEqual(self.builtin.snapshot(0xABCDEF).records, [], "by code; nothing stored")
        e = self.builtin.extended("p1234-56")  # a name in either case
        self.assertEqual((e.occurrence, e.aging, e.failed_cycles), (3, 0, 1))
        self.assertEqual(e.records[0x01], b"\x00\x03")
        self.assertEqual(self.builtin.extended("B2BCD-EF").aging, 2)
        self.assertIsNone(self.builtin.extended("P1234-56", 0x01).aging, "only the record asked for")
        with self.assertRaises(blobly.NegativeResponse) as err:
            self.builtin.extended("P1234-56", 0x04)
        self.assertEqual(err.exception.nrc, 0x31)
        with self.assertRaises(blobly.NegativeResponse):
            self.builtin.snapshot("U0001-00")

    def test_a_dtc_given_wrong_is_refused_before_anything_is_sent(self):
        before = self.sut.last
        with self.assertRaises(ValueError):
            self.sut.snapshot("not a DTC")
        with self.assertRaises(blobly.Refused):
            self.sut.extended(0x1000000)  # past 24 bits
        with self.assertRaises(blobly.Refused):
            self.sut.dtcs(0x100)  # a mask is a byte
        self.assertEqual(self.sut.last, before)


class TestFunctional(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.net = blobly.Project(SIM_DEMO).start()
        cls.can1 = cls.net.channels.CAN1

    @classmethod
    def tearDownClass(cls):
        cls.net.stop()

    def ecus(self):
        a, b = self.can1.uds(tx=0x7E0, rx=0x7E8), self.can1.uds(tx=0x7E1, rx=0x7E9)
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        return [a, b]

    def test_both_ecus_answer_one_request_each_multi_frame(self):
        ds = self.ecus()
        ds[0].tester_present()
        rs = self.can1.uds_functional(0x7DF, ds, b"\x22\xf1\x90")
        self.assertIsNone(ds[0].last, "last still described the request before the functional one")
        self.assertEqual([r.outcome for r in rs], ["positive", "positive"])
        self.assertEqual(rs[0].answer[3:], b"BLOBLYNETV0SUT001")
        self.assertEqual(rs[1].answer[3:], b"BLOBLY-CHASSIS-01")
        self.assertEqual((rs[0].nrc, rs[0].pended, rs[0].error), (None, False, ""))

    def test_a_refusal_iso_suppresses_is_silence_one_it_does_not_is_reported(self):
        ds = self.ecus()
        rs = self.can1.uds_functional(0x7DF, ds, b"\x22\xab\xcd", window_ms=300)  # 0x31, suppressed
        self.assertEqual([r.outcome for r in rs], ["silent", "silent"])
        rs = self.can1.uds_functional(0x7DF, ds, b"\x19\x01", window_ms=300)  # 0x13, answered
        self.assertEqual([(r.outcome, r.nrc) for r in rs], [("negative", 0x13), ("negative", 0x13)])

    def test_a_suppressed_positive_response_is_silence_and_physical_still_works(self):
        ds = self.ecus()
        rs = self.can1.uds_functional(0x7DF, ds, b"\x3e\x80", window_ms=300)
        self.assertEqual([r.outcome for r in rs], ["silent", "silent"])
        self.assertEqual(ds[0].read_did(0xF190), b"BLOBLYNETV0SUT001")

    def test_what_is_refused(self):
        ds = self.ecus()
        twin, other_row = self.can1.uds(tx=0x7E0, rx=0x7E8), self.net.channels.CAN2.uds()
        self.addCleanup(twin.close)
        self.addCleanup(other_row.close)
        ds[0].tester_present()
        before = ds[0].last
        with self.assertRaises(blobly.Refused):
            self.can1.uds_functional(0x7DF, ds, bytes(8))  # one Single Frame: 7 bytes at most
        self.assertEqual(ds[0].last, before, "a refused request cleared the last exchange")
        with self.assertRaises(blobly.Refused):
            self.can1.uds_functional(0x7DF, [ds[0], twin], b"\x3e\x00")  # one response id twice
        with self.assertRaises(blobly.BloblyError):
            self.can1.uds_functional(0x7DF, [other_row], b"\x3e\x00")  # another row's
        with self.assertRaises(blobly.BloblyError):  # a DoIP row has no UDS client of its own yet
            self.net.channels.DoIP1.uds_functional(0xE400, [ds[0]], b"\x3e\x00")
        with self.assertRaises(ValueError):
            self.can1.uds_functional(0x7DF, [ds[0], ds[0]], b"\x3e\x00")
        with self.assertRaises(ValueError):
            self.can1.uds_functional(0x7DF, [], b"\x3e\x00")  # nothing to answer it


class FakeEcu:
    """Answers single-frame requests on `ch` (0x700 in, 0x708 out), each with the next of
    `script`'s answers."""

    def __init__(self, ch, script):
        self.ch, self.script = ch, list(script)
        ch.look()  # its handle open before the client's first request
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        try:
            while self.script:
                f = self.ch.recv(3000)
                if f is None:
                    return
                if f.id == 0x700:
                    answer = self.script.pop(0)
                    self.ch.send(0x708, bytes([len(answer)]) + answer)
        except blobly.BloblyError:
            pass  # the test ended and its project stopped under the wait


class TestUnreadable(unittest.TestCase):
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

    def test_a_dtc_list_that_is_not_whole_records(self):
        FakeEcu(self.ch, [b"\x59\x0a\xff\x12\x34"])
        with self.assertRaises(blobly.UndecodableAnswer):
            self.diag.supported_dtcs()

    def test_an_extended_record_of_a_size_it_is_told(self):
        answer = b"\x59\x06\x12\x34\x56\x09\x10"  # record 0x10, empty: not blobly_emb's
        FakeEcu(self.ch, [answer, answer])
        with self.assertRaises(blobly.UndecodableAnswer):
            self.diag.extended(0x123456)
        self.diag.ext_record_size(0x10, 0)
        self.assertEqual(self.diag.extended(0x123456).records, {0x10: b""})
        with self.assertRaises(blobly.Refused):
            self.diag.ext_record_size(0x10, 4089)  # no ISO-TP answer could carry it
        with self.assertRaises(blobly.Refused):
            self.diag.did_size(0xF190, 4086)

    def test_a_stated_size_holds_on_the_next_connection(self):
        self.diag.ext_record_size(0x10, 0)
        self.net.stop()  # the connection is let go; the next call opens another
        self.net.start()
        FakeEcu(self.ch, [b"\x59\x06\x12\x34\x56\x09\x10"])
        self.assertEqual(self.diag.extended(0x123456).records, {0x10: b""})


if __name__ == "__main__":
    unittest.main()
