"""DTCs and functional addressing from Python against projects/sim-demo.blobnet's simulated ECUs,
the coverage of the Lua suites tests/diag_advanced.lua (0x19 01 / 02 / 0A), tests/diag_functional.lua
and blobly/script/records_test.v (0x19 03 / 04 / 06 against CAN2's built-in server), plus answers
sim-demo never gives, from a fake ECU on an in-process bus."""
import threading

import pytest

import blobly
from blobly import _lib
from conftest import SIM_DEMO, write

pytestmark = pytest.mark.usefixtures("engine")

BARE = """project:
  name: bare
  version: 8
channels:
  - name: B
    type: can
    interface: inproc:PY_UDS_DTC_FAKE
"""


@pytest.fixture(scope="class")
def sut(sim_demo):
    """A client of CAN1's SUT, configured with two DTCs."""
    with sim_demo.channels.CAN1.uds() as d:
        yield d


@pytest.fixture(scope="class")
def builtin(sim_demo):
    """A client of CAN2's built-in server, which also stores a snapshot and extended data."""
    with sim_demo.channels.CAN2.uds() as d:
        yield d


@pytest.fixture(scope="class")
def can1(sim_demo):
    return sim_demo.channels.CAN1


class TestDtcs:
    def test_dtcs_as_records_with_named_status_bits(self, sut):
        assert sut.dtc_count() == 2
        every = sut.supported_dtcs()
        assert [d.name for d in every] == ["P1234-56", "B2BCD-EF"]
        first = every[0]
        assert (first.code, first.status) == (0x123456, 0x09)
        assert first.bits["confirmedDTC"] and first.bits["testFailed"]
        assert not every[1].bits["testFailed"]
        assert len(sut.dtcs(0x01)) == 1, "only one has testFailed"
        assert len(sut.dtcs()) == 2

    def test_a_bit_outside_the_availability_mask_is_not_reported(self, sut):
        every = sut.supported_dtcs()
        for d in every:
            for mask, name in ((0x01, "testFailed"), (0x80, "warningIndicatorRequested")):
                assert (name in d.bits) == bool(d.availability & mask), (d.name, name)

    def test_snapshots_and_extended_data(self, builtin):
        ids = builtin.snapshot_ids()
        assert [(i.name, i.record) for i in ids] == [("P1234-56", 0x01)]
        s = builtin.snapshot("P1234-56")  # the DIDs' sizes learned by reading them (0x22)
        assert s.dtc.bits["confirmedDTC"] and s.dtc.bits["testFailed"], "the status rides along"
        assert len(s.records) == 1
        assert s.records[0].number == 0x01
        assert s.records[0].dids == {0xF195: b"\x01\x00", 0xF18C: b"SN-0001"}
        assert list(s.records[0].dids) == [0xF195, 0xF18C], "the ECU's order"
        assert builtin.snapshot(0xABCDEF).records == [], "by code; nothing stored"
        e = builtin.extended("p1234-56")  # a name in either case
        assert (e.occurrence, e.aging, e.failed_cycles) == (3, 0, 1)
        assert e.records[0x01] == b"\x00\x03"
        assert builtin.extended("B2BCD-EF").aging == 2
        assert builtin.extended("P1234-56", 0x01).aging is None, "only the record asked for"
        with pytest.raises(blobly.NegativeResponse) as err:
            builtin.extended("P1234-56", 0x04)
        assert err.value.nrc == 0x31
        with pytest.raises(blobly.NegativeResponse):
            builtin.snapshot("U0001-00")

    def test_a_dtc_given_wrong_is_refused_before_anything_is_sent(self, sut):
        before = sut.last
        with pytest.raises(ValueError):
            sut.snapshot("not a DTC")
        with pytest.raises(blobly.Refused):
            sut.extended(0x1000000)  # past 24 bits
        with pytest.raises(blobly.Refused):
            sut.dtcs(0x100)  # a mask is a byte
        assert sut.last == before


