"""The NM waits' rule, as a model: every reading the listener makes while a wait reads — after each
frame and after each read that found nothing — is offered to the wait's predicate, whatever the
timeout and however close the reads. NmListener._until driven over synthetic reads, no engine:
each read changes the reading in some way a predicate can see (a keeper, a node's bits, the
state), often with nothing else about it moving."""
import random
from types import SimpleNamespace

import pytest

from blobly import nm as nmmod
from blobly._lib import Timeout


def reading(rng, k):
    names = ["A", "B", "C"]
    keepers = [n for n in names if rng.random() < 0.5]
    state = "awake" if keepers else rng.choice(["releasing", "asleep"])
    return nmmod.NmReading(
        state, keepers, rng.choice([None, "A", "B"]), False, None, [], [], [], [], True, 1.0,
        rng.randrange(3), 0, "", 0, rng.choice([1, 2, 5]), False, "script", "the script", f"read {k}", 1.0)


class Model:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.reads = self.rng.randrange(1, 60)
        self.current = reading(self.rng, -1)
        self.produced = []
        channel = SimpleNamespace(name="A", _handle=lambda: 1, _frames_until=self.frames_until)
        self.lis = nmmod.NmListener(channel, None)
        self.lis._handle = lambda: 1
        self.lis._view = lambda h: SimpleNamespace(timeout_ms=self.current.timeout_ms)
        self.lis._reading = lambda h, v=None: self.current

    def frames_until(self, deadline, run, idle=False, slice_ms=100, look_first=False):
        assert idle and look_first, "a wait asks after reads that found nothing, and looks first"
        for k in range(self.reads):
            self.current = reading(self.rng, k)  # what this read made of the reading
            self.produced.append(self.current)
            yield None if self.rng.random() < 0.3 else object()


@pytest.mark.parametrize("seed", range(300))
def test_every_reading_a_wait_reads_is_offered(seed):
    m = Model(seed)
    offered = []
    with pytest.raises(Timeout):
        m.lis.expect(lambda r: offered.append(r) or False, 1000)
    assert offered == m.produced


@pytest.mark.parametrize("seed", range(100))
def test_expect_state_takes_the_first_reading_that_matches(seed):
    m = Model(seed)
    try:
        got = m.lis.expect_state("awake", 1000, kept_awake_by=["B"])
    except Timeout:
        got = None
    assert got is next((r for r in m.produced if r.state == "awake" and r.kept_awake_by == ["B"]), None)
