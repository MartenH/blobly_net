"""J1939 from Python: Channel.j1939 against projects/j1939-script.blobnet, three rows on one
in-process wire. The engine answers nothing on J1939, so the tests play every node themselves:
Peer (SA 0x21) and Other (SA 0x00) send, J1939 (its database declares J1939) listens."""
import os

import pytest

import blobly
from conftest import REPO

PROJECT = os.path.join(REPO, "projects", "j1939-script.blobnet")
TP_CM, TP_DT, CLAIM = 0xEC00, 0xEB00, 0xEE00

pytestmark = pytest.mark.usefixtures("engine")


def jid(priority, pgn, da, sa):
    """The 29-bit id of `pgn` from `sa` to `da` (a PDU2 group's low byte is its own)."""
    pdu1 = (pgn >> 8) & 0xFF < 0xF0
    return (priority << 26) | ((pgn & 0x3FF00 | (da if pdu1 else pgn & 0xFF)) << 8) | sa


def cm(ch, sa, da, data):
    ch.send(jid(7, TP_CM, da, sa), bytes(data), ext=True)


def packets(ch, sa, da, payload, skip=()):
    for seq, i in enumerate(range(0, len(payload), 7), start=1):
        if seq not in skip:
            part = payload[i:i + 7]
            ch.send(jid(7, TP_DT, da, sa), bytes([seq]) + part + b"\xff" * (7 - len(part)), ext=True)


