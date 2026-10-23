"""Raw ISO-TP and a UDS client's timing: whole messages on an id pair with no UDS on top, then the
waits a UDS request is bounded by, read and stated.

Starts the project, opens a raw ISO-TP channel on the SUT's request / response pair and sends it a
VIN request (its multi-frame answer comes back reassembled) and a request the UDS helpers would
never build (a DID cut short, whose negative answer comes back as bytes), and waits for nothing
more. Then a UDS client with a short first wait, on ids nothing answers, fails in that wait rather
than the default second, and a client on the SUT shows the timing a session answer adopted.

    python isotp_raw.py [project.blobnet] [--channel NAME] [--tx 0x7E0] [--rx 0x7E8]
                        [--silent-tx 0x6F0] [--silent-rx 0x6F8]

The project defaults to the repository's projects/sim-demo.blobnet, whose CAN1 has the SUT at
0x7E0 / 0x7E8 and nothing at 0x6F0 / 0x6F8. Exits 0 when every check held, and 1 with a FAIL line otherwise."""
import argparse
import os
import sys
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly (the repository root's blobly/ is the V
# engine's source, which Python would take for a namespace package)
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

SIM_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "sim-demo.blobnet"))


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    ap.add_argument("--channel", default="CAN1", help="the CAN channel (default: CAN1)")
    ap.add_argument("--tx", type=lambda v: int(v, 0), default=0x7E0, help="the request id (default: 0x7E0)")
    ap.add_argument("--rx", type=lambda v: int(v, 0), default=0x7E8, help="the response id (default: 0x7E8)")
    ap.add_argument("--silent-tx", type=lambda v: int(v, 0), default=0x6F0,
                    help="a request id nothing answers, for the short wait (default: 0x6F0)")
    ap.add_argument("--silent-rx", type=lambda v: int(v, 0), default=0x6F8,
                    help="its response id (default: 0x6F8)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()  # loads the library, on the main thread
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:  # loaded and started; stopped when the block ends
        if args.channel not in net.channels.keys():
            fail(f"no enabled channel named {args.channel!r}; there are: {', '.join(net.channels.keys())}")
        ch = net.channels[args.channel]
        if ch.kind != "can":
            fail(f"{args.channel} is a {ch.kind} channel; raw ISO-TP runs on a CAN one")

        with ch.isotp(args.tx, args.rx) as tp:  # closed when the block ends
            print(f"raw ISO-TP on {ch.name}, 0x{tp.tx:X} out, 0x{tp.rx:X} back")
            tp.send(b"\x22\xf1\x90")  # ReadDataByIdentifier VIN, as UDS would send it
            answer = tp.recv(1000)
            if answer is None or answer[:3] != b"\x62\xf1\x90":
                fail(f"the VIN request was answered {answer!r}")
            print(f"VIN answer, {len(answer)} bytes reassembled: {answer[3:].decode('ascii', 'replace')}")

            tp.send(b"\x22\xf1")  # a DID cut short: no UDS helper builds it
            answer = tp.recv(1000)
            print(f"a request cut short: {answer.hex(' ').upper() if answer else None}")
            if answer is None or answer[0] != 0x7F:
                fail("the request cut short was not refused")
            if tp.recv(100) is not None:
                fail("a second answer came")
            print("nothing more within 100 ms")

        # a UDS client's waits: a first wait of 100 ms on ids nothing answers fails in 100 ms
        with ch.uds(tx=args.silent_tx, rx=args.silent_rx, timeout_ms=100) as nobody:
            try:
                nobody.tester_present()
                fail(f"something answered 0x{args.silent_tx:X}; name a pair nothing answers with --silent-tx/--silent-rx")
            except blobly.Timeout:
                print(f"no answer on 0x{args.silent_tx:X}, given up after {nobody.last.rtt_us // 1000} ms")
        with ch.uds(tx=args.tx, rx=args.rx) as diag:
            diag.session(0x01)  # its timing record: P2 and P2*, which the client adopts
            print(f"after the session: first wait {diag.timeout_ms} ms, P2* {diag.p2_star_ms} ms, "
                  f"margin {diag.margin_ms} ms, at most {diag.pending_budget_ms} ms a request")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
