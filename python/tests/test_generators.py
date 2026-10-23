"""Generator control from Python, seen on the bus: projects/sim-demo.blobnet writes four generators
on CAN1 — Heartbeat pulse (manual, message Heartbeat 0x700), Ping ECU (Request) (on key, Request
0x101) and Cyclic wake (0x123) (a raw frame every 500 ms)."""
import pytest

import blobly
from blobly import GeneratorRefused
from conftest import SIM_DEMO, write

pytestmark = pytest.mark.usefixtures("engine")

HEARTBEAT, REQUEST, WAKE = 0x700, 0x101, 0x123


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


class TestSimDemo:
    def test_the_run_lists_the_project_generators(self, sim_demo):
        gens = sim_demo.generators
        assert [g.name for g in gens] == ["Ping ECU (Request)", "Rev to 6000 rpm", "Heartbeat pulse",
                                          "Cyclic wake (0x123)"]
        hb = gens["Heartbeat pulse"]
        assert (hb.channel, hb.message, hb.trigger, hb.id, hb.running) == ("CAN1", "Heartbeat", "manual",
                                                                           HEARTBEAT, False)
        wake = gens["CAN1/Cyclic wake (0x123)"]
        assert wake.running and wake.cycle_ms == 500 and wake.message == "" and wake.target == "inproc:CAN1"
        assert gens[3] is wake and len(gens) == 4
        with pytest.raises(KeyError, match="no generator"):
            gens["nope"]

    def test_fire_sends_once_with_the_value_set(self, sim_demo, can1):
        hb = sim_demo.generators["Heartbeat pulse"]
        sent = hb.sent
        hb.set("Counter", 42)
        hb.fire()
        # the simulated SUT sends Heartbeat too: ours is the one at 42
        assert sum(f.data[0] == 42 for f in frames(can1, HEARTBEAT, 300)) == 1
        assert hb.sent == sent + 1

    def test_a_source_counts_the_frames_sent(self, sim_demo, can1):
        ping = sim_demo.generators["Ping ECU (Request)"]
        ping.source(can1.messages.Request.signals.ReqCode, "counter", start=100, modulo=256)
        ping.fire()
        ping.fire()
        a, b = frames(can1, REQUEST, 300)
        assert b.data[0] == a.data[0] + 1

    def test_stop_start_and_cycle(self, sim_demo, can1):
        wake = sim_demo.generators["Cyclic wake (0x123)"]
        wake.stop()
        assert not wake.running
        frames(can1, WAKE, 60)
        assert frames(can1, WAKE, 600) == []
        wake.start(50)
        n = len(frames(can1, WAKE, 500))
        assert 4 <= n <= 12, f"{n} frames in 500 ms at 50 ms"
        wake.cycle_ms = 500
        assert wake.cycle_ms == 500 and wake.running

    def test_refusals_are_typed(self, sim_demo):
        gens = sim_demo.generators
        hb, wake = gens["Heartbeat pulse"], gens["Cyclic wake (0x123)"]
        for call, what in [(lambda: wake.__setattr__("cycle_ms", 0), "a cycle is 1"),
                           (lambda: hb.set("NoSignal", 1), "has no signal"),
                           (lambda: wake.set("Counter", 1), "raw frame"),
                           (lambda: hb.start(), "no cycle"),
                           (lambda: hb.source("Counter", "stepmod", period=1), "non-zero count"),
                           (lambda: hb.source("Counter", "wobble"), "unknown type")]:
            with pytest.raises(GeneratorRefused, match=what):
                call()
        with pytest.raises(TypeError, match="no source parameter"):
            hb.source("Counter", "sine", amp=1)
        with pytest.raises(TypeError):
            hb.set("Counter", "1")


def test_a_generator_of_a_stopped_run_refuses(engine):
    net = blobly.Project(SIM_DEMO).start()
    gens = net.generators
    hb = gens["Heartbeat pulse"]
    net.stop()
    with pytest.raises(blobly.BloblyError) as e:
        hb.fire()
    assert e.value.code == -3
    with pytest.raises(blobly.BloblyError):
        net.generators
    # a new run of the project: the same object goes on working
    net.start()
    try:
        assert net.generators["Heartbeat pulse"] is hb
        hb.fire()
        with pytest.raises(blobly.BloblyError, match="earlier run") as e:
            gens["Heartbeat pulse"]  # a container of the earlier run: its positions are not this one's
        assert e.value.code == -3
    finally:
        net.stop()


def test_a_generator_name_a_c_string_cannot_carry_is_refused_at_load(engine, tmp_path):
    path = write(str(tmp_path), "nul.blobnet", """project:
  name: nul
  version: 8
channels:
  - name: N
    type: can
    interface: inproc:PY_GEN_NUL
    senders:
      - name: "Ping\\u0000Tail"
        id: "0x10"
        data: 01
""")
    with pytest.raises(blobly.Refused, match="NUL"):
        blobly.Project(path).load()
