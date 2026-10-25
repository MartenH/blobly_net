"""Network management from Python: Channel.nm against projects/nm-demo, whose recording replays at
4x onto an in-process bus and whose system.toml declares sysnode, domain and zone_a on bus body."""
import os

import pytest

import blobly
from conftest import REPO

PROJECT = os.path.join(REPO, "projects", "nm-demo", "nm-demo.blobnet")

pytestmark = pytest.mark.usefixtures("engine")


@pytest.fixture(scope="module")
def net():
    with blobly.Project(PROJECT) as p:
        yield p


def test_the_cluster_wakes_is_kept_awake_releases_and_sleeps(net):
    body = net.channels.body
    nm = body.nm()
    with net.replay(body, speed=4, loop=False):
        r = nm.expect_state("awake", 3000, kept_awake_by=["domain", "sysnode"])
        assert r.kept_awake_by == ["sysnode", "domain"]  # declared order
        assert r.woken_by == "sysnode" and r.woken_active
        assert (r.source, r.origin, r.cluster) == ("system.toml", "system.toml bus body", "NM ids 0x500..0x53F")
        assert r.missing == ["zone_a"]
        sysnode = r.node("sysnode")
        assert (sysnode.nid, sysnode.can_id, sysnode.ext) == (0x11, 0x511, False)
        assert sysnode.bits.repeat_request and sysnode.bits.active_wakeup and sysnode.bits.wants_network
        zone_a = r.node("zone_a")
        assert zone_a.missing and zone_a.bits is None and zone_a.last_heard_ms is None
        r = nm.expect_state("awake", 8000, kept_awake_by=["sysnode"])
        assert r.unknown == ["NID 0x22"]
        assert r.node("domain").bits.ready_to_sleep
        assert r.node("sysnode").cadence_ms == pytest.approx(25, abs=10)  # 100 ms at 4x
        nm.expect_state("releasing", 8000)
        assert nm.expect_asleep(4000).kept_awake_by == []
        r = nm.expect_state("awake", 6000)
        assert r.woken_by == "domain" and r.woken_active
        assert r.node("domain").pn == 0x05  # partial networks 0 and 2
        assert nm.state == "awake" and nm.woken_by == "domain"


def test_a_wait_not_met_says_what_the_reading_was(net):
    nm = net.channels.body.nm()
    with pytest.raises(blobly.Timeout, match="expected NM state awake, kept awake by zone_a"):
        nm.expect_state("awake", 50, kept_awake_by=["zone_a"])
    with pytest.raises(ValueError, match="awake, releasing, asleep"):
        nm.expect_state("dozing", 50)


def test_a_range_the_script_states_reads_without_names(net):
    body = net.channels.body
    nm = body.nm(0x510, 0x512, timeout_ms=300)
    with net.replay(body, speed=4, loop=False):
        r = nm.expect_state("awake", 3000)
    assert (r.source, r.missing) == ("script", [])
    assert [n.name for n in nm.nodes] == ["NID 0x11"]  # 0x513 is outside the range
    with pytest.raises(ValueError, match="above hi"):
        body.nm(0x600, 0x500)
    with pytest.raises(TypeError, match="lo and hi"):
        body.nm(0x500)
    assert body.nm().reading().source == "system.toml"  # the wire's own again
