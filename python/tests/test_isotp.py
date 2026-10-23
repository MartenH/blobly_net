"""Raw ISO-TP from Python (Channel.isotp): whole messages on an id pair with no UDS on top, against
projects/sim-demo.blobnet's simulated ECUs (a request and its multi-frame answer, a malformed UDS
request and the bytes that come back, a long request segmented), the lifecycle a UdsClient has, and
what only a peer of the test's own on an in-process bus does: no Flow Control, an overflow, a
transfer that stops partway, a listen-only row. tests/isotp_timing.lua is the Lua twin."""
import os
import threading
import time

import pytest

import blobly
from blobly import _lib
from conftest import SIM_DEMO, write

pytestmark = pytest.mark.usefixtures("engine")

VIN_ANSWER = b"\x62\xf1\x90BLOBLYNETV0SUT001"

# one in-process row and no simulation: the test's own peer answers on it
BARE = """project:
  name: bare
  version: 8
channels:
  - name: B
    type: can
    interface: inproc:PY_ISOTP_PEER
"""


@pytest.fixture(scope="class")
def can1(sim_demo):
    return sim_demo.channels.CAN1


class TestSimDemo:
    def test_a_request_and_its_multi_frame_answer(self, can1):
        with can1.isotp(0x7E0, 0x7E8) as tp:
            assert (tp.tx, tp.rx, tp.ext) == (0x7E0, 0x7E8, False)
            assert repr(tp) == "<IsoTp CAN1 0x7E0/0x7E8>"
            tp.send(b"\x22\xf1\x90")
            assert tp.recv() == VIN_ANSWER

    def test_a_malformed_uds_request_comes_back_as_bytes(self, can1):
        with can1.isotp(0x7E0, 0x7E8) as tp:
            tp.send(b"\x22\xf1")  # a DID cut short: incorrectMessageLengthOrInvalidFormat
            assert tp.recv() == b"\x7f\x22\x13"

    def test_a_long_message_goes_out_segmented(self, can1):
        with can1.isotp(0x7E0, 0x7E8) as tp:
            tp.send(b"\x2e\xf1\xaa" + bytes(range(20)))  # a First Frame, then Consecutive Frames
            answer = tp.recv()
            assert answer is not None and answer[0] in (0x6E, 0x7F), answer

    def test_nothing_in_time_is_none(self, can1):
        with can1.isotp(0x6F0, 0x6F8) as tp:  # nothing answers there
            t = time.monotonic()
            assert tp.recv(150) is None
            assert 0.14 <= time.monotonic() - t < 1
            assert tp.recv(0) is None

    def test_a_29_bit_pair(self, can1):
        with can1.isotp(0x7E0, 0x18DAF110) as tp:
            assert tp.ext, "an id past 0x7FF makes the pair 29-bit"

    def test_what_it_cannot_carry_is_refused(self, sim_demo, can1):
        with can1.isotp(0x7E0, 0x7E8) as tp:
            for bad in (b"", bytes(4096)):
                with pytest.raises(blobly.Refused):
                    tp.send(bad)
            with pytest.raises(TypeError):
                tp.send("text")
            for wait, kind in ((-1, ValueError), (float("inf"), TypeError), (True, TypeError)):
                with pytest.raises(kind):
                    tp.recv(wait)
        with pytest.raises(blobly.Refused, match="carries no ISO-TP"):
            sim_demo.channels.DoIP1.isotp(0x7E0, 0x7E8)
        with pytest.raises(blobly.Refused, match="not a CAN identifier"):
            can1.isotp(0x2000_0000, 0x7E8)
        with pytest.raises(TypeError):
            can1.isotp(0x7E0, None)

    def test_a_closed_channel_refuses(self, can1):
        tp = can1.isotp(0x7E0, 0x7E8)
        tp.close()
        tp.close()
        with pytest.raises(blobly.BloblyError) as e:
            tp.send(b"\x3e\x00")
        assert e.value.code == _lib.BB_ERR_HANDLE
        assert "closed" in repr(tp)

    def test_close_from_another_thread_ends_a_recv(self, can1):
        tp = can1.isotp(0x6F0, 0x6F8)
        threading.Timer(0.1, tp.close).start()
        t = time.monotonic()
        with pytest.raises(blobly.BloblyError) as e:
            tp.recv(5000)
        assert time.monotonic() - t < 1, "the close waited out the receive"
        assert e.value.code == _lib.BB_ERR_HANDLE

    def test_threads_may_share_one(self, can1):
        with can1.isotp(0x7E0, 0x7E8) as tp:
            got = []

            def ask():
                tp.send(b"\x22\xf1\x90")
                got.append(tp.recv())
            t = threading.Thread(target=ask)
            t.start()
            t.join(5)
            assert got == [VIN_ANSWER]


