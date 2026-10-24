"""J1939 from Python: a rejoined message is judged over the row's SOURCE databases, then decoded by
the row's merged catalog. Two files that disagree about one id decode nothing, and say why. One
layout at two priorities in two files decodes. Two rows, each with its own peer on its own wire."""
import pytest

import blobly
from conftest import write
from test_j1939 import BODY, announce, cm, packets

pytestmark = pytest.mark.usefixtures("engine")

HEAD = 'VERSION ""\nNS_ :\nBS_:\nBU_: Body\n'
TAIL = ('BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","reserved","J1939PG";\n'
        'BA_DEF_DEF_ "VFrameFormat" "J1939PG";\n')


def dbc(id, factor, declared=True):
    return (HEAD + f"BO_ {id | 0x80000000} BodyStatus: 20 Body\n"
            f" SG_ Odometer : 8|32@1+ ({factor},0) [0|4294967295] \"km\" Body\n" + (TAIL if declared else ""))


@pytest.fixture(scope="module")
def net(tmp_path_factory):
    d = tmp_path_factory.mktemp("j1939src")
    write(d, "a.dbc", dbc(0x18FF1021, 0.1))
    write(d, "clash.dbc", dbc(0x18FF1021, 1))  # the same id, another layout
    write(d, "prio.dbc", dbc(0x1CFF1021, 0.1))  # the same layout, priority 7
    write(d, "plain.dbc", dbc(0x18FF1021, 0.1, declared=False))  # the id, declaring nothing
    path = write(d, "p.blobnet", """project:
  name: j1939-sources
  version: 2
channels:
  - name: Clash
    type: can
    interface: inproc:J1939SRC1
    databases: [a.dbc, clash.dbc]
  - name: ClashPeer
    type: can
    interface: inproc:J1939SRC1
  - name: Prio
    type: can
    interface: inproc:J1939SRC2
    databases: [a.dbc, prio.dbc]
  - name: PrioPeer
    type: can
    interface: inproc:J1939SRC2
  - name: Order
    type: can
    interface: inproc:J1939SRC3
    databases: [plain.dbc, a.dbc]
  - name: OrderPeer
    type: can
    interface: inproc:J1939SRC3
""")
    with blobly.Project(path) as p:
        yield p


def rejoined(net, row, peer):
    ch, tx = net.channels[row], net.channels[peer]
    ch.look()
    tx.look()
    cm(tx, 0x21, 0xFF, announce(32, BODY, 0xFF10))
    packets(tx, 0x21, 0xFF, BODY)
    return ch.j1939().expect_pgn(0xFF10, 1000)


def test_two_files_disagreeing_about_an_id_decode_nothing(net):
    m = rejoined(net, "Clash", "ClashPeer")
    assert m.message is None and m.signals == {}
    assert "different layouts" in m.note


def test_one_layout_at_two_priorities_in_two_files_decodes(net):
    m = rejoined(net, "Prio", "PrioPeer")
    assert m.message is not None and m.message.name == "BodyStatus"
    assert m.signals["Odometer"] == pytest.approx(12345.6)


def test_a_later_file_declaring_j1939_makes_the_wire_j1939(net):
    # plain.dbc first: the merge keeps its undeclared copy of the id a.dbc declares J1939
    ch, tx = net.channels.Order, net.channels.OrderPeer
    ch.look()
    tx.look()
    assert not any(m.j1939 for m in ch.messages), "the merged catalog declares nothing"
    cm(tx, 0x21, 0xFF, announce(32, BODY, 0xFF10))
    packets(tx, 0x21, 0xFF, BODY)
    assert all(ch.recv(200) is not None for _ in range(4))  # read before anything asked
    assert [m.data for m in ch.j1939().messages(0)] == [BODY]
