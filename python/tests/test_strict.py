"""What a load does not use: Project.notes as data, and strict=True refusing a project whose file
carries a key no section lists or a DBC record the reader does not take (bb_load_flags,
BB_LOAD_STRICT). The rules are V tests (blobly/project/keys_test.v, blobly/candb/dbc_unread_test.v)."""
import pytest

import blobly
from conftest import SIM_DEMO, write

pytestmark = pytest.mark.usefixtures("engine")

DBC = """VERSION ""
BU_: Body Gw
BO_ 256 Door: 8 Body
 SG_ Speed : 0|32@1- (1,0) [0|0] "" Gw
BA_DEF_ SG_ "GenSigSendType" ENUM "Cyclic","OnWrite";
BA_ "GenSigSendType" SG_ 256 Speed 1;
SIG_VALTYPE_ 256 Speed : 1;
"""


def project(version=2, key="bitrate"):
    return f"""project:
  name: strict
  version: {version}
buses:
  - name: CAN1
    interface: inproc:STRICT1
    {key}: 500000
    databases: [u.dbc]
    senders:
      - name: G
        cycle_msec: 10
"""


def test_notes_list_what_the_load_did_not_use(tmp_path):
    write(tmp_path, "u.dbc", DBC)
    net = blobly.Project(write(tmp_path, "p.blobnet", project(key="bitrat"))).load()
    assert net.notes[0].startswith('unknown key `bitrat` in channel "CAN1" (known: ')
    assert net.notes[1].startswith('unknown key `cycle_msec` in channel "CAN1" / generator "G"')
    assert net.notes[2] == 'u.dbc: not read: attribute "GenSigSendType" × 1, SIG_VALTYPE_ × 1'
    assert len(net.notes) == 3


def test_a_clean_project_says_nothing_and_loads_strictly():
    net = blobly.Project(SIM_DEMO, strict=True).load()
    assert net.notes == []


def test_strict_refuses_listing_every_line(tmp_path):
    write(tmp_path, "u.dbc", DBC)
    path = write(tmp_path, "p.blobnet", project(key="bitrat"))
    net = blobly.Project(path, strict=True)
    with pytest.raises(blobly.Refused) as e:
        net.load()
    text = str(e.value)
    assert "a strict load refuses what this build does not read" in text
    for want in ("unknown key `bitrat`", "unknown key `cycle_msec`",
                 'u.dbc: not read: attribute "GenSigSendType" × 1, SIG_VALTYPE_ × 1'):
        assert want in text
    # the refused load's lines are its notes
    assert len(net.notes) == 3 and all(n in text for n in net.notes)
    assert net.notes[0].startswith("unknown key `bitrat`")
    # a refused load starts nothing, and the next one is the library's to make
    assert blobly.Project(SIM_DEMO).load().notes == []


def test_a_newer_schema_is_noted_not_refused_for_its_keys(tmp_path):
    path = write(tmp_path, "p.blobnet", project(version=99).replace("    databases: [u.dbc]\n", ""))
    net = blobly.Project(path, strict=True).load()
    assert len(net.notes) == 1 and net.notes[0].startswith("unknown key `cycle_msec` in channel")
