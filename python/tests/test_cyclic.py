"""Background cyclic senders (Channel.send_cyclic, Message.send_cyclic) and the UDS keep-alive
(UdsClient.keep_alive). sim-demo answers a Request (0x101) on CAN1 with a Response (0x102) whose
first byte is ReqCode + 1; described-ecu-demo's zone_a ends a non-default session after its S3,
which these tests shorten to 600 ms in a copy."""
import os
import shutil
import time
import warnings

import pytest

import blobly
from blobly import CyclicStatus, KeepAliveWarning, NegativeResponse, Refused
from conftest import REPO, SIM_DEMO

pytestmark = pytest.mark.usefixtures("engine")


def frames(can, ident, ms):
    """The frames of `ident` heard on `can` within ms."""
    out = []
    end = blobly.now_ms() + ms
    while (left := end - blobly.now_ms()) > 0:
        f = can.recv(min(left, 20))
        if f is not None and f.id == ident and not f.ext:
            out.append(f)
    return out


def drain(can):
    while can.recv(0) is not None:
        pass


@pytest.fixture
def can1(sim_demo):
    can = sim_demo.channels.CAN1
    drain(can)
    return can


class TestSenders:
    def test_a_raw_sender_is_heard_at_its_period_by_the_channel_handle(self, can1):
        with can1.send_cyclic(0x321, b"\x01\x02", period_ms=20) as s:
            got = frames(can1, 0x321, 300)
            # the first at once, then one per 20 ms, never a burst
            assert 5 <= len(got) <= 17, len(got)
            assert got[0].data == b"\x01\x02"
            s.update(b"\x09")
            time.sleep(0.06)
            drain(can1)  # what went out before the update
            later = frames(can1, 0x321, 100)
            assert later and all(f.data == b"\x09" for f in later)
            s.period_ms = 100
            assert s.period_ms == 100
            st = s.status()
            assert st.running and st.failed == 0 and st.error == ""
        st = s.status()  # the block's end stopped it, and what it did is kept
        assert isinstance(st, CyclicStatus) and not st.running and st.sent >= 8
        drain(can1)
        assert frames(can1, 0x321, 100) == []
        assert s.stop()  # a stopped sender stops again quietly

    def test_a_message_sender_runs_while_the_script_waits_and_takes_an_update(self, can1):
        req = can1.messages.Request
        s = req.send_cyclic(50, ReqCode=5)
        try:
            answers = frames(can1, 0x102, 400)  # this thread waits; the requests go on
            assert len(answers) >= 5 and answers[-1].data[0] == 6
            s.update(ReqCode=9)
            time.sleep(0.12)
            drain(can1)
            assert frames(can1, 0x102, 200)[-1].data[0] == 10
        finally:
            assert s.stop()

    def test_what_a_sender_cannot_send_is_refused(self, can1, sim_demo):
        with pytest.raises(ValueError, match="a period of 0 ms"):
            can1.send_cyclic(0x10, b"", period_ms=0)
        with pytest.raises(Refused, match='unknown signal "Nope"'):
            can1.messages.Request.send_cyclic(10, Nope=1)
        with pytest.raises(ValueError, match="more than a CAN-FD frame"):
            can1.send_cyclic(0x10, bytes(65))
        with pytest.raises(Refused, match="not a CAN|carries no CAN"):
            sim_demo.channels.DoIP1.send_cyclic(0x10, b"")
        s = can1.send_cyclic(0x10, b"", period_ms=50)
        with pytest.raises(TypeError, match="raw sender"):
            s.update(ReqCode=1)
        s.stop()
        with pytest.raises(Refused, match="stopped"):
            s.update(b"\x01")


    def test_a_keep_alive_never_sends_inside_a_functional_request(self, can1):
        with can1.uds(keep_alive_ms=250) as d:
            d.session(0x03)
            for _ in range(6):  # a keep-alive due between each, and none inside one
                (reply,) = can1.uds_functional(0x7DF, [d], b"\x22\xf1\x90")
                assert reply.outcome == "positive" and reply.answer.startswith(b"\x62\xf1\x90"), reply
                time.sleep(0.3)
            assert d.keep_alive_status.sent >= 3

    def test_a_bad_keep_alive_period_is_refused(self, can1):
        with pytest.raises(ValueError, match="250 .. 60000"):
            can1.uds(keep_alive_ms=100)


