"""UDS over DoIP (ISO 13400): an entity heard announcing itself, asked who it is, and diagnosed over
its TCP connection, a functional request included.

Starts the project, which brings its simulated DoIP entity up inside this process on a loopback
port of its own, listens for the announcements it sends as it comes up, asks it to identify itself,
then opens a UDS client on its connection (routing activation from the channel's tester address to
its ECU address): the default session, the VIN it serves beside the one it announced, the DTCs,
and a request to the functional address 0xE400.

    python doip_diag.py [project.blobnet] [--channel NAME]

The project defaults to the repository's projects/sim-demo.blobnet, whose DoIP1 hosts the entity.
Exits 0 when every check held, and 1 with a FAIL line otherwise."""
import argparse
import os
import sys
from typing import NoReturn
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly (the repository root's blobly/ is the V
# engine's source, which Python would take for a namespace package)
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

SIM_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "sim-demo.blobnet"))
VIN = 0xF190


def fail(why: str) -> NoReturn:
    sys.exit(f"FAIL: {why}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    ap.add_argument("--channel", default="DoIP1", help="the DoIP channel (default: DoIP1)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()  # loads the library, on the main thread
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:  # loaded and started; stopped when the block ends
        if args.channel not in net.channels.keys():
            fail(f"no enabled channel named {args.channel!r}; there are: {', '.join(net.channels.keys())}")
        doip = net.channels[args.channel]
        if doip.kind != "doip":
            fail(f"{args.channel} is a {doip.kind} channel, not a DoIP one")
        print(f"{doip.name} on {doip.iface}")  # a hosted entity runs on a port of this run's own

        # an entity announces itself as it comes up; a tester that listens then hears it unasked
        heard = blobly.doip_listen(1200, channel=doip)
        print(f"heard {len(heard)} announcement(s): "
              + (", ".join(f"{a.vin} at 0x{a.logical_address:04X} from {a.source}" for a in heard) or "none"))

        found = doip.discover()  # ISO 13400 vehicle identification: asked, and answered
        print(f"discovered {found.vin} at logical address 0x{found.logical_address:04X}, "
              f"EID {found.eid.hex(':')}, from {found.source}")

        with doip.uds() as diag:  # TCP, then routing activation; closed when the block ends
            print(f"UDS over DoIP from 0x{diag.tester:04X} to 0x{diag.ecu:04X}")
            record = diag.session(0x01)
            print(f"default session: {record.hex(' ').upper()}")

            vin = diag.read_did(VIN).decode("ascii", "replace")
            print(f"VIN served {vin}, in {diag.last.rtt_us} us")
            if vin != found.vin:
                fail(f"the entity announces {found.vin} but serves {vin}")

            for d in diag.supported_dtcs():
                print(f"  {d.name} status 0x{d.status:02X}")

            # to the functional logical address (0xE400): one connection reaches one entity, so
            # one reply
            reply, = doip.uds_functional(None, [diag], bytes([0x22, VIN >> 8, VIN & 0xFF]))
            if reply.outcome != "positive":
                fail(f"a functional VIN read was {reply.outcome} {reply.error}")
            print(f"functional 0x22 F190: {reply.answer[3:].decode('ascii', 'replace')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
