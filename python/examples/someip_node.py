"""SOME/IP against a node with a static peer endpoint, a blobly_emb SOME/IP node: one method called
and answered, a request sent with everything heard after it, and the events the node publishes.

A blobly_emb node accepts datagrams only from its configured peer and answers that endpoint, so
every call here goes out FROM the peer port (--port). The defaults are blobly_emb's
examples/host_someip: the node on 127.0.0.1:30490, its peer 30491, service 0x0100.

    python someip_node.py [--to HOST:PORT] [--port PORT] [--service ID] [--method ID]

Needs no project and no hardware: only the node. Exits 0 when the method was answered (a RESPONSE,
or an ERROR naming its return code), and 1 with a FAIL line otherwise."""
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
from blobly import SomeipMessage, someip  # noqa: E402


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--to", default="127.0.0.1:30490", help="the node, IPv4 host:port (default: 127.0.0.1:30490)")
    ap.add_argument("--port", type=int, default=30491, help="the node's peer port, sent from (default: 30491)")
    ap.add_argument("--service", type=lambda s: int(s, 0), default=0x0100, help="the service id (default: 0x0100)")
    ap.add_argument("--method", type=lambda s: int(s, 0), default=0x0001, help="a method id (default: 0x0001)")
    args = ap.parse_args(argv)

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()  # loads the library, on the main thread
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")

    # one request, its answer the RESPONSE or ERROR mirroring its Request ID; events skipped
    try:
        answer = someip.call(args.to, SomeipMessage(args.service, args.method, b"\x01\x02"), port=args.port)
    except blobly.Timeout:
        fail(f"no answer from {args.to} to 0x{args.service:04X}:0x{args.method:04X} within 1000 ms")
    print(f"call 0x{answer.service:04X}:0x{answer.method:04X} session {answer.session}: {answer.type} "
          f"rc {answer.return_code}, payload {answer.payload.hex(' ') or '-'}, in {answer.at_ms} ms")

    # a request sent, and everything the node said within the window after it
    heard, malformed = someip.send(args.to, SomeipMessage(args.service, args.method), port=args.port, window_ms=500)
    for m in heard:
        print(f"  heard {m.type} 0x{m.service:04X}:0x{m.method:04X} from {m.source} at {m.at_ms} ms: "
              f"{m.payload.hex(' ') or '-'}")
    print(f"send: {len(heard)} message(s), {malformed} malformed datagram(s)")

    # what the node publishes to its peer, nothing sent
    events, malformed = someip.listen(500, port=args.port)
    print(f"listen: {len([m for m in events if m.event])} event(s) in 500 ms, {malformed} malformed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
