"""UDS from Python against projects/sim-demo.blobnet's simulated ECUs, the coverage of the Lua
suites tests/diag_basic.lua and tests/diag_advanced.lua (sessions, DIDs, 0x27, 0x11, 0x14, 0x28,
0x85, suppressed requests, the refusals), plus what only a host sees: typed errors, the timing of
the last exchange, a connection let go and reopened across a stop, a close from another thread,
and the failures sim-demo cannot produce (responsePending then silence, an undecodable answer),
answered by a fake ECU on an in-process bus."""
import os
import threading
import time

import pytest

import blobly
from blobly import _lib
from conftest import DEMO, SIM_DEMO

# one in-process row and no simulation: the tests' own fake ECU answers on it
BARE = """project:
  name: bare
  version: 8
channels:
  - name: B
    type: can
    interface: inproc:PY_UDS_FAKE
"""

pytestmark = pytest.mark.usefixtures("engine")


@pytest.fixture(scope="class")
def can1(sim_demo):
    return sim_demo.channels.CAN1


class TestSimDemo:
    """diag_basic.lua and diag_advanced.lua, from Python."""

    @pytest.fixture
    def diag(self, can1):
        with can1.uds(tx=0x7E0, rx=0x7E8) as client:
            yield client

    def test_sessions_and_dids(self, diag):
        params = diag.session(0x01)
        assert params[:1] == b"\x01", "the answer starts with the session"
        assert diag.read_did(0xF190) == b"BLOBLYNETV0SUT001"  # multi-frame
        assert diag.read_did(0xF18C) == b"SN-0001"
        assert diag.read_did(0xF195) == b"\x01\x00"
        diag.tester_present()
        time.sleep(0.02)
        diag.tester_present()

    def test_the_default_ids_and_the_ecus_apart(self, can1, diag):
        with can1.uds() as d:
            assert (d.tx, d.rx, d.ext) == (0x7E0, 0x7E8, False)
            with can1.uds(tx=0x7E1, rx=0x7E9) as chassis:
                assert chassis.read_did(0xF190) == b"BLOBLY-CHASSIS-01"
            with can1.uds(tx=0x18DA10F1, rx=0x18DAF110) as wide:
                assert wide.ext, "an id past 0x7FF makes the pair 29-bit"

    def test_a_negative_response_is_typed_and_carries_its_nrc(self, diag):
        with pytest.raises(blobly.NegativeResponse) as e:
            diag.read_did(0xABCD)
        assert e.value.nrc == 0x31
        assert e.value.nrc_name == "requestOutOfRange"
        assert e.value.code == _lib.BB_ERR_NEGATIVE
        assert isinstance(e.value, blobly.BloblyError)
        assert e.value.exchange.answer == b"\x7f\x22\x31"
        assert diag.last.nrc == 0x31

    def test_id_zero_is_an_id_and_nothing_answers_it(self, can1, diag):
        with can1.uds(tx=0, rx=0) as zero:
            assert (zero.tx, zero.rx) == (0, 0), "0 was replaced by the default"
            t = time.monotonic()
            with pytest.raises(blobly.Timeout, match="no answer to 0x22"):
                zero.read_did(0xF190)
            assert time.monotonic() - t < 5, "the wait is bounded"
            assert zero.last.sent
            assert zero.last.answer == b""

    def test_an_id_that_is_not_a_can_identifier_is_refused(self, can1, diag):
        for bad in ({"tx": -2}, {"rx": 0x2000_0000}):
            with pytest.raises(blobly.Refused, match="is not a CAN identifier"):
                can1.uds(**bad)
        with pytest.raises(TypeError):
            can1.uds(tx=1.5)
        with pytest.raises(TypeError):
            can1.uds(tx=True)

    def test_write_then_read_back(self, diag):
        diag.write_did(0xF1AA, b"\xca\xfe")
        assert diag.read_did(0xF1AA) == b"\xca\xfe"

    def test_security_access(self, diag):
        diag.session(0x01)  # locked
        seed = diag.security_access(0x01)  # the reference key
        assert seed == b"\x11\x22\x33\x44"

        def no_key(s):
            raise AssertionError("a key was computed for an all-zero seed")
        assert diag.security_access(0x01, no_key) == b"\x00\x00\x00\x00"
        diag.session(0x01)  # relock: a session change locks the server again
        with pytest.raises(blobly.NegativeResponse) as e:
            diag.security_access(0x01, lambda s: s)  # the seed is not the key
        assert e.value.nrc == 0x35
        assert e.value.exchange.request[:2] == b"\x27\x02", "the key went out at level + 1"
        assert blobly.reference_key(b"\x11\x22") == b"\xee\xdd"
        with pytest.raises(blobly.Refused):
            diag.security_access(0x02)  # a seed is requested at an odd level
        with pytest.raises(blobly.Refused):
            diag.security_access(0x7F)  # no key level answers it
        before = diag.last
        with pytest.raises(blobly.Refused):
            diag.reset(0x81)  # suppressed: no answer would come; raw_suppressed is for that
        with pytest.raises(blobly.Refused):
            diag.session(0x81)
        assert diag.last == before, "a refused sub-function was sent"

    def test_reset_dtc_setting_and_comm_control(self, diag):
        assert diag.reset(0x01) == b"\x01"
        with pytest.raises(blobly.NegativeResponse) as e:
            diag.reset(0x09)
        assert e.value.nrc == 0x12
        diag.dtc_setting(False)
        diag.dtc_setting(True)
        for v in (None, 1, "on"):
            with pytest.raises(TypeError):
                diag.dtc_setting(v)
        with pytest.raises(blobly.NegativeResponse) as e:
            diag.comm_control(0x03)  # the simulated ECU cannot gate its traffic, so it refuses
        assert e.value.nrc == 0x11

    def test_a_suppressed_positive_response_is_silence(self, diag):
        assert not diag.raw_suppressed(b"\x3e\x00")
        assert diag.last.request == b"\x3e\x80", "the bit went out set"
        assert not diag.raw_suppressed(b"\x10\x01")
        with pytest.raises(blobly.NegativeResponse) as e:
            diag.raw_suppressed(b"\x11\x05")
        assert e.value.nrc == 0x12
        with pytest.raises(blobly.Refused):
            diag.raw_suppressed(b"\x22\xf1\x90")  # no sub-function to suppress with

    def test_clear_refuses_what_it_cannot_clear(self, diag):
        with pytest.raises(blobly.NegativeResponse) as e:
            diag.clear_dtcs(0x000001)  # no such DTC
        assert e.value.nrc == 0x31
        with pytest.raises(blobly.NegativeResponse) as e:
            diag.raw(b"\x14\xff\xff")  # a group is three bytes
        assert e.value.nrc == 0x13
        before = diag.last
        for g in (-1, 0x1FFFFFF):
            with pytest.raises(blobly.Refused, match="24-bit"):
                diag.clear_dtcs(g)
        assert diag.last == before, "a refused group was sent"
        for g in (1.5, False):
            with pytest.raises(TypeError):
                diag.clear_dtcs(g)
        with pytest.raises(ValueError):
            diag.reset(2**32 + 1)  # would arrive as 1

    def test_raw_and_the_timing_of_the_last_exchange(self, can1, diag):
        assert can1.uds().last is None, "a fresh client has no exchange yet"
        assert diag.raw(b"\x22\xf1\x8c") == b"\x62\xf1\x8cSN-0001"
        x = diag.last
        assert (x.request, x.answer, x.nrc) == (b"\x22\xf1\x8c", b"\x62\xf1\x8cSN-0001", None)
        assert x.sent
        assert x.rtt_us > 0
        assert (x.pending, x.pending_us) == (0, 0)
        with pytest.raises(blobly.Refused):
            diag.raw(b"")
        assert not diag.last.sent, "an empty request reached the carrier"
        with pytest.raises(blobly.Refused):
            diag.raw(bytes(4096))  # past ISO-TP's 4095
        with pytest.raises(TypeError):
            diag.raw("22 F1 90")

    def test_a_closed_client_refuses(self, can1, diag):
        d = can1.uds()
        with d:
            d.tester_present()
        with pytest.raises(blobly.BloblyError) as e:
            d.tester_present()
        assert e.value.code == _lib.BB_ERR_HANDLE
        d.close()  # twice is nothing

    def test_security_access_is_one_operation_for_threads_sharing_a_client(self, diag):
        diag.session(0x01)  # locked
        in_key, other = threading.Event(), []

        def slow_key(seed):
            in_key.set()
            time.sleep(0.1)  # another thread's call must wait, not change the session under the seed
            return blobly.reference_key(seed)
        t = threading.Thread(target=lambda: other.append(diag.session(0x01)))
        worker = threading.Thread(target=lambda: other.append(diag.security_access(0x01, slow_key)))
        worker.start()
        in_key.wait(5)
        t.start()
        worker.join(5)
        t.join(5)
        assert other[0] == b"\x11\x22\x33\x44", "the key was refused: a call came between seed and key"

    def test_a_client_on_a_worker_thread(self, diag):
        got = []
        t = threading.Thread(target=lambda: got.append(diag.read_did(0xF190)))
        t.start()
        t.join(10)
        assert got == [b"BLOBLYNETV0SUT001"]

    def test_close_from_another_thread_ends_a_call_in_progress(self, can1, diag):
        silent = can1.uds(tx=0x6F0, rx=0x6F8)  # nothing answers there
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
        assert time.monotonic() - start < 0.5, "the close waited out the call"
        assert len(out) == 1
        assert out[0].code == _lib.BB_ERR_HANDLE


