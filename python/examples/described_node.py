"""A node of the system model by its name: its DIDs listed and read by name, a gated parameter
written through its description, and its DTCs named by its faults.

Starts the project, whose simulated zone_a answers as blobly_emb's ecu.toml describes it, and asks
the system model (the system.toml beside the project) for the node: the model supplies the channel
and the ids, and the node's ecu.toml the layout of each DID. Lists the DIDs with their gates, reads
the VIN, the live steering angle and the SteerLimit parameter decoded, tries a write the gate
refuses and catches what it needs (WriteGated), establishes it (the extended session, security
level 1 with blobly_net's reference key), writes SteerLimit and reads it back with its parameter
status, puts the parameter back, and lists the DTCs by their fault names.

    python described_node.py [project.blobnet] [--node NAME] [--param NAME] [--value N]

The project defaults to the repository's projects/described-ecu-demo/described-ecu-demo.blobnet,
whose node zone_a has the parameter SteerLimit (a u16 of 0..360, written in the extended session
at level 1). Exits 0 when every check held, and 1 with a FAIL line otherwise."""
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

DESCRIBED = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "described-ecu-demo",
                                          "described-ecu-demo.blobnet"))


def fail(why: str) -> NoReturn:
    sys.exit(f"FAIL: {why}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=DESCRIBED, help="a .blobnet project (default: described-ecu-demo)")
    ap.add_argument("--node", default="zone_a", help="the node to talk to (default: zone_a)")
    ap.add_argument("--param", default="SteerLimit", help="the parameter to write (default: SteerLimit)")
    ap.add_argument("--value", type=int, default=300, help="the value to write it to (default: 300)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()  # loads the library, on the main thread
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:  # loaded and started; stopped when the block ends
        if net.system is None:
            fail("no system.toml describes the project: it names no nodes")
        print(f"system model: {net.system}, nodes: {', '.join(net.nodes.keys())}")
        if args.node not in net.nodes.keys():
            fail(f"no node {args.node!r}; there are: {', '.join(net.nodes.keys())}")
        node = net.nodes[args.node]
        for d in node.dids:
            if d.kind == "unknown":
                continue  # the ISO identification DIDs it does not declare
            parts = ", ".join(f"{p.label} {p.hint}" for p in d.parts)
            write = f"written in {d.write_gate}" if d.write_gate else "read only"
            print(f"  0x{d.id:04X} {d.name or '(unnamed)'}: {d.kind}, {parts}; {write}")

        with node.uds() as diag:  # the channel and ids come from the model; closed when the block ends
            print(f"{diag}")
            diag.session(0x01)
            print(f"VIN {diag.read('VIN')!r}, steering angle {diag.read('SteeringAngle')}")
            param = node.did(args.param)
            if param is None or param.write_gate is None:
                fail(f"{args.node} has no writable DID {args.param!r}")
            was = diag.read(args.param)
            print(f"{args.param} = {was}")

            try:
                try:
                    diag.write(args.param, args.value)  # refused before anything is sent
                    fail(f"{args.param} was written in the default session, unlocked")
                except blobly.WriteGated as e:  # a typed error: what the gate needs
                    print(f"not written: needs session 0x{e.session:02X}, level {e.level}")
                    if e.session:
                        diag.session(e.session)
                    if e.level:
                        diag.security_access(2 * e.level - 1)  # 0x27 with blobly_net's reference key

                diag.write(args.param, args.value)
                now = diag.read(args.param)
                if now != args.value:
                    fail(f"{args.param} reads {now} after a write of {args.value}")
                print(f"{args.param} = {now}, written; parameter status {diag.read('parameter status')}")
                try:
                    diag.write(args.param, 100_000)
                    fail(f"{args.param} took 100000, past its range")
                except blobly.Refused as e:  # the description's range: nothing was sent
                    print(f"refused: {e}")
            finally:
                try:
                    diag.write(args.param, was)  # put back, whatever happened above
                except blobly.BloblyError as e:  # said, not raised: a failure above is the one to report
                    print(f"{args.param} not put back: {e}")
            diag.session(0x01)  # relocks

            for d in diag.dtcs():  # 0x19 02, each named by the description's [[fault]]
                print(f"  {d.name} {d.fault or '(not described)'} status 0x{d.status:02X}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
