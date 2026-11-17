"""The system model from Python against projects/described-ecu-demo: zone_a of system_full, whose
simulated server answers as its ecu.toml describes it — the coverage tests/diag_nodes.lua has:
nodes by name, their DIDs listed, read and written through the node's layout, a gated write
refused with what it needs, DTCs named by the description's faults. Plus what only a host sees: the
typed errors, a node kept across a stop and a start, and a project the model reaches nowhere."""
import os
import shutil
import threading

import pytest

import blobly
from blobly import _lib
from conftest import REPO, SIM_DEMO

DEMO_DIR = os.path.join(REPO, "projects", "described-ecu-demo")
DESCRIBED = os.path.join(DEMO_DIR, "described-ecu-demo.blobnet")

pytestmark = pytest.mark.usefixtures("engine")


@pytest.fixture(scope="class")
def net(engine):
    with blobly.Project(DESCRIBED) as n:
        yield n


@pytest.fixture
def zone_a(net):
    return net.nodes.zone_a


@pytest.fixture
def diag(zone_a):
    with zone_a.uds() as client:
        client.session(0x01)
        yield client


class TestDescribedNode:
    def test_the_model_and_its_node(self, net, zone_a):
        assert net.system == os.path.join(DEMO_DIR, "system.toml")
        assert net.nodes.keys() == ["zone_a"]
        assert (zone_a.described, zone_a.server, zone_a.reference_key, zone_a.problem) == (True, True, True, "")
        [t] = zone_a.targets
        assert (t.channel.name, t.tx, t.rx, t.ext) == ("edge", 0x7C0, 0x7C8, False)
        assert [f.name for f in zone_a.faults][:2] == ["SpeedImplausible", "SafetyCmdTimeout"]
        assert zone_a.faults.SpeedImplausible.dtc == 0xC40100
        assert zone_a.faults.SpeedImplausible.dtc_name == "U0401-00"

    def test_its_dids_with_their_layout_and_gates(self, zone_a):
        steer = zone_a.dids.SteerLimit
        assert (steer.id, steer.kind, steer.size, steer.by_label) == (0x0110, "param", 2, False)
        assert steer.parts == (blobly.DidPart("deg", "int", "u16 0..360"),)
        assert steer.read_gate is None
        assert steer.write_gate == blobly.Gate(("extended",), 1)
        assert str(steer.write_gate) == "extended, level 1"
        assert zone_a.dids.VIN.write_gate is None, "no write gate: not writable"
        assert zone_a.dids["parameter status"].by_label
        assert zone_a.did(0x0110) is steer
        assert zone_a.did(0x1234) is None, "an identifier it does not list"
        iso = zone_a.dids["ECU serial number"]
        assert (iso.id, iso.kind, iso.size) == (0xF18C, "unknown", None)
        with pytest.raises(KeyError):
            zone_a.did("SteerLimt")

    def test_a_did_is_read_by_name_through_its_layout(self, diag):
        assert diag.read("SteerLimit") == 360
        assert diag.read(0x0110) == 360
        assert diag.read("VIN") == "BLOBLY-ZONE_A-H723"
        assert diag.read("parameter status") == {"SteerLimit": 0}
        assert diag.read(0x0102) == b"\x00"
        assert diag.last.request == b"\x22\x01\x02"

    def test_a_gated_write_says_what_it_needs(self, diag):
        with pytest.raises(blobly.WriteGated) as e:
            diag.write("SteerLimit", 300)
        assert (e.value.session, e.value.level, e.value.code) == (0x03, 1, -13)
        assert "switch to the extended session (0x10 03), then unlock level 1 (0x27 01/02)" in str(e.value)
        assert isinstance(e.value, blobly.Refused), "nothing was sent"
        diag.session(0x03)
        with pytest.raises(blobly.WriteGated) as e:
            diag.write("SteerLimit", 300)
        assert (e.value.session, e.value.level) == (0, 1)
        diag.security_access(1)
        diag.write("SteerLimit", 300)
        assert diag.read("SteerLimit") == 300
        assert diag.read("parameter status") == {"SteerLimit": 1}
        diag.write("SteerLimit", {"deg": 200})
        diag.write("SteerLimit", deg=360)
        assert diag.read("SteerLimit") == 360
        diag.session(0x01)  # relocks
        with pytest.raises(blobly.WriteGated):
            diag.write("SteerLimit", 300)

    def test_a_value_the_layout_does_not_hold_is_refused_unsent(self, diag):
        diag.session(0x03)
        diag.security_access(1)
        before = diag.last
        with pytest.raises(blobly.Refused, match="400 is outside 0..360") as e:
            diag.write("SteerLimit", 400)
        assert not isinstance(e.value, blobly.WriteGated)
        with pytest.raises(TypeError, match="an integer"):
            diag.write("SteerLimit", "300")
        with pytest.raises(TypeError, match="an integer"):
            diag.write("SteerLimit", True)
        with pytest.raises(TypeError, match="its parts are deg"):
            diag.write("SteerLimit", angle=1)
        with pytest.raises(blobly.Refused, match="not writable"):
            diag.write("VIN", "X")
        with pytest.raises(blobly.Refused, match="does not list it"):
            diag.write(0x1234, b"\x00")
        assert diag.last == before, "none of them was sent"

    def test_dtcs_are_named_by_the_faults(self, diag):
        dtcs = diag.dtcs()
        assert [(d.name, d.fault) for d in dtcs][:2] == [("U0401-00", "SpeedImplausible"),
                                                          ("U0164-00", "SafetyCmdTimeout")]
        assert diag.extended("U0401-00").dtc.fault == "SpeedImplausible"
        assert diag.supported_dtcs()[0].fault == "SpeedImplausible"

    def test_a_node_outlives_a_stop_and_a_start(self, net, zone_a, diag):
        assert diag.read("SteerLimit") in (200, 300, 360)
        net.stop()
        with pytest.raises(blobly.BloblyError) as e:
            net.nodes
        assert e.value.code == _lib.BB_ERR_STATE
        net.start()
        assert net.nodes.zone_a is zone_a, "kept: the same node at its position"
        assert diag.read("VIN") == "BLOBLY-ZONE_A-H723", "its connection reopened on the same ids"

    def test_a_plain_client_names_no_fault(self, net):
        with net.channels.edge.uds(0x7C0, 0x7C8) as plain:
            assert all(d.fault is None for d in plain.dtcs())