class TestFunctional:
    @pytest.fixture
    def ds(self, can1):
        """The two ECUs on CAN1, each a client of its own."""
        with can1.uds(tx=0x7E0, rx=0x7E8) as a, can1.uds(tx=0x7E1, rx=0x7E9) as b:
            yield [a, b]

    def test_both_ecus_answer_one_request_each_multi_frame(self, can1, ds):
        ds[0].tester_present()
        rs = can1.uds_functional(0x7DF, ds, b"\x22\xf1\x90")
        assert ds[0].last is None, "last still described the request before the functional one"
        assert [r.outcome for r in rs] == ["positive", "positive"]
        assert rs[0].answer[3:] == b"BLOBLYNETV0SUT001"
        assert rs[1].answer[3:] == b"BLOBLY-CHASSIS-01"
        assert (rs[0].nrc, rs[0].pended, rs[0].error) == (None, False, "")

    def test_a_refusal_iso_suppresses_is_silence_one_it_does_not_is_reported(self, can1, ds):
        rs = can1.uds_functional(0x7DF, ds, b"\x22\xab\xcd", window_ms=300)  # 0x31, suppressed
        assert [r.outcome for r in rs] == ["silent", "silent"]
        rs = can1.uds_functional(0x7DF, ds, b"\x19\x01", window_ms=300)  # 0x13, answered
        assert [(r.outcome, r.nrc) for r in rs] == [("negative", 0x13), ("negative", 0x13)]

    def test_a_suppressed_positive_response_is_silence_and_physical_still_works(self, can1, ds):
        rs = can1.uds_functional(0x7DF, ds, b"\x3e\x80", window_ms=300)
        assert [r.outcome for r in rs] == ["silent", "silent"]
        assert ds[0].read_did(0xF190) == b"BLOBLYNETV0SUT001"

    def test_what_is_refused(self, sim_demo, can1, ds):
        with can1.uds(tx=0x7E0, rx=0x7E8) as twin, sim_demo.channels.CAN2.uds() as other_row:
            ds[0].tester_present()
            before = ds[0].last
            with pytest.raises(blobly.Refused):
                can1.uds_functional(0x7DF, ds, bytes(8))  # one Single Frame: 7 bytes at most
            assert ds[0].last == before, "a refused request cleared the last exchange"
            with pytest.raises(blobly.Refused):
                can1.uds_functional(0x7DF, [ds[0], twin], b"\x3e\x00")  # one response id twice
            with pytest.raises(blobly.BloblyError):
                can1.uds_functional(0x7DF, [other_row], b"\x3e\x00")  # another row's
            with pytest.raises(blobly.BloblyError):  # a client of another row
                sim_demo.channels.DoIP1.uds_functional(0xE400, [ds[0]], b"\x3e\x00")
            with pytest.raises(ValueError):
                can1.uds_functional(0x7DF, [ds[0], ds[0]], b"\x3e\x00")
            with pytest.raises(ValueError):
                can1.uds_functional(0x7DF, [], b"\x3e\x00")  # nothing to answer it


class TestReentry:
    def test_functional_from_a_key_fn_does_not_wait_on_a_busy_client(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            a, b = can1.uds(tx=0x7E0, rx=0x7E8), can1.uds(tx=0x7E1, rx=0x7E9)
            a.session(0x01)
            held, release = threading.Event(), threading.Event()

            def hold_b():  # another thread inside a call on B
                with b._lock:
                    held.set()
                    release.wait(5)
            t = threading.Thread(target=hold_b)
            t.start()
            held.wait(5)
            errors = []

            def key_fn(seed):
                try:
                    can1.uds_functional(0x7DF, [b], b"\x3e\x00", window_ms=100)
                except blobly.BloblyError as e:
                    errors.append(e)
                return blobly.reference_key(seed)
            try:
                a.security_access(0x01, key_fn)
            finally:
                release.set()
                t.join(5)
                a.close()
                b.close()
            assert [e.code for e in errors] == [_lib.BB_ERR_STATE], "it waited, or did not refuse"


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


class TestUnreadable:
    @pytest.fixture
    def net(self, tmp_path):
        net = blobly.Project(write(tmp_path, "bare.blobnet", BARE)).start()
        yield net
        net.stop()

    @pytest.fixture
    def ch(self, net):
        return net.channels.B

    @pytest.fixture
    def diag(self, ch):
        with ch.uds(tx=0x700, rx=0x708) as d:
            yield d

    def test_a_dtc_list_that_is_not_whole_records(self, ch, diag):
        FakeEcu(ch, [b"\x59\x0a\xff\x12\x34"])
        with pytest.raises(blobly.UndecodableAnswer):
            diag.supported_dtcs()

    def test_an_extended_record_of_a_size_it_is_told(self, ch, diag):
        answer = b"\x59\x06\x12\x34\x56\x09\x10"  # record 0x10, empty: not blobly_emb's
        FakeEcu(ch, [answer, answer])
        with pytest.raises(blobly.UndecodableAnswer):
            diag.extended(0x123456)
        diag.ext_record_size(0x10, 0)
        assert diag.extended(0x123456).records == {0x10: b""}
        with pytest.raises(blobly.Refused):
            diag.ext_record_size(0x10, 4089)  # no ISO-TP answer could carry it
        with pytest.raises(blobly.Refused):
            diag.did_size(0xF190, 4086)

    def test_a_stated_size_holds_on_the_next_connection(self, net, ch, diag):
        diag.ext_record_size(0x10, 0)
        net.stop()  # the connection is let go; the next call opens another
        net.start()
        FakeEcu(ch, [b"\x59\x06\x12\x34\x56\x09\x10"])
        assert diag.extended(0x123456).records == {0x10: b""}
