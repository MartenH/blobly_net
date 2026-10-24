"""Interfaces: list what is present to open, then open one by its address with no project at all.

Prints every interface the engine knows without a network wait (SocketCAN links, the vendor
channels installed drivers report, the software buses, a connected CAN bridge) with its address,
kind, CAN-FD support and description; with --cansub, the CANsub channels an mDNS browse finds;
and the Vector driver's state with each physical channel and the application channel mapped to
it. Then opens two buses on one address, sends a frame on one and expects it on the other.

    python interfaces.py [--open ADDRESS] [--cansub] [--seconds N]

ADDRESS defaults to an in-process bus, which needs nothing; give vcan0 (or kvaser:0@500000,
vector:1@500000, ...) to exchange the frame there, and --seconds to also print what else arrives
on it for N seconds. Two handles on one PCAN or CANsub channel share one driver connection, which
does not hand one handle's sends to the other, so the exchange needs another node there. Exits 0 when the frame came back, and 1 with a FAIL line otherwise."""
import argparse
import os
import sys
import time
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly (the repository root's blobly/ is the V
# engine's source, which Python would take for a namespace package)
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402
from blobly import vector  # noqa: E402

FD = {True: "FD", False: "classic", None: "?"}


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def show(rows: list[blobly.Interface]) -> None:
    for i in rows:
        extra = f"  [{i.state}]" if i.state else ""
        print(f"  {i.address:<32} {i.kind:<9} {FD[i.fd]:<7} {i.description}{extra}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--open", default="inproc:EXAMPLE", help="the address to exchange a frame on")
    ap.add_argument("--cansub", action="store_true", help="browse mDNS for CANsub devices (waits 700 ms)")
    ap.add_argument("--seconds", type=float, default=0, help="then print what arrives for N seconds")
    args = ap.parse_args(argv)

    sys.stdout.reconfigure(line_buffering=True)
    blobly.init()  # loads the library, on the main thread
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    rows = blobly.interfaces()
    print(f"{len(rows)} interface(s) present:")
    show(rows)
    if args.cansub:
        found = blobly.discover_cansub(700)
        print(f"{len(found)} CANsub channel(s) found:")
        show(found)
    why = vector.driver()
    if why is not None:
        print(f"Vector: {why}")
    else:
        for h in vector.assignments():
            mapped = f"vector:{h.app}" if h.app else ("unassigned" if h.owner_known else "unknown")
            print(f"  {h.name:<24} {h.transceiver:<24} {'FD' if h.fd_iso else 'classic'}  {mapped}")

    # two handles on one address are two nodes on that wire: one hears what the other sends
    with blobly.open(args.open) as a, blobly.open(args.open) as b:
        a.send(0x7A1, b"\x01\x02\x03")
        try:
            got = b.expect(0x7A1, 1000)
        except blobly.Timeout as e:
            fail(str(e))
        if got.data != b"\x01\x02\x03":
            fail(f"0x7A1 came back as {got.data.hex()}")
        print(f"{args.open}: 0x7A1 sent on one handle, received on the other; load {a.load()}")
        until = time.monotonic() + args.seconds
        while time.monotonic() < until:
            f = b.recv(100)
            if f is not None:
                print(f"  {f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