class TestReachedNowhere:
    def test_a_node_no_row_reaches_is_refused_saying_how_it_is_reached(self, tmp_path):
        shutil.copytree(DEMO_DIR, tmp_path / "demo")
        path = tmp_path / "demo" / "described-ecu-demo.blobnet"
        path.write_text(path.read_text(encoding="utf-8").replace("name: edge", "name: other"), encoding="utf-8")
        with blobly.Project(path) as net:
            zone_a = net.nodes.zone_a
            assert zone_a.targets == []
            with pytest.raises(blobly.Refused, match="reached at 0x7C0/0x7C8 on a CAN row named edge"):
                zone_a.uds()

    def test_a_kept_client_follows_its_node_across_a_restart(self, tmp_path):
        shutil.copytree(DEMO_DIR, tmp_path / "demo")
        d = tmp_path / "demo"
        ecu, system = d / "nodes" / "zone_a" / "ecu.toml", d / "system.toml"
        with blobly.Project(d / "described-ecu-demo.blobnet") as net:
            diag = net.nodes.zone_a.uds()
            assert diag.dtcs()[0].fault == "SpeedImplausible"
            net.stop()
            # the description's names are the next run's
            ecu.write_text(ecu.read_text(encoding="utf-8").replace("SpeedImplausible", "SpeedWrong"), encoding="utf-8")
            net.start()
            assert diag.dtcs()[0].fault == "SpeedWrong"
            net.stop()
            # reached elsewhere: the kept client refuses rather than address the old ids
            system.write_text(system.read_text(encoding="utf-8").replace("0x7C0", "0x7C1").replace("0x7C8", "0x7C9"),
                              encoding="utf-8")
            net.start()
            with pytest.raises(blobly.BloblyError, match="reached elsewhere") as e:
                diag.read("VIN")
            assert e.value.code == _lib.BB_ERR_STATE
            diag.close()

    def test_no_system_toml_means_no_nodes(self):
        with blobly.Project(SIM_DEMO) as net:
            assert net.system is None
            assert len(net.nodes) == 0


# a node declared 29-bit on ids at or below 0x7FF, on a bare row of its bus: WideNodeEcu answers it
WIDE_SYSTEM = """[bus.body]
interface = "can0"

[[node]]
name  = "n29"
ecu   = "nodes/n29/ecu.toml"
buses = ["body"]
diag  = { req = 0x700, rsp = 0x708, ext = true }
"""
WIDE_PROJECT = """project:
  name: wide
  version: 8
channels:
  - name: body
    type: can
    interface: inproc:PY_NODE_WIDE
"""


class TestDeclaredWidth:
    def test_a_node_declared_29_bit_on_small_ids_is_opened_29_bit(self, tmp_path):
        os.makedirs(tmp_path / "nodes" / "n29")
        (tmp_path / "nodes" / "n29" / "ecu.toml").write_text(
            "[uds]\n\n[isotp]\nrx_id = 0x700\ntx_id = 0x708\next = true\n", encoding="utf-8")
        (tmp_path / "system.toml").write_text(WIDE_SYSTEM, encoding="utf-8")
        (tmp_path / "wide.blobnet").write_text(WIDE_PROJECT, encoding="utf-8")
        with blobly.Project(tmp_path / "wide.blobnet") as net:
            n29 = net.nodes.n29
            [t] = n29.targets
            assert (t.channel.name, t.tx, t.rx, t.ext) == ("body", 0x700, 0x708, True)
            ch = net.channels.body
            ch.look()  # the fake's handle open before the client's first request
            seen, stop = [], threading.Event()

            def ecu():  # answers TesterPresent in 29-bit only
                try:
                    while not stop.is_set():
                        f = ch.recv(100)
                        if f is not None and f.id == 0x700:
                            seen.append(f.ext)
                            if f.ext and f.data[:3] == b"\x02\x3e\x00":
                                ch.send(0x708, b"\x02\x7e\x00", ext=True)
                except blobly.BloblyError:
                    pass
            th = threading.Thread(target=ecu, daemon=True)
            th.start()
            try:
                with n29.uds() as diag:
                    assert (diag.tx, diag.rx, diag.ext) == (0x700, 0x708, True)
                    diag.tester_present()
            finally:
                stop.set()
                th.join(2)
            assert seen == [True]
