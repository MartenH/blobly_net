"""Fault injection: make a simulated ECU misbehave on purpose and watch the bus.

Three faults on sim-demo's CAN1, each seen on the wire:
  - drop: SUT's Powertrain (0x100, every 100 ms) for one second. Its frames are counted per 250 ms
    window: they stop, and come back by themselves when the second is up.
  - out_of_range: ChassisECU's BrakeStatus with BrakePedal, declared 0..100, forced to 127 until
    the fault is cleared.
  - bad_crc: refused, because sim-demo protects nothing. A fault that would change no bit on the
    wire is refused rather than armed (blobly.FaultRefused says why).

    python fault_injection.py [project.blobnet]

The project defaults to the repository's projects/sim-demo.blobnet; another needs sim-demo's
nodes and messages on its CAN1. Exits 0 when each fault did what it should, and 1 with a FAIL
line otherwise."""
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
from blobly import FaultKind  # noqa: E402

SIM_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "sim-demo.blobnet"))


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def count(ch: blobly.Channel, frame_id: int, seconds: float) -> int:
    """How many frames of `frame_id` arrive on `ch` in the next `seconds`."""
    end, n = time.monotonic() + seconds, 0
    while (left := end - time.monotonic()) > 0:
        f = ch.recv(left * 1000)
        n += f is not None and f.id == frame_id
    return n


def last_value(ch: blobly.Channel, msg: blobly.Message, signal: str, seconds: float) -> float | None:
    """`signal` in the last frame of `msg` on `ch` in the next `seconds`: the frames already queued
    when the window opens were sent before it."""
    end, value = time.monotonic() + seconds, None
    while (left := end - time.monotonic()) > 0:
        f = ch.recv(left * 1000)
        if f is not None and f.id == msg.id and f.ext == msg.ext:
            value = ch.decode(f)[signal]
    return value


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:
        if "CAN1" not in net.channels.keys():
            fail("the project has no channel CAN1; this example expects sim-demo's")
        can1 = net.channels.CAN1
        powertrain, brake = can1.messages.Powertrain, can1.messages.BrakeStatus

        print("drop: Powertrain for 1000 ms; its frames per 250 ms window:")
        net.fault(can1, "SUT", powertrain, FaultKind.DROP, ms=1000)
        windows = [count(can1, powertrain.id, 0.25) for _ in range(8)]
        print("  " + " ".join(str(n) for n in windows))
        if 0 not in windows[:4]:
            fail("Powertrain went on arriving while it was dropped")
        if windows[-1] == 0:
            fail("Powertrain did not come back when the fault's time was up")

        pedal = brake.signals.BrakePedal
        print(f"out_of_range: BrakePedal is declared {pedal.minimum:g}..{pedal.maximum:g}")
        before = last_value(can1, brake, "BrakePedal", 0.3)
        net.fault(can1, "ChassisECU", brake, FaultKind.OUT_OF_RANGE, signal=pedal)
        during = last_value(can1, brake, "BrakePedal", 0.3)
        net.clear_fault(can1, "ChassisECU", brake)
        after = last_value(can1, brake, "BrakePedal", 0.3)
        print(f"  before {before}, during {during}, after the clear {after}")
        if during is None or during <= pedal.maximum:
            fail(f"BrakePedal was {during} under out_of_range, inside its declared range")
        if after is None or after > pedal.maximum:
            fail(f"BrakePedal was {after} after the clear")

        try:
            net.fault(can1, "SUT", powertrain, FaultKind.BAD_CRC)
            fail("bad_crc was armed on a message with no checksum")
        except blobly.FaultRefused as e:
            print(f"bad_crc refused: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
