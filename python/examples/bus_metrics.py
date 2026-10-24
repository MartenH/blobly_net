"""Bus metrics: a channel's load and its backend's dropped / error / undecodable counts, read while
the project runs.

Reads a CAN channel for a few seconds and prints, once a second, the load of the frames its handle
carried (the last whole second, and since it opened) and the diagnostics counts. The load is of
DECODED frames, both directions: what the channel reads and what it sends.

    python bus_metrics.py [project.blobnet] [--channel NAME] [--seconds N]

The project defaults to the repository's projects/sim-demo.blobnet, the channel to its first CAN
channel. Exits 0 when the channel carried traffic, and 1 with a FAIL line otherwise."""
import argparse
import os
import sys
from typing import NoReturn
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

SIM_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "sim-demo.blobnet"))


def fail(why: str) -> NoReturn:
    sys.exit(f"FAIL: {why}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    ap.add_argument("--channel", help="the CAN channel to read (default: the first one)")
    ap.add_argument("--seconds", type=int, default=3, help="how long to read (default: 3)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:
        cans = [c for c in net.channels if c.kind == "can" and args.channel in (None, c.name)]
        if not cans:
            fail(f"no enabled CAN channel {args.channel or ''}".rstrip())
        ch = cans[0]
        print(f"reading {ch.name} ({ch.iface}) for {args.seconds} s")
        ch.load()  # opens the channel's handle: its counts start here
        for _ in range(args.seconds):
            end = blobly.now_ms() + 1000
            while blobly.now_ms() < end:  # read for a second: a frame counts when it is read
                ch.recv(max(0.0, end - blobly.now_ms()))
            load, diag = ch.load(), ch.diagnostics()
            pct = "  n/a" if load.percent is None else f"{load.percent:5.2f}"  # None before a whole second
            avg = "  n/a" if load.average is None else f"{load.average:5.2f}"
            print(f"  {pct} % last second, {avg} % since open, "
                  f"{load.frames} frames at {load.nominal} bit/s; {diag}")
        if ch.load().frames == 0:
            fail(f"{ch.name} carried nothing")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