class TestLifecycle:
    def test_a_stop_and_start_reopen_the_connection(self):
        net = blobly.Project(SIM_DEMO)
        with net:
            d = net.channels.CAN1.uds()
            assert d.read_did(0xF18C) == b"SN-0001"
        assert d.last is None, "the stop let the connection go"
        with pytest.raises(blobly.BloblyError):
            d.read_did(0xF18C)  # not started
        with net:
            assert d.read_did(0xF18C) == b"SN-0001", "the client did not reopen"
            d.close()

    def test_a_client_of_another_projects_load_refuses(self):
        with blobly.Project(SIM_DEMO) as net:
            d = net.channels.CAN1.uds()
        blobly.Project(DEMO).load()
        with pytest.raises(blobly.BloblyError):
            d.read_did(0xF18C)

    def test_a_stop_inside_key_fn_fails_the_key_rather_than_reconnect(self):
        net = blobly.Project(SIM_DEMO)
        with net:
            d = net.channels.CAN1.uds()
            d.session(0x01)

            def restart(seed):
                net.stop()
                net.start()
                return blobly.reference_key(seed)
            with pytest.raises(blobly.BloblyError) as e:
                d.security_access(0x01, restart)
            assert e.value.code == _lib.BB_ERR_HANDLE, "the key went out on a new connection"
            d.close()

    def test_a_collected_client_is_let_go_at_the_next_call(self):
        import gc
        from blobly import uds
        with blobly.Project(SIM_DEMO) as net:
            net.channels.CAN1.uds().read_did(0xF18C)  # never closed: collected
            gc.collect()
            assert uds._orphans, "the finalizer closed it on the spot"
            with net.channels.CAN1.uds() as d:
                assert uds._orphans == [], "an open left it"
                with pytest.raises(blobly.NegativeResponse) as e:
                    d.read_did(0xABCD)
                assert e.value.nrc == 0x31

    def test_a_project_not_started_opens_nothing(self):
        net = blobly.Project(SIM_DEMO).load()
        with pytest.raises(blobly.BloblyError) as e:
            net.channels.CAN1.uds()
        assert e.value.code == _lib.BB_ERR_STATE


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


