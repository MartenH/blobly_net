"""Raw CAN, first steps: list a project's channels, receive frames, send one and check the answer.

Starts the project, which brings its simulated ECUs up inside this process. Prints every enabled
channel with its name, kind and interface, receives a few frames on a CAN channel, then sends
0x101 and waits for 0x102: sim-demo's SUT answers 0x101 with 0x102, the first byte plus one.

    python raw_can.py [project.blobnet] [--channel NAME]

The project defaults to the repository's projects/sim-demo.blobnet. The channel defaults to the
project's first CAN channel. Exits 0 when the answer came and is right, and 1 with a FAIL line
otherwise."""
import argparse
import os
import sys
import time
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
if find_spec("blobly") is None:  # not installed: use this checkout's python/blobly
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

SIM_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "sim-demo.blobnet"))
REQUEST, ANSWER = 0x101, 0x102


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def can_channel(net: blobly.Project, name: str | None) -> blobly.Channel:
    """The channel named `name`, or the project's first CAN channel."""
    if name is not None:
        if name not in net.channels.keys():
            fail(f"no enabled channel named {name!r}; there are: {', '.join(net.channels.keys())}")
        ch = net.channels[name]
    else:
        ch = next((c for c in net.channels if c.kind == "can"), None)
        if ch is None:
            fail("the project has no enabled CAN channel")
    if ch.kind != "can":
        fail(f"{ch.name} is a {ch.kind} channel, which carries no CAN frames")
    return ch


def wait_for(ch: blobly.Channel, frame_id: int, timeout_ms: float) -> blobly.Frame | None:
    """The first standard frame with this id on `ch` within timeout_ms, else None. Every other
    frame read on the way is consumed: recv takes frames off this channel's handle."""
    deadline = time.monotonic() + timeout_ms / 1000
    while True:
        left_ms = (deadline - time.monotonic()) * 1000
        if left_ms <= 0:
            return None
        f = ch.recv(left_ms)
        if f is not None and f.id == frame_id and not f.ext:
            return f


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    ap.add_argument("--channel", help="the CAN channel to use (default: the first one)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()  # loads the library, on the main thread
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:  # loaded and started; stopped when the block ends
        print(f"{len(net.channels)} enabled channel(s):")
        for ch in net.channels:
            print(f"  {ch.name:<10} {ch.kind:<7} {ch.iface}")

        can = can_channel(net, args.channel)
        print(f"receiving on {can.name}:")
        for _ in range(5):
            f = can.recv(500)  # at most 500 ms; None when nothing came
            if f is None:
                print("  nothing within 500 ms")
                break
            print(f"  {f}")

        request = bytes([0x05])
        print(f"sending 0x{REQUEST:X} [{request.hex().upper()}] on {can.name}")
        can.send(REQUEST, request)
        answer = wait_for(can, ANSWER, 1000)
        if answer is None:
            fail(f"no 0x{ANSWER:X} on {can.name} within 1000 ms; sim-demo's SUT answers 0x{REQUEST:X} with it")
        if answer.data[:1] != bytes([request[0] + 1]):
            fail(f"the answer is {answer}; its first byte should be 0x{request[0] + 1:02X}")
        print(f"answered: {answer}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
