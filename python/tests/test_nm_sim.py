"""Simulated nodes announcing NM, from Python: projects/nm-demo/nm-sim simulates sysnode and domain,
which announce on the ids the system.toml beside it gives them at the row's 100 ms cycle, until
Channel.nm().release() silences them."""
import os

import pytest

import blobly
from conftest import REPO

PROJECT = os.path.join(REPO, "projects", "nm-demo", "nm-sim.blobnet")

pytestmark = pytest.mark.usefixtures("engine")


@pytest.fixture(scope="module")
def net():
    with blobly.Project(PROJECT) as p:
        yield p


def test_the_simulated_nodes_announce_as_the_system_model_declares_them(net):
    nm = net.channels.body.nm()
    r = nm.expect_state("awake", 2000, kept_awake_by=["sysnode", "domain"])
    assert r.missing == ["zone_a"]
    sysnode = r.node("sysnode")
    assert (sysnode.nid, sysnode.can_id, sysnode.bits.raw) == (0x11, 0x511, 0)
    r = nm.reading(600)
    assert r.node("domain").cadence_ms == pytest.approx(100, abs=25)


def test_released_the_cluster_sleeps_and_requested_it_wakes(net):
    nm = net.channels.body.nm()
    nm.expect_state("awake", 2000)
    assert nm.release() == 2
    assert nm.expect_asleep(2000).kept_awake_by == []
    assert nm.request() == 2
    nm.expect_state("awake", 2000, kept_awake_by=["sysnode", "domain"])


def test_a_stop_refuses_and_a_start_requests_the_network_again(net):
    nm = net.channels.body.nm()
    assert nm.release() == 2
    net.stop()
    with pytest.raises(blobly.BloblyError):
        nm.release()
    net.start()
    net.channels.body.nm().expect_state("awake", 2000, kept_awake_by=["sysnode", "domain"])
