"""DBC messages and signals: what a channel's databases define, encoding and decoding by signal
name, and a request sent by name whose answer is decoded.

Lists every message of the channel's databases with its signals: position, scaling, range, unit
and value labels. Then encodes sim-demo's Powertrain and decodes it back, and sends Request by
signal name and decodes the Response that sim-demo's SUT answers it with (RespCode = ReqCode + 1).

    python dbc_messages.py [project.blobnet] [--channel NAME]

The project defaults to the repository's projects/sim-demo.blobnet. The channel defaults to the
project's first CAN channel that has a database. Exits 0 when every check holds, and 1 with a
FAIL line otherwise."""
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


def fail(why: str) -> NoReturn:
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


def message(ch: blobly.Channel, name: str) -> blobly.Message:
    """The message `name` of the channel's databases; a FAIL naming what there is otherwise."""
    if name not in ch.messages.keys():
        fail(f"{ch.name} has no message {name!r} (this part expects sim-demo's database); "
             f"there are: {', '.join(ch.messages.keys())}")
    return ch.messages[name]


def describe(sig: blobly.Signal) -> str:
    """One line for a signal: where it sits, how it scales, its range, unit and labels."""
    line = (f"{sig.name:<14} bit {sig.start_bit}, {sig.length} bit(s) {sig.byte_order}-endian"
            f"{' signed' if sig.signed else ''}, x{sig.factor:.12g} {sig.offset:+.12g}")
    if sig.minimum != 0 or sig.maximum != 0:  # both 0: the DBC states no range
        line += f", [{sig.minimum:.12g} .. {sig.maximum:.12g}]"
    if sig.unit:
        line += f" {sig.unit}"
    if sig.multiplexor:
        line += ", the multiplexor"
    if sig.multiplexed:
        line += f", present when the multiplexor is {sig.mux_value}"
    if sig.labels:
        line += ", labels " + " ".join(f"{v:.12g}={text}" for v, text in sig.labels.items())
    return line


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    ap.add_argument("--channel", help="the CAN channel to use (default: the first with a database)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:
        can = db_channel(net, args.channel)  # a channel's messages exist while the project runs

        print(f"{can.name}: {len(can.messages)} message(s)")
        for msg in can.messages:
            kind = "29-bit" if msg.ext else "11-bit"
            j1939 = ", J1939" if msg.j1939 else ""
            print(f"  {msg.name} 0x{msg.id:X} ({kind}{j1939}), {msg.dlc} byte(s), {len(msg.signals)} signal(s)")
            for sig in msg.signals:
                print(f"    {describe(sig)}")

        # encode by signal name (every signal not named is raw 0), then decode the frame back
        powertrain = message(can, "Powertrain")
        frame = powertrain.encode(EngineSpeed=1500, Gear=3, CruiseOn=1)
        print(f"Powertrain encoded: {frame}")
        values = can.decode(frame)
        print(f"decoded: {values}")
        if values is None or (values["EngineSpeed"], values["Gear"], values["CruiseOn"]) != (1500, 3, 1):
            fail(f"Powertrain decoded as {values}, not what was encoded")
        print(f"Gear 3 is labelled {powertrain.signals.Gear.labels[3]!r}")

        # send by signal name; the SUT answers Request with Response, ReqCode + 1
        request, response = message(can, "Request"), message(can, "Response")
        sent = request.send(ReqCode=5)
        print(f"sent {request.name}: {sent}")
        try:
            answer = can.expect(response, timeout_ms=1000)  # its id and kind; other frames are consumed
        except blobly.Timeout as e:
            fail(str(e))
        decoded = can.decode(answer)
        print(f"{response.name}: {answer} -> {decoded}")
        if decoded != {"RespCode": 6}:
            fail(f"the answer decodes as {decoded}; sim-demo's SUT answers ReqCode 5 with RespCode 6")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
