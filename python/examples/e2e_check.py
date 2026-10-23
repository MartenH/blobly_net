"""E2E on what a script reads and sends: AUTOSAR E2E Profile 1 as the project's DBC declares it.

On e2e-demo's in-process wire (rows E2E and E2E_TAP, one wire):
  - every BrakeStatus frame the simulated Chassis sends carries its verdict, Frame.e2e: "ok";
  - faults on Chassis earn the verdicts a receiver gives a broken sender: bad_crc for a broken
    checksum, repeated for a frozen counter; expect(..., e2e=True) raises blobly.E2eError for one;
  - BrakeCommand sent by name is stamped with its declared counter and CRC, and E2E_TAP hears it
    "ok"; the same message encoded and sent as a raw frame goes out unstamped, and is bad_crc.

    python e2e_check.py [project.blobnet]

The project defaults to the repository's projects/e2e-demo.blobnet; another needs its rows E2E
and E2E_TAP on one wire, and its messages. Exits 0 when every check held, and 1 with a FAIL line
otherwise."""
import argparse
import os
import sys
import time
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly (the repository root's blobly/ is the V
# engine's source, which Python would take for a namespace package)
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402
from blobly import E2eError, E2eStatus, FaultKind  # noqa: E402

E2E_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "e2e-demo.blobnet"))


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def verdicts(ch: blobly.Channel, msg: blobly.Message, n: int, seconds: float = 2.0) -> list[E2eStatus | None]:
    """The verdicts of the next n frames of `msg` on `ch`, within `seconds`."""
    out: list[E2eStatus | None] = []
    end = time.monotonic() + seconds
    while len(out) < n and (left := end - time.monotonic()) > 0:
        f = ch.recv(left * 1000)
        if f is not None and (f.id, f.ext) == (msg.id, msg.ext):
            out.append(f.e2e)
    return out


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=E2E_DEMO, help="a .blobnet project (default: e2e-demo)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:
        if not {"E2E", "E2E_TAP"} <= set(net.channels.keys()):
            fail("the project has no rows E2E and E2E_TAP; this example expects e2e-demo's")
        ch, tap = net.channels.E2E, net.channels.E2E_TAP
        status, command = ch.messages.BrakeStatus, ch.messages.BrakeCommand

        got = verdicts(ch, status, 10)
        print("BrakeStatus, as Chassis sends it:", " ".join(map(str, got)))
        if got != ["ok"] * 10:
            fail(f"BrakeStatus from the simulated sender did not pass: {got}")

        for kind, want in ((FaultKind.BAD_CRC, E2eStatus.BAD_CRC), (FaultKind.FREEZE_COUNTER, E2eStatus.REPEATED)):
            net.fault(ch, "Chassis", status, kind)
            try:
                for _ in range(100):  # frames queued before the fault landed still pass
                    ch.expect(status, 500, e2e=True)
                fail(f"no frame failed while {kind} was armed")
            except E2eError as e:
                print(f"{kind}: {e}")
                if e.status is not want:
                    fail(f"{kind} read as {e.status}, not {want}")
            net.clear_faults()
            if E2eStatus.OK not in verdicts(ch, status, 20):
                fail(f"BrakeStatus did not pass again after {kind} was cleared")

        tap.recv(0)  # opened: it hears what is sent from here on
        sent = [command.send(Demand=100 * i) for i in range(3)]
        heard = verdicts(tap, command, 3)
        print("BrakeCommand sent by name, as E2E_TAP judges it:", " ".join(map(str, heard)),
              "| counters", [f.data[3] & 0x0F for f in sent])
        if heard != ["ok"] * 3:
            fail(f"BrakeCommand sent by name did not pass: {heard}")
        raw = command.encode(Demand=700)
        ch.send(raw.id, raw.data, ext=raw.ext)
        unstamped = tap.expect(tap.messages.BrakeCommand, 500)
        print(f"BrakeCommand sent as a raw frame: {unstamped} {unstamped.e2e}")
        if unstamped.e2e is not E2eStatus.BAD_CRC:
            fail(f"an unstamped BrakeCommand read as {unstamped.e2e}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
