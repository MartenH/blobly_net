"""Bus metrics from Python (Channel.load, Channel.diagnostics): two rows on one in-process wire at
250 kbit/s, one sending what the other reads. A standard 8-byte frame is 135 bit-times with
worst-case stuffing (transport.frame_bits)."""
import time

import pytest

import blobly
from blobly import _lib
from conftest import write

pytestmark = pytest.mark.usefixtures("engine")

WIRE = """project:
  name: metrics
  version: 8
channels:
  - name: A
    type: can
    interface: inproc:PY_METRICS
    bitrate: 250000
  - name: B
    type: can
    interface: inproc:PY_METRICS
"""

FRAME = bytes(8)


@pytest.fixture(scope="class")
def net(tmp_path_factory):
    path = write(tmp_path_factory.mktemp("metrics"), "metrics.blobnet", WIRE)
    net = blobly.Project(path).start()
    yield net
    net.stop()


class TestMetrics:
    def test_a_known_frame_count_is_its_load(self, net):
        a, b = net.channels.A, net.channels.B
        before = b.load()  # opened now: B counts from here
        assert before.percent is None, "no whole second yet"
        for _ in range(100):
            a.send(0x555, FRAME)
        got = 0
        while got < 100 and b.recv(1000) is not None:
            got += 1
        assert got == 100
        sent, read = a.load(), b.load()
        assert (sent.frames, sent.bits) == (100, 100 * 135)
        assert (read.frames - before.frames, read.bits - before.bits) == (100, 100 * 135)
        assert sent.nominal == read.nominal == 250000, "the wire's first row prices it"

    def test_a_whole_second_has_a_percent(self, net):
        b = net.channels.B
        time.sleep(1.05)
        l = b.load()
        assert l.percent is not None and 0 < l.average <= 100, l

    def test_a_reader_that_falls_behind_counts_drops(self, net):
        a, b = net.channels.A, net.channels.B
        assert b.diagnostics() == blobly.BusDiagnostics(0, 0, 0)
        for _ in range(8192 + 50):  # one more than the in-process queue holds, and then some
            a.send(0x556, FRAME)
        d = b.diagnostics()
        assert d.dropped >= 50 and d.bus_errors == 0 and d.decode_errors == 0
        assert a.diagnostics().dropped == 0, "the sender lost nothing"

    def test_a_stopped_project_has_no_metrics(self, net):
        net.stop()
        try:
            with pytest.raises(blobly.BloblyError) as e:
                net.channels.A.load()
            assert e.value.code == _lib.BB_ERR_STATE
        finally:
            net.start()
