"""J1939 from a script: a multi-packet message rejoined from the transport protocol and decoded by
PGN, an RTS/CTS connection followed as a listener, a dropped packet seen as a fault, and the address
directory after a contested claim.

The engine reads J1939 and answers none of it, so on projects/j1939-script.blobnet (three rows on
one in-process wire) the script plays every node itself: Peer (SA 0x21) and Other (SA 0x00) send,
J1939 listens — its database declares J1939, so its handle reads it from its first frame.

    python j1939_listen.py [project.blobnet]

Exits 0 when every step reads as it should, and 1 with a FAIL line otherwise."""
import os
import sys
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

PROJECT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "j1939-script.blobnet"))
TP_CM, TP_DT, CLAIM = 0xEC00, 0xEB00, 0xEE00


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def jid(priority: int, pgn: int, da: int, sa: int) -> int:
    """The 29-bit id of `pgn` from `sa` to `da` (a PDU2 group keeps its own low byte)."""
    ps = da if (pgn >> 8) & 0xFF < 0xF0 else pgn & 0xFF
    return priority << 26 | (pgn & 0x3FF00 | ps) << 8 | sa


def transfer(ch: blobly.Channel, sa: int, da: int, ctrl: int, pgn: int, payload: bytes, skip: int = 0) -> None:
    """An announcement (BAM 32, RTS 16) and the TP.DT packets after it, packet `skip` left out."""
    n = len(payload)
    ch.send(jid(7, TP_CM, da, sa), bytes([ctrl, n & 0xFF, n >> 8, (n + 6) // 7, 0xFF,
                                          pgn & 0xFF, pgn >> 8 & 0xFF, pgn >> 16]), ext=True)
    for seq, i in enumerate(range(0, n, 7), start=1):
        if seq != skip:
            part = payload[i:i + 7]
            ch.send(jid(7, TP_DT, da, sa), bytes([seq]) + part + b"\xff" * (7 - len(part)), ext=True)


def claim(ch: blobly.Channel, sa: int, identity: int, function: int) -> None:
    name = 1 << 63 | function << 40 | 100 << 21 | identity
    ch.send(jid(6, CLAIM, 0xFF, sa), name.to_bytes(8, "little"), ext=True)


def main(argv: list[str]) -> int:
    project = argv[0] if argv else PROJECT
    if not os.path.isfile(project):
        fail(f"no project at {project}; pass the path of a .blobnet file")
    sys.stdout.reconfigure(line_buffering=True)
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(project) as net:
        j, peer, other = net.channels.J1939, net.channels.Peer, net.channels.Other
        listener = j.j1939()
        for c in (j, other):
            c.look()  # handles open before anything is sent: a wire hands a handle what comes after

        body = bytes([7]) + (123456).to_bytes(4, "little") + bytes([65, 1]) + bytes(12) + b"\x2a"
        transfer(peer, 0x21, 0xFF, 32, 0xFF10, body)
        m = listener.expect_pgn(0xFF10, timeout_ms=1000)
        if m.message is None:
            fail(f"PGN 0xFF10 not decoded: {m.note or 'nothing defines it'}")
        print(f"BAM: {m.message.name} from SA 0x{m.sa:02X}, {len(m.data)} bytes in {m.packets} packets: {m.signals}")

        # RTS/CTS: Peer announces to Other, Other paces it with a CTS and acknowledges the end
        cfg = bytes([3]) + (1000).to_bytes(2, "little") + bytes(12) + b"\x99"
        peer.send(jid(7, TP_CM, 0x00, 0x21), bytes([16, len(cfg), 0, 3, 0xFF, 0x00, 0xEF, 0x00]), ext=True)
        other.send(jid(7, TP_CM, 0x21, 0x00), bytes([17, 3, 1, 0xFF, 0xFF, 0x00, 0xEF, 0x00]), ext=True)
        for seq, i in enumerate(range(0, len(cfg), 7), start=1):
            part = cfg[i:i + 7]
            peer.send(jid(7, TP_DT, 0x00, 0x21), bytes([seq]) + part + b"\xff" * (7 - len(part)), ext=True)
        other.send(jid(7, TP_CM, 0x21, 0x00), bytes([19, len(cfg), 0, 3, 0xFF, 0x00, 0xEF, 0x00]), ext=True)
        m = listener.expect_pgn(0xEF00, timeout_ms=1000, sa=0x21)
        print(f"RTS/CTS: {m.message.name} to SA 0x{m.da:02X}: {m.signals}")

        transfer(peer, 0x21, 0xFF, 32, 0xFF10, body, skip=2)
        try:
            listener.expect_pgn(0xFF10, timeout_ms=300)
            fail("a transfer missing its second packet completed")
        except blobly.Timeout:
            pass
        faults = listener.faults()
        if [f.kind for f in faults][:1] != ["sequence"]:
            fail(f"a dropped packet was not a sequence fault: {faults}")
        print(f"fault: {faults[0]}")

        claim(peer, 0x80, 500, 26)  # a body controller at 0x80
        claim(other, 0x00, 1, 0)    # an engine at 0x00 ...
        claim(other, 0x80, 1, 0)    # ... claims 0x80 too, and its lower NAME takes it
        held = listener.addresses(200)
        for a in held:
            print(f"SA 0x{a.sa:02X}: {a.name.function_name or a.name.function}, identity {a.name.identity}")
        if [(a.sa, a.name.identity) for a in held] != [(0x80, 1)]:
            fail(f"the contested address is not the lower NAME's: {held}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