class TestLifecycle:
    def test_a_stop_and_start_reopen_the_channel(self):
        net = blobly.Project(SIM_DEMO).start()
        try:
            tp = net.channels.CAN1.isotp(0x7E0, 0x7E8)
            net.stop()
            with pytest.raises(blobly.BloblyError) as e:
                tp.send(b"\x22\xf1\x90")
            assert e.value.code == _lib.BB_ERR_STATE
            net.start()
            tp.send(b"\x22\xf1\x90")
            assert tp.recv() == VIN_ANSWER
            tp.close()
        finally:
            net.stop()
        with pytest.raises(blobly.BloblyError) as e:
            net.channels.CAN1.isotp(0x7E0, 0x7E8)
        assert e.value.code == _lib.BB_ERR_STATE

    def test_a_collected_channel_is_let_go_at_the_next_call(self):
        import gc
        from blobly import uds
        with blobly.Project(SIM_DEMO) as net:
            net.channels.CAN1.isotp(0x7E0, 0x7E8)  # never closed: collected
            gc.collect()
            assert [closer for closer, _ in uds._orphans] == ["bb_isotp_close"]
            with net.channels.CAN1.isotp(0x7E0, 0x7E8) as tp:
                assert uds._orphans == [], "an open left it"
                tp.send(b"\x22\xf1\x90")
                assert tp.recv() == VIN_ANSWER


class Peer:
    """The other end of the test's id pair (0x700 out, 0x708 back) on raw frames: `on_first`
    answers each First Frame it hears with that Flow Control's bytes, or nothing when None."""

    def __init__(self, ch, on_first=None):
        self.ch, self.on_first = ch, on_first
        ch.look()  # its handle open before the channel's first send: opened later, it misses it
        self.done = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        try:
            while not self.done.is_set():
                f = self.ch.recv(100)
                if f is not None and f.id == 0x700 and f.data[0] & 0xF0 == 0x10 and self.on_first:
                    self.ch.send(0x708, self.on_first)
        except blobly.BloblyError:
            pass  # the test ended and its project stopped under the wait

    def close(self):
        self.done.set()
        self.thread.join(2)


class TestPeer:
    """What sim-demo's ECUs never do, from the test's own peer."""

    @pytest.fixture
    def net(self, tmp_path):
        net = blobly.Project(write(tmp_path, "bare.blobnet", BARE)).start()
        yield net
        net.stop()

    @pytest.fixture
    def ch(self, net):
        return net.channels.B

    @pytest.fixture
    def tp(self, ch):
        with ch.isotp(0x700, 0x708) as tp:
            yield tp

    def test_no_flow_control_is_a_timeout(self, tp):
        t = time.monotonic()
        with pytest.raises(blobly.Timeout, match="no Flow Control"):
            tp.send(bytes(20))
        assert 0.9 <= time.monotonic() - t < 3, "N_Bs is 1000 ms"

    def test_an_overflow_is_the_carriers(self, ch, tp):
        peer = Peer(ch, on_first=b"\x32\x00\x00\x00\x00\x00\x00\x00")
        try:
            with pytest.raises(blobly.CarrierFailed, match="overflow"):
                tp.send(bytes(20))
        finally:
            peer.close()

    def test_a_transfer_that_stops_is_kept_then_given_up(self, ch, tp):
        ch.send(0x708, b"\x10\x0e\x01\x02\x03\x04\x05\x06")  # a First Frame of 14 bytes, and no more
        assert tp.recv(100) is None, "a transfer begun is not a message"
        t = time.monotonic()
        with pytest.raises(blobly.CarrierFailed, match="N_Cr"):
            tp.recv(3000)
        assert time.monotonic() - t < 2, "N_Cr is 1000 ms"
        ch.send(0x708, b"\x10\x0e\x01\x02\x03\x04\x05\x06")
        assert tp.recv(100) is None
        ch.send(0x708, b"\x21\x07\x08\x09\x0a\x0b\x0c\x0d")
        ch.send(0x708, b"\x22\x0e\x00\x00\x00\x00\x00\x00")
        assert tp.recv(1000) == bytes(range(1, 15)), "the next receive went on with the transfer kept"

    def test_a_listen_only_row_refuses_the_send(self, tmp_path, net, tp):
        silent = write(tmp_path, "silent.blobnet",
                       BARE.replace("PY_ISOTP_PEER", "PY_ISOTP_SILENT") + "    listen_only: true\n")
        net.stop()
        with blobly.Project(silent) as other, other.channels.B.isotp(0x700, 0x708) as quiet:
            with pytest.raises(blobly.Refused, match="listen-only"):
                quiet.send(b"\x3e\x00")
        net.start()