def announce(ctrl, payload, pgn, da_byte=0xFF):
    n = len(payload)
    return [ctrl, n & 0xFF, n >> 8, (n + 6) // 7, da_byte, pgn & 0xFF, (pgn >> 8) & 0xFF, pgn >> 16]


def name(identity, function, manufacturer=100):
    raw = identity | manufacturer << 21 | function << 40 | 1 << 63
    return raw, raw.to_bytes(8, "little")


@pytest.fixture(scope="module")
def net():
    with blobly.Project(PROJECT) as p:
        yield p


@pytest.fixture
def rows(net):
    """The three channels, each with a fresh handle (so nothing an earlier test left is read)."""
    chs = net.channels
    for c in chs:
        c.close()
        c.look()  # opened now: a shared wire hands a handle only what is sent after it opens
    return chs.J1939, chs.Peer, chs.Other


BODY = bytes([7]) + (123456).to_bytes(4, "little") + bytes([65, 1]) + bytes(range(12)) + b"\x2a"


def test_a_bam_is_one_message_decoded_by_pgn(rows):
    j, peer, _ = rows
    cm(peer, 0x21, 0xFF, announce(32, BODY, 0xFF10))
    packets(peer, 0x21, 0xFF, BODY)
    m = j.j1939().expect_pgn(0xFF10, 1000)
    assert (m.pgn, m.sa, m.da, m.bam, m.priority, m.packets) == (0xFF10, 0x21, 0xFF, True, 7, 3)
    assert m.data == BODY
    assert m.message is not None and m.message.name == "BodyStatus"
    assert m.signals["Counter"] == 7
    assert m.signals["Odometer"] == pytest.approx(12345.6)
    assert m.signals["CabTemp"] == 25
    assert m.signals["Tail"] == 0x2A, "a signal past the eighth byte"
    assert m.t_start_ms <= m.t_ms <= blobly.now_ms()
    assert j.j1939().faults() == []


def test_an_rts_cts_connection_played_from_both_sides(rows):
    j, peer, other = rows
    payload = bytes([3]) + (1000).to_bytes(2, "little") + bytes(12) + b"\x99"
    cm(peer, 0x21, 0x00, announce(16, payload, 0xEF00, 0xFF))
    cm(other, 0x00, 0x21, [17, 3, 1, 0xFF, 0xFF, 0x00, 0xEF, 0x00])  # CTS: 3 packets from 1
    packets(peer, 0x21, 0x00, payload)
    cm(other, 0x00, 0x21, [19, len(payload), 0, 3, 0xFF, 0x00, 0xEF, 0x00])  # end of message ack
    m = j.j1939().expect_pgn(0xEF00, 1000, sa=0x21)
    assert (m.bam, m.da, m.data) == (False, 0x00, payload)
    assert m.message.name == "PropA_Cfg"
    assert m.signals == {"Mode": 3, "Setpoint": 500, "Last": 0x99}


def test_a_sequence_gap_is_a_fault_and_no_message(rows):
    j, peer, _ = rows
    listener = j.j1939()
    cm(peer, 0x21, 0xFF, announce(32, BODY, 0xFF10))
    packets(peer, 0x21, 0xFF, BODY, skip=(2,))
    with pytest.raises(blobly.Timeout, match="sequence"):
        listener.expect_pgn(0xFF10, 300)
    faults = listener.faults()
    assert [f.kind for f in faults][:1] == ["sequence"]
    assert (faults[0].sa, faults[0].pgn) == (0x21, 0xFF10)
    assert "PGN 0xFF10" in str(faults[0])
    assert listener.faults() == [], "taken once"


def test_a_stalled_bam_times_out_once_nothing_is_queued(rows):
    j, peer, _ = rows
    cm(peer, 0x21, 0xFF, announce(32, BODY, 0xFF10))
    packets(peer, 0x21, 0xFF, BODY[:7])
    listener = j.j1939()
    assert listener.messages(900) == []
    assert [f.kind for f in listener.faults()] == ["timeout"]


def test_claims_and_a_contested_claim(rows):
    j, peer, other = rows
    high, high_bytes = name(500, 26)  # a body controller
    low, low_bytes = name(1, 0)  # an engine: the lower NAME
    peer.send(jid(6, CLAIM, 0xFF, 0x80), high_bytes, ext=True)
    other.send(jid(6, CLAIM, 0xFF, 0x00), low_bytes, ext=True)
    got = j.j1939().addresses(200)
    assert [(a.sa, a.name.raw) for a in got] == [(0x00, low), (0x80, high)]
    body = got[1].name
    assert (body.function, body.function_name, body.identity, body.manufacturer) == (26, "Body Controller", 500, 100)
    assert body.arbitrary_address_capable
    # the engine claims 0x80 too and wins it; the body controller, holding nothing, gives up
    other.send(jid(6, CLAIM, 0xFF, 0x80), low_bytes, ext=True)
    got = j.j1939().addresses(200)
    assert [(a.sa, a.name.raw) for a in got] == [(0x80, low)], "the lower NAME keeps it, and has left 0x00"
    peer.send(jid(6, CLAIM, 0xFF, 0xFE), high_bytes, ext=True)  # Cannot Claim
    assert [a.sa for a in j.j1939().addresses(200)] == [0x80]


def test_a_row_that_does_not_say_j1939_reads_it_only_when_asked(rows):
    _, peer, other = rows
    cm(peer, 0x21, 0xFF, announce(32, BODY, 0xFF10))
    packets(peer, 0x21, 0xFF, BODY)
    assert other.recv(200) is not None  # read before anything asked: not J1939 on this row
    listener = other.j1939()
    while other.recv(50) is not None:
        pass
    assert listener.messages(0) == []
    cm(peer, 0x21, 0xFF, announce(32, BODY, 0xFF10))
    packets(peer, 0x21, 0xFF, BODY)
    m = listener.expect_pgn(0xFF10, 1000)
    assert m.message is None and m.signals == {}, "Other has no database"


def test_frames_read_by_recv_feed_the_listener(rows):
    j, peer, _ = rows
    cm(peer, 0x21, 0xFF, announce(32, BODY, 0xFF10))
    packets(peer, 0x21, 0xFF, BODY)
    seen = [j.recv(200) for _ in range(4)]
    assert all(f is not None for f in seen), "the frames are still the channel's"
    assert [m.pgn for m in j.j1939().messages(0)] == [0xFF10]


def test_expect_pgn_refuses_what_is_no_pgn(rows):
    j = rows[0]
    with pytest.raises(ValueError):
        j.j1939().expect_pgn(0x40000, 10)
    with pytest.raises(TypeError):
        j.j1939().expect_pgn("0xFF10", 10)
    with pytest.raises(blobly.Timeout, match="no multi-packet message came"):
        j.j1939().expect_pgn(0xFF10, 50)
