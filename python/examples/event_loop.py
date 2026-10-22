"""The event loop: handlers for frames by id and by DBC message, a timer that sends a request
every 100 ms, a health handler, and run().

Registers the handlers, then runs the loop for a while. The timer sends sim-demo's Request with
ReqCode 1, 2, 3 ...; the SUT answers each with Response, RespCode = ReqCode + 1. One handler
counts 0x102 by its raw id, another decodes it as the Response message, and a third listens for
Request to show that this script never hears its own sends. On a software bus (sim-demo's
inproc: channels) on_health never fires: there is no controller to report a state.

    python event_loop.py [project.blobnet] [--channel NAME] [--ms 2000]

The project defaults to the repository's projects/sim-demo.blobnet. The channel defaults to the
project's first CAN channel. Exits 0 when the answers match the requests, and 1 with a FAIL line
otherwise."""
import argparse
import os
import sys
from dataclasses import dataclass, field
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
if find_spec("blobly") is None:  # not installed: use this checkout's python/blobly
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

SIM_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "sim-demo.blobnet"))


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


@dataclass
class Tally:
    sent: list[int] = field(default_factory=list)      # ReqCode of each Request sent
    answers: list[int] = field(default_factory=list)   # RespCode of each Response decoded
    by_id: int = 0                                      # frames the raw-id handler saw
    own: int = 0                                        # our own Requests heard back: always 0
    states: list[str] = field(default_factory=list)    # what on_health reported


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    ap.add_argument("--channel", help="the CAN channel to use (default: the first one)")
    ap.add_argument("--ms", type=float, default=2000, help="how long run() runs, in ms (default 2000)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:
        can = can_channel(net, args.channel)
        msgs = can.messages
        for name in ("Request", "Response"):
            if name not in msgs.keys():
                fail(f"{can.name} has no message {name!r}; this example expects sim-demo's database")
        request, response = msgs.Request, msgs.Response
        tally = Tally()

        def send_request() -> None:
            code = len(tally.sent) + 1
            request.send(ReqCode=code)
            tally.sent.append(code)

        def on_raw(frame: blobly.Frame) -> None:
            tally.by_id += 1

        def on_response(frame: blobly.Frame) -> None:
            tally.answers.append(int(can.decode(frame)["RespCode"]))

        def on_own(frame: blobly.Frame) -> None:
            tally.own += 1

        def on_health(state: str) -> None:
            tally.states.append(state)
            print(f"{can.name} is {state}")

        def progress() -> None:
            print(f"  sent {len(tally.sent)}, answered {len(tally.answers)}")

        net.on_message(can, response.id, on_raw)     # an int id: matches 11- and 29-bit alike
        net.on_message(can, response, on_response)   # a Message: its id and its kind
        net.on_message(can, request, on_own)          # this script's own sends never arrive
        net.on_health(can, on_health)
        net.on_timer(100, send_request)
        net.on_timer(500, progress)
        print(f"running for {args.ms:g} ms on {can.name} ({can.iface})")
        net.run(args.ms)

        print(f"sent {len(tally.sent)} request(s), decoded {len(tally.answers)} answer(s)")
        if not tally.answers:
            fail(f"no {response.name} in {args.ms:g} ms")
        wrong = [a for a in tally.answers if a - 1 not in tally.sent]
        if wrong:
            fail(f"answers {wrong} match no request sent ({tally.sent})")
        if tally.by_id != len(tally.answers):
            fail(f"the raw-id handler saw {tally.by_id} frame(s), the Response handler {len(tally.answers)}: "
                 "a frame should reach every handler it matches")
        if tally.own:
            fail(f"heard {tally.own} of this script's own Requests")
        health = can.health()
        print(f"{can.name} health now: {health!r}" + (" (a software bus has no controller)" if health == "" else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
