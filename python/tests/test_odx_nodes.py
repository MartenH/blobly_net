"""A node a project row names by its ODX description, from Python, against projects/odx-demo:
BodyController of dbc/odx_demo.odx-d on CAN1, whose simulated BodyECU answers at its ids — the
coverage tests/odx_nodes.lua has: the node by name, its DIDs listed with the layout and gates the
ODX gives them, read and written by name (scaled values as numbers, text tables as labels), and its
DTCs named by the variant's DTC list."""
import os

import pytest

import blobly
from conftest import REPO

ODX_DEMO = os.path.join(REPO, "projects", "odx-demo.blobnet")

pytestmark = pytest.mark.usefixtures("engine")


@pytest.fixture(scope="class")
def net(engine):
    with blobly.Project(ODX_DEMO) as n:
        yield n


@pytest.fixture
def diag(net):
    with net.nodes.BodyController.uds() as client:
        yield client


class TestOdxNode:
    def test_the_row_names_the_node(self, net):
        assert net.system is None, "no system.toml: the node is the row's"
        assert net.nodes.keys() == ["BodyController"]
        body = net.nodes.BodyController
        [t] = body.targets
        assert (t.channel.name, t.tx, t.rx, t.ext) == ("CAN1", 0x7E0, 0x7E8, False)
        assert [f.name for f in body.faults] == ["LampOpenCircuit", "SupplyLow"]
        assert body.faults.LampOpenCircuit.dtc == 0x912301

    def test_its_dids_carry_the_layout_the_odx_gives(self, net):
        dids = net.nodes.BodyController.dids
        assert (dids.VIN.id, dids.VIN.kind, dids.VIN.size) == (0xF190, "text", 17)
        lamp = dids.LampConfig
        assert (lamp.kind, lamp.size, lamp.by_label) == ("fields", 3, True)
        assert lamp.parts == (blobly.DidPart("Brightness", "int", "u8 0..255"),
                              blobly.DidPart("DelayMs", "int", "u16 0..65535"))
        assert dids.TrimOffset.parts == (blobly.DidPart("TrimOffset", "int", "i16 -32768..32767"),)
        assert dids.Temperature.parts == (blobly.DidPart("Temperature", "number", "number -40..6513.5 °C"),)
        assert dids.LampMode.parts == (blobly.DidPart("LampMode", "label", "one of Off, On, Auto, Service"),)
        assert dids.EcuSerial.write_gate is None, "no 0x2E service: not writable"
        assert dids.EcuSerial.read_gate == blobly.Gate(("default", "extended"), 0)
        assert dids.VIN.write_gate == blobly.Gate(("extended",), 1)
        assert dids.TrimOffset.write_gate == blobly.Gate(("extended",), 0)
        assert dids.LampConfig.write_gate == blobly.Gate((), 0), "no precondition: open"

    def test_a_did_is_read_and_written_by_name(self, diag):
        assert diag.read("VIN") == "WVWZZZ1JZXW000001"
        assert diag.read("LampConfig") == {"Brightness": 200, "DelayMs": 1500}
        assert diag.read("TrimOffset") == -100
        assert diag.read("Temperature") == 260.0
        assert diag.read("SupplyVoltage") == 30.0
        assert diag.read("LampMode") == "Auto"
        diag.write("LampMode", "Off")
        assert diag.read("LampMode") == "Off"
        with pytest.raises(blobly.Refused, match="not one of Off, On, Auto, Service"):
            diag.write("LampMode", "Dim")
        diag.write("LampConfig", Brightness=10, DelayMs=250)
        assert diag.read("LampConfig") == {"Brightness": 10, "DelayMs": 250}
        with pytest.raises(blobly.Refused, match="not writable"):
            diag.write("EcuSerial", b"\x00\x00\x00\x01")

    def test_a_write_is_gated_by_its_odx_preconditions(self, diag):
        diag.session(0x01)
        with pytest.raises(blobly.WriteGated) as gated:
            diag.write("TrimOffset", -7)
        assert (gated.value.session, gated.value.level) == (0x03, 0)
        diag.session(0x03)
        diag.write("TrimOffset", -7)
        assert diag.read("TrimOffset") == -7
        with pytest.raises(blobly.WriteGated) as gated:
            diag.write("VIN", "WVWZZZ1JZXW000002")
        assert (gated.value.session, gated.value.level) == (0, 1)
        diag.security_access(1)
        diag.write("VIN", "WVWZZZ1JZXW000002")
        assert diag.read("VIN") == "WVWZZZ1JZXW000002"

    def test_dtcs_are_named_by_the_variant(self, diag):
        assert [d.fault for d in diag.dtcs()] == ["LampOpenCircuit", "SupplyLow"]