class TestFailures:
    """The failures sim-demo's ECUs never produce."""

    @pytest.fixture
    def net(self, tmp_path):
        path = os.path.join(tmp_path, "bare.blobnet")
        with open(path, "w") as f:
            f.write(BARE)
        net = blobly.Project(path).start()
        yield net
        net.stop()

    @pytest.fixture
    def ch(self, net):
        return net.channels.B

    @pytest.fixture
    def diag(self, ch):
        with ch.uds(tx=0x700, rx=0x708) as client:
            yield client

    def test_pending_then_silence(self, ch, diag):
        # a 0x10 answer announcing P2* = 10 ms, so the wait after 0x78 is 1010 ms, not 6 s
        ecu = FakeEcu(ch, [[b"\x50\x01\x00\x32\x00\x01"], [b"\x7f\x31\x78"]])
        diag.session(0x01)
        t = time.monotonic()
        with pytest.raises(blobly.PendingExpired):
            diag.raw(b"\x31\x01\x02\x03")
        assert time.monotonic() - t < 3
        x = diag.last
        assert x.pending == 1
        assert x.pending_us > 0
        ecu.thread.join(1)

    def test_an_answer_that_cannot_be_read(self, ch, diag):
        FakeEcu(ch, [[b"\x62\xf1"]])  # too short to echo the DID
        with pytest.raises(blobly.UndecodableAnswer):
            diag.read_did(0xF190)
        assert diag.last.answer == b"\x62\xf1"

    def test_a_listen_only_wire_refuses_the_request(self, tmp_path, net, diag):
        silent = os.path.join(tmp_path, "silent.blobnet")
        with open(silent, "w") as f:
            f.write(BARE.replace("PY_UDS_FAKE", "PY_UDS_SILENT") + "    listen_only: true\n")
        net.stop()
        with blobly.Project(silent) as other, other.channels.B.uds() as quiet:
            with pytest.raises(blobly.Refused, match="listen-only"):
                quiet.tester_present()
            assert not quiet.last.sent
        net.start()

    def test_a_late_answer_to_another_request_is_skipped(self, ch, diag):
        FakeEcu(ch, [[b"\x62\xf1\x8cOLD", b"\x62\xf1\x90NEW"]])
        assert diag.read_did(0xF190) == b"NEW"
