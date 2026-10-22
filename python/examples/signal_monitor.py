"""A signal monitor: the decoded values of chosen messages, printed twice a second for N seconds.

Each chosen message gets an on_message handler that decodes its frames; a timer prints the
latest values with their units and value labels every 500 ms. At the end it prints how many
frames of each message arrived.

    python signal_monitor.py [project.blobnet] [--channel NAME] [--seconds 3]
                             [--message Powertrain --message WheelSpeeds ...]

The project defaults to the repository's projects/sim-demo.blobnet, the channel to the project's
first CAN channel with a database, and the messages to Powertrain and WheelSpeeds (both cyclic on
sim-demo's CAN1). Exits 0 when every chosen message arrived, and 1 with a FAIL line otherwise."""
import argparse
import os
import sys
import time
from collections.abc import Callable
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


def db_channel(net: blobly.Project, name: str | None) -> blobly.Channel:
    """The channel named `name`, or the project's first CAN channel with a database."""
    if name is not None:
        if name not in net.channels.keys():
            fail(f"no enabled channel named {name!r}; there are: {', '.join(net.channels.keys())}")
        ch = net.channels[name]
        if ch.kind != "can":
            fail(f"{ch.name} is a {ch.kind} channel, which has no database")
        return ch
    for ch in net.channels:
        if ch.kind == "can" and len(ch.messages) > 0:
            return ch
    fail("no enabled CAN channel of the project has a database")


def shown(sig: blobly.Signal, value: float) -> str:
    """`Name=value unit (label)`, as much of it as the database gives."""
    text = f"{sig.name}={value:.12g}"
    if sig.unit:
        text += f" {sig.unit}"
    label = sig.labels.get(value)
    if label is not None:
        text += f" ({label})"
    return text


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    ap.add_argument("--channel", help="the CAN channel to watch (default: the first with a database)")
    ap.add_argument("--seconds", type=float, default=3.0, help="how long to watch (default 3)")
    ap.add_argument("--message", action="append", dest="messages",
                    help="a message to watch, by name; repeat for more (default: Powertrain, WheelSpeeds)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")
    if not args.seconds > 0:
        fail("--seconds must be more than 0")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:
        can = db_channel(net, args.channel)
        names = list(dict.fromkeys(args.messages or ["Powertrain", "WheelSpeeds"]))  # each once
        missing = [n for n in names if n not in can.messages.keys()]
        if missing:
            fail(f"{can.name} has no message {', '.join(missing)}; there are: {', '.join(can.messages.keys())}")
        watched = [can.messages[n] for n in names]
        latest: dict[str, dict[str, float]] = {}
        counts = {m.name: 0 for m in watched}
        start = time.monotonic()

        def handler(msg: blobly.Message) -> Callable[[blobly.Frame], None]:
            def on_frame(frame: blobly.Frame) -> None:
                values = can.decode(frame)
                if values is not None:
                    latest[msg.name] = values
                    counts[msg.name] += 1
            return on_frame

        def show() -> None:
            t = time.monotonic() - start
            for msg in watched:
                values = latest.get(msg.name)
                if values is None:
                    print(f"{t:5.1f} s  {msg.name}: nothing yet")
                    continue
                parts = [shown(msg.signals[name], v) for name, v in values.items()]
                print(f"{t:5.1f} s  {msg.name}: " + "  ".join(parts))

        for msg in watched:
            net.on_message(can, msg, handler(msg))
        net.on_timer(500, show)
        print(f"watching {', '.join(names)} on {can.name} for {args.seconds:g} s")
        net.run(args.seconds * 1000)

        print("frames: " + ", ".join(f"{name} {n}" for name, n in counts.items()))
        silent = [name for name, n in counts.items() if n == 0]
        if silent:
            fail(f"no frame of {', '.join(silent)} in {args.seconds:g} s")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
