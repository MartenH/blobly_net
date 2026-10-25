"""Network management from a script: who reports in on a CAN bus's NM cluster and who keeps the
network awake, followed through a wake-up, a release and a sleep.

On projects/nm-demo (its recording replayed at 4x onto an in-process bus; the system.toml beside it
declares sysnode, domain and zone_a on bus `body`): sysnode wakes the bus and domain joins, domain
then sysnode become ready to sleep, the bus releases and sleeps, and domain wakes it again with a
partial-network request. zone_a is declared and never reports.

    python nm_monitor.py [project.blobnet [channel]]

Exits 0 when every step reads as it should, and 1 with a FAIL line otherwise."""
import os
import sys
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

PROJECT = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "nm-demo", "nm-demo.blobnet"))


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def show(r: blobly.NmReading) -> None:
    keepers = ", ".join(r.kept_awake_by) or "nobody"
    print(f"{r.state:9}  kept awake by {keepers}; woken by {r.woken_by}")


def main(argv: list[str]) -> int:
    project = argv[0] if argv else PROJECT
    if not os.path.isfile(project):
        fail(f"no project at {project}; pass the path of a .blobnet file")
    sys.stdout.reconfigure(line_buffering=True)
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(project) as net:
        ch = net.channels[argv[1]] if len(argv) > 1 else net.channels[0]
        nm = ch.nm()
        first = nm.reading()
        print(f"{ch.name}: {first.cluster}, from {first.origin}, timeout {first.timeout_ms} ms")
        with net.replay(ch, speed=4, loop=False):
            try:
                r = nm.expect_state("awake", 3000, kept_awake_by=["sysnode", "domain"])
                show(r)
                for n in r.nodes:
                    heard = "never heard" if n.missing else f"NID 0x{n.nid:02X} on 0x{n.can_id:03X}"
                    print(f"  {n.name:8} {heard}")
                show(nm.expect_state("awake", 8000, kept_awake_by=["sysnode"]))
                show(nm.expect_state("releasing", 8000))
                show(nm.expect_asleep(4000))
                r = nm.expect_state("awake", 6000)
                show(r)
            except blobly.Timeout as e:
                fail(str(e))
        domain = r.node("domain")
        if r.woken_by != "domain" or domain is None or domain.pn is None:
            fail(f"domain did not wake the bus with a PN request: {r}")
        print(f"domain asks for partial networks 0x{domain.pn:X}; missing: {', '.join(r.missing)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
