"""Background sends: a message sent on a period while the script waits for something else, and a
UDS session kept alive between the script's requests.

On sim-demo's CAN1 a Request (0x101) goes out every 100 ms from a sender of the engine's, and the
simulated SUT answers each with a Response whose RespCode is ReqCode + 1. Meanwhile the script
holds the SUT's extended session with a keep-alive, waits, changes what the sender sends, and
reads what both did.

    python background_send.py [project.blobnet] [--seconds N]

The project defaults to the repository's projects/sim-demo.blobnet. Exits 0 when the answers
followed the sender and the keep-alive ran, and 1 with a FAIL line otherwise."""
import argparse
import os
import sys
import time
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

SIM_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "sim-demo.blobnet"))


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    ap.add_argument("--seconds", type=float, default=1.5, help="how long to wait (default: 1.5)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:
        can1 = net.channels.CAN1
        with can1.uds(keep_alive_ms=500) as diag, can1.messages.Request.send_cyclic(100, ReqCode=5) as req:
            diag.session(0x03)  # extended: the keep-alive holds it from here
            print(f"a Request every {req.period_ms} ms; waiting {args.seconds} s")
            time.sleep(args.seconds)  # the script does something else: both go on underneath it
            _, code = can1.expect_signal("Response", "RespCode", 6, timeout_ms=1000)
            print(f"the SUT answers RespCode {code:g}")
            req.update(ReqCode=9)
            _, code = can1.expect_signal("Response", "RespCode", 10, timeout_ms=1000)
            print(f"after the update it answers RespCode {code:g}")
            st, ka = req.status(), diag.keep_alive_status
            print(f"sender: {st}")
            print(f"keep-alive: {ka}")
            if st.sent < args.seconds * 1000 / 100 or st.failed:
                fail(f"the sender sent {st.sent} and failed {st.failed}")
            if ka.sent < 1 or ka.failures:
                fail(f"the keep-alive sent {ka.sent} and failed {ka.failures}")
        print(f"stopped: {req.status()}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
