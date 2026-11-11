"""A signal wider than 64 bits carries no number. One that starts on a byte boundary and is whole
bytes long is read and written as bytes, in payload order; any other is left out of decode, and
encode, send and send_cyclic refuse a number for either in the words of the generator control."""
import pytest

import blobly
from blobly import Refused
from conftest import write

pytestmark = pytest.mark.usefixtures("engine")

WIDE_DBC = """VERSION ""

BU_: A

BO_ 1280 ConfigData: 32 A
 SG_ Mode : 0|8@1+ (1,0) [0|255] "" A
 SG_ Key : 8|128@1+ (1,0) [0|0] "" A
 SG_ KeyBe : 143|72@0+ (1,0) [0|0] "" A
 SG_ Odd : 204|68@1+ (1,0) [0|0] "" A
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
KEY = bytes(range(16))
KEY_BE = bytes(range(0xA0, 0xA9))


@pytest.fixture(scope="module")
def ch(tmp_path_factory):
    d = tmp_path_factory.mktemp("wide")
    write(d, "wide.dbc", WIDE_DBC)
    net = blobly.Project(write(d, "wide.blobnet", WIDE)).start()
    yield net.channels.WIDE
    net.stop()


def test_signal_kinds(ch):
    assert [s.kind for s in ch.messages.ConfigData.signals] == ["number", "bytes", "bytes", "none"]


def test_decode_reads_byte_signals_as_bytes_and_leaves_the_rest_out(ch):
    f = ch.messages.ConfigData.encode(Mode=2)
    data = bytes(range(32))
    assert ch.decode(blobly.Frame(f.id, data)) == {"Mode": 0, "Key": data[1:17], "KeyBe": data[17:26]}
    # a payload that does not hold KeyBe whole
    assert ch.decode(blobly.Frame(f.id, data[:20])) == {"Mode": 0, "Key": data[1:17]}


def test_encode_takes_bytes_in_payload_order(ch):
    f = ch.messages.ConfigData.encode(Mode=2, Key=KEY, KeyBe=bytearray(KEY_BE))
    assert f.data[0] == 2 and f.data[1:17] == KEY and f.data[17:26] == KEY_BE
    assert ch.decode(f) == {"Mode": 2, "Key": KEY, "KeyBe": KEY_BE}


def test_encode_refuses_bytes_where_a_signal_takes_none(ch):
    msg = ch.messages.ConfigData
    with pytest.raises(Refused, match="Key takes 16 bytes, not 3"):
        msg.encode(Key=b"abc")
    with pytest.raises(Refused, match=r"Mode is a number \(8 bits\), not bytes"):
        msg.encode(Mode=b"\x01")
    with pytest.raises(Refused, match="Odd is 68 bits wide from bit 204: bytes are read from"):
        msg.encode(Odd=bytes(9))
    with pytest.raises(TypeError, match="a number or bytes"):
        msg.encode(Key="text")


def test_encode_send_and_send_cyclic_refuse_a_number_for_a_wide_signal(ch):
    msg = ch.messages.ConfigData
    for call in (lambda: msg.encode(Key=1), lambda: msg.send(Key=1),
                 lambda: msg.send_cyclic(10, Key=1)):
        with pytest.raises(Refused, match=REFUSAL):
            call()


def test_a_sent_byte_signal_is_expected_as_bytes(ch):
    with blobly.open("inproc:PY_WIDE") as tap:
        tap.recv(0)  # subscribed before the send
        ch.messages.ConfigData.send(Key=KEY)
        got = tap.recv(1000)
        assert got is not None and got.data[1:17] == KEY
        ch.recv(0)
        tap.send(got.id, ch.messages.ConfigData.encode(Key=KEY, KeyBe=KEY_BE).data)
        f, v = ch.expect_signal("ConfigData", "KeyBe", KEY_BE, 1000)
        assert v == KEY_BE and f.data[17:26] == KEY_BE
    with pytest.raises(TypeError, match="KeyBe decodes to bytes"):
        ch.expect_signal("ConfigData", "KeyBe", 1, 10)
