"""A signal wider than 64 bits carries no number: decode leaves it out, and encode, send and
send_cyclic refuse a value for it in the words of the generator control."""
import pytest

import blobly
from blobly import Refused
from conftest import write

pytestmark = pytest.mark.usefixtures("engine")

WIDE_DBC = """VERSION ""

BU_: A

BO_ 1280 ConfigData: 24 A
 SG_ Mode : 0|8@1+ (1,0) [0|255] "" A
 SG_ Key : 8|128@1+ (1,0) [0|0] "" A
"""

WIDE = """project:
  name: wide
  version: 8
channels:
  - name: WIDE
    type: canfd
    interface: inproc:PY_WIDE
    bitrate: 500000
    data_bitrate: 2000000
    databases:
      - wide.dbc
"""

REFUSAL = "Key is 128 bits wide: a value is encoded into 1 .. 64"


@pytest.fixture(scope="module")
def ch(tmp_path_factory):
    d = tmp_path_factory.mktemp("wide")
    write(d, "wide.dbc", WIDE_DBC)
    net = blobly.Project(write(d, "wide.blobnet", WIDE)).start()
    yield net.channels.WIDE
    net.stop()


def test_decode_leaves_a_wide_signal_out(ch):
    f = ch.messages.ConfigData.encode(Mode=2)
    assert ch.decode(blobly.Frame(f.id, bytes(range(24)))) == {"Mode": 0}


def test_encode_send_and_send_cyclic_refuse_a_wide_signal(ch):
    msg = ch.messages.ConfigData
    for call in (lambda: msg.encode(Key=1), lambda: msg.send(Key=1),
                 lambda: msg.send_cyclic(10, Key=1)):
        with pytest.raises(Refused, match=REFUSAL):
            call()
