"""Replay and recording from Python, on projects/replay-demo.blobnet: REPLAY1 replays
samples/demo.log (0x100 and 0x700 at 10 Hz for 2.9 s) onto inproc:RPLY, and the channel's own
handle hears what the replay sends."""
import collections
import os

import pytest

import blobly
from blobly import Refused
from conftest import REPO, write

pytestmark = pytest.mark.usefixtures("engine")

REPLAY_DEMO = os.path.join(REPO, "projects", "replay-demo.blobnet")
POWERTRAIN, HEARTBEAT, BODY = 0x100, 0x700, 0x200


def drain(ch, quiet_ms=50):
    """What `ch` hears until quiet_ms pass with nothing, counted by id."""
    got = collections.Counter()
    while (f := ch.recv(quiet_ms)) is not None:
        got[f.id] += 1
    return got


@pytest.fixture(scope="class")
def net(engine):
    net = blobly.Project(REPLAY_DEMO).start()
    yield net
    net.stop()


class TestReplay:
    def test_a_replay_plays_the_row_recording_and_finishes(self, net):
        ch = net.channels.REPLAY1
        drain(ch, 0)
        with net.replay(ch, speed=20, loop=False) as r:
            assert r.notes == ["REPLAY1: 60 frames, 0 withheld"]
            assert r.wait_done(5000)
            assert drain(ch) == {POWERTRAIN: 30, HEARTBEAT: 30}
        st = r.stop()
        assert (st.state, st.sent, st.failed, st.passes, st.ended) == ("finished", 60, 0, 1, True)
        assert 2.8 < st.duration_s < 3.0

    def test_controls_are_applied_before_they_return(self, net):
        ch = net.channels.REPLAY1
        with net.replay("REPLAY1", paused=True) as r:
            assert r.status().state == "paused"
            r.seek(2.5)
            assert r.status().position_s == 2.5
            r.set_speed(10)
            r.set_loop(False)
            st = r.status()
            assert (st.speed, st.loop, st.state) == (10, False, "paused")
            drain(ch, 0)
            r.resume()
            assert r.wait_done(2000)
            assert drain(ch) == {POWERTRAIN: 5, HEARTBEAT: 5}  # what is recorded from 2.5 s on
        with pytest.raises(Refused, match="stopped"):
            r.pause()

    def test_the_ecu_under_test_is_subtracted(self, net, tmp_path):
        log = write(tmp_path, "two.log", "(1.000000) can0 100#0102030405060708\n"
                                         "(1.010000) can0 200#0102030405060708\n")
        ch = net.channels.REPLAY1
        drain(ch, 0)
        with net.replay(ch, log, exclude=["SUT"], loop=False) as r:
            assert r.notes == ["REPLAY1: 1 frames, 1 withheld"]
            assert r.wait_done(2000)
            assert drain(ch) == {BODY: 1}

    def test_what_would_play_something_else_is_refused(self, net):
        with pytest.raises(Refused, match="declares Nobody"):
            net.replay("REPLAY1", exclude=["Nobody"])
        with pytest.raises(Refused, match="nothing to play"):
            net.replay("REPLAY1", exclude=["SUT"])
        with pytest.raises(ValueError, match="speed"):
            net.replay("REPLAY1", speed=0)
        with pytest.raises(ValueError, match="node names"):
            net.replay("REPLAY1", exclude=[""])  # an empty name is not the empty list
        with pytest.raises(Refused, match="nothing to play"):
            net.replay("REPLAY1", exclude=iter(["SUT"]))  # an iterator is read once

    def test_a_recording_reads_back_as_what_was_sent(self, net, tmp_path):
        path = tmp_path / "rec.log"
        with net.record(path, "REPLAY1") as rec:
            with net.replay("REPLAY1", speed=50, loop=False) as r:
                assert r.wait_done(3000)
        c = rec.stop()
        assert (c.frames, c.ours, c.theirs, c.missed, c.dropped) == (60, 60, 0, 0, 0)
        lines = path.read_text().splitlines()
        with open(os.path.join(REPO, "samples", "demo.log")) as f:
            src = f.read().splitlines()
        assert [ln.split()[1:] for ln in lines] == [["REPLAY1", s.split()[2], "T"] for s in src]


class TestReplayEndsWithTheRun:
    def test_a_stop_of_the_project_stops_its_replays(self, engine):
        net = blobly.Project(REPLAY_DEMO).start()
        r = net.replay("REPLAY1")
        assert r.status().state == "playing"
        net.stop()
        assert r.status().ended
        assert r.stop().ended
        with pytest.raises(blobly.BloblyError, match="not started"):
            net.replay("REPLAY1")