class TestProjectStop:
    def test_the_project_stop_ends_its_senders(self):
        net = blobly.Project(SIM_DEMO).start()
        can = net.channels.CAN1
        s = can.send_cyclic(0x333, b"", period_ms=10)
        assert frames(can, 0x333, 60)
        t0 = time.monotonic()
        assert net.stop()  # within its bound: the sender's loop is the run's
        assert time.monotonic() - t0 < 1.5
        st = s.status()
        assert not st.running and st.sent > 0
        net.start()
        try:
            drain(net.channels.CAN1)
            assert frames(net.channels.CAN1, 0x333, 80) == []
            assert s.stop()  # of the stopped run: nothing to do
        finally:
            net.stop()

    def test_a_sender_needs_a_started_project(self):
        net = blobly.Project(SIM_DEMO)
        net.load()
        with pytest.raises(blobly.BloblyError, match="not started"):
            net.channels.CAN1.send_cyclic(0x10, b"")


@pytest.fixture
def quick_s3(tmp_path):
    """described-ecu-demo copied with zone_a's S3 at 600 ms; `refuse_3e` leaves TesterPresent out
    of its services."""
    def make(refuse_3e=False):
        d = tmp_path / ("refusing" if refuse_3e else "plain")
        shutil.copytree(os.path.join(REPO, "projects", "described-ecu-demo"), d)
        ecu = d / "nodes" / "zone_a" / "ecu.toml"
        text = ecu.read_text(encoding="utf-8").replace("s3_ms             = 5000", "s3_ms             = 600")
        if refuse_3e:
            text = text.replace("\n[boot]\n", '\n[uds.services]\n"0x10" = {}\n"0x22" = {}\n'
                                '"0x27" = { sessions = ["extended"] }\n\n[boot]\n')
        ecu.write_text(text, encoding="utf-8")
        return str(d / "described-ecu-demo.blobnet")
    return make


class TestKeepAlive:
    def test_without_it_the_session_lapses_at_s3(self, quick_s3):
        with blobly.Project(quick_s3()) as net, net.channels.edge.uds(0x7C0, 0x7C8) as d:
            d.session(0x03)
            time.sleep(1.0)
            with pytest.raises(NegativeResponse) as e:
                d.security_access(1)  # served only outside the default session
            assert e.value.nrc == 0x7F

    def test_it_holds_the_extended_session_through_a_pause_past_s3(self, quick_s3):
        with blobly.Project(quick_s3()) as net, net.channels.edge.uds(0x7C0, 0x7C8, keep_alive_ms=250) as d:
            d.session(0x03)
            last = d.last
            time.sleep(1.5)
            st = d.keep_alive_status
            assert st.running and st.period_ms == 250 and st.sent >= 2 and st.failures == 0, st
            assert d.last == last  # none of its TesterPresents is the client's last exchange
            d.security_access(1)
            d.keep_alive(None)
            assert not d.keep_alive_status.running
            d.session(0x01)

    def test_nothing_is_sent_in_the_default_session(self, quick_s3):
        with blobly.Project(quick_s3()) as net, net.channels.edge.uds(0x7C0, 0x7C8) as d:
            d.keep_alive(250)
            d.session(0x01)
            time.sleep(0.6)
            assert d.keep_alive_status.sent == 0

    def test_a_refusal_is_said_at_the_next_call(self, quick_s3):
        with blobly.Project(quick_s3(refuse_3e=True)) as net, net.channels.edge.uds(0x7C0, 0x7C8) as d:
            d.keep_alive(250)
            d.session(0x03)
            time.sleep(0.6)
            assert d.keep_alive_status.failures == 1
            with pytest.warns(KeepAliveWarning, match="refused"):
                d.read_did(0xF190)
            with warnings.catch_warnings():
                warnings.simplefilter("error")
                d.read_did(0xF190)  # said once
            time.sleep(0.4)  # refused again once a session is answered: and then stopped unsaid
            d.session(0x03)
            time.sleep(0.5)
            d.keep_alive(None)
            with pytest.warns(KeepAliveWarning, match="refused"):
                d.read_did(0xF190)  # a stopped keep-alive's failure is said all the same
