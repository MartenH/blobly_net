"""LIN from a script: a project's LIN bus read and decoded through its LDF, a signal a simulated node
publishes changed, the schedule switched, and the bus put to sleep and woken.

On projects/lin-demo (BODY: an in-process LIN bus, this process its master simulating CEM, LSM and
RSM on the NormalTable schedule of dbc/lin_demo.ldf).

    python lin_monitor.py [project.blobnet [lin-bus]]

Exits 0 when every step reads as it should, and 1 with a FAIL line otherwise."""
import os
import sys
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

PROJECT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "lin-demo.blobnet"))


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def show(f: blobly.LinFrame) -> None:
    print(f"  {f.origin:4} 0x{f.id:02X} {f.name:9} {f.data.hex(' '):23}  {f.signals}")


def main(argv: list[str]) -> int:
    project = argv[0] if argv else PROJECT
    if not os.path.isfile(project):
        fail(f"no project at {project}; pass the path of a .blobnet file")
    sys.stdout.reconfigure(line_buffering=True)
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(project) as net:
        if not net.lin:
            fail(f"{project} has no LIN bus")
        bus = net.lin[argv[1]] if len(argv) > 1 else net.lin[0]
        print(f"{bus.name}: {bus.address} at {bus.baud} baud, {bus.role}, LDF {bus.ldf}")
        try:
            print("one schedule round:")
            for name in ("CEM_Frm1", "CEM_Frm2", "LSM_Frm2", "RSM_Frm2"):
                show(bus.expect(name, 500))
            bus.set("IntTest", "passed")
            f = bus.expect("LSM_Frm2", 500)
            for _ in range(10):  # LSM sends what it was set to from its next response
                if f.raw["IntTest"] == 2:
                    break
                f = bus.expect("LSM_Frm2", 500)
            if f.raw["IntTest"] != 2:
                fail(f"LSM did not send IntTest passed: {f}")
            print("IntTest set to passed:")
            show(f)
            bus.schedule("FastTable")
            print("on FastTable:")
            show(bus.expect("RSM_Frm3", 500))
            bus.stop_schedule()
            bus.sleep()
            bus.expect(0x3C, 500)
            print(f"after go-to-sleep the bus is {bus.status().state}")
            bus.wakeup()
            w = bus.recv(500)
            for _ in range(20):  # a frame still queued from before the sleep comes first
                if w is None or w.event == "wakeup":
                    break
                w = bus.recv(500)
            if w is None or w.event != "wakeup":
                fail("no wakeup read back")
            bus.schedule("NormalTable")
            bus.expect("CEM_Frm1", 500)
        except blobly.Timeout as e:
            fail(str(e))
        st = bus.status()
        if st.state != "active" or st.frames[0x01].errors:
            fail(f"the bus did not come back clean: {st}")
        print(f"woken, {st.state}; {len(st.frames)} ids seen, CEM_Frm1 {st.frames[0x01].count} times")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
