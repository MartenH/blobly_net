"""A rest bus from the database alone: every node but the ECU under test, played from the DBC.

projects/restbus-db.blobnet simulates BodyECU, ChassisECU and BatteryECU with one line,
`simulate: [BodyECU, ChassisECU, BatteryECU]`, and leaves out SUT (the ECU under test) and Tester
(the role this script plays). This script:
  - receives each simulated node's messages and prints the cycle it measures beside the DBC's;
  - checks that none of SUT's messages is on the bus, which holds with no ECU attached (as here);
  - holds BrakePedal of ChassisECU's BrakeStatus at 80 % and sees it on the wire, then lets go;
  - drops WheelSpeeds with a fault and sees it stop and come back when cleared.

    python rest_bus.py [project.blobnet] [--seconds 1.5]

The project defaults to the repository's projects/restbus-db.blobnet; another needs its CAN1 and
nodes. Exits 0 when each check held, and 1 with a FAIL line otherwise."""
import argparse
import os
import sys
import time
from typing import NoReturn
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly (the repository root's blobly/ is the V
# engine's source, which Python would take for a namespace package)
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402
from blobly import FaultKind  # noqa: E402

RESTBUS_DB = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "restbus-db.blobnet"))

# what the rest bus sends: message -> its simulated sender
REST = {"BodyStatus": "BodyECU", "WheelSpeeds": "ChassisECU", "BrakeStatus": "ChassisECU",
        "BatteryStatus": "BatteryECU"}
SUT = ("Powertrain", "Heartbeat", "Response")  # the ECU under test's, which nothing here sends


def fail(why: str) -> NoReturn:
    sys.exit(f"FAIL: {why}")


def listen(ch: blobly.Channel, seconds: float) -> dict[int, list[float]]:
    """The receive times of every frame on `ch` in the next `seconds`, per id."""
    seen: dict[int, list[float]] = {}
    end = time.monotonic() + seconds
    while (left := end - time.monotonic()) > 0:
        f = ch.recv(left * 1000)
        if f is not None:
            seen.setdefault(f.id, []).append(f.t_ms)
    return seen


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=RESTBUS_DB, help="a .blobnet project (default: restbus-db)")
    ap.add_argument("--seconds", type=float, default=1.5, help="how long to measure the cycles (default 1.5)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:
        if "CAN1" not in net.channels.keys():
            fail("the project has no channel CAN1; this example expects restbus-db's")
        can1 = net.channels.CAN1
        net.wait_ready(5000)  # start() returns before the simulated nodes have opened their bus
        msgs = can1.messages
        can1.expect(msgs.WheelSpeeds, 2000)  # the rest bus is up

        print(f"the rest bus over {args.seconds:g} s:")
        seen = listen(can1, args.seconds)
        for name, node in REST.items():
            m = msgs[name]
            t = seen.get(m.id, [])
            if len(t) < 2:
                fail(f"{name} (0x{m.id:X}) from {node}: {len(t)} frame(s) in {args.seconds:g} s")
            mean = (t[-1] - t[0]) / (len(t) - 1)
            print(f"  {name:13} 0x{m.id:03X} from {node:10} every {mean:6.1f} ms (DBC: {m.cycle_ms} ms)")
            if m.cycle_ms and not 0.75 * m.cycle_ms <= mean <= 1.25 * m.cycle_ms:
                fail(f"{name} came every {mean:.1f} ms, its DBC cycle is {m.cycle_ms} ms")
        sent = [name for name in SUT if msgs[name].id in seen]
        if sent:
            fail(f"heard the ECU under test's {', '.join(sent)}; this check expects no ECU attached")
        print(f"  nothing of SUT's (no ECU attached): {', '.join(SUT)}")

        brake = msgs.BrakeStatus
        net.set_signal(can1, "ChassisECU", brake, "BrakePedal", 80)
        _, pedal = can1.expect_signal(brake, "BrakePedal", 80, 1000)
        print(f"set: BrakePedal = {pedal:g} %")
        net.clear_signal(can1, "ChassisECU", brake, "BrakePedal")
        _, pedal = can1.expect_signal(brake, "BrakePedal", 0, 1000)
        print(f"cleared: BrakePedal = {pedal:g} % (its start value)")

        wheels = msgs.WheelSpeeds
        net.fault(can1, "ChassisECU", wheels, FaultKind.DROP)
        net.wait(100)  # the simulation takes it up on its next pass; what was queued is read away
        during = listen(can1, 0.4)
        if wheels.id in during:
            fail("WheelSpeeds went on arriving while it was dropped")
        if brake.id not in during:
            fail("BrakeStatus, from the same node, stopped too")
        print("drop: WheelSpeeds silent for 400 ms, BrakeStatus still arriving")
        net.clear_fault(can1, "ChassisECU", wheels)
        can1.expect(wheels, 1000)
        print("cleared: WheelSpeeds back")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
