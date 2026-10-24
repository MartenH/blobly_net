"""Replay and recording: a recording played onto a channel, driven, and the channel recorded.

On replay-demo's REPLAY1, which replays samples/demo.log (Powertrain 0x100 and Heartbeat 0x700 at
10 Hz for 2.9 s):
  - the wire is recorded to a candump .log while the replay runs;
  - the replay starts paused, is moved to 1.5 s into the recording, played at 4x once to its end,
    and its status printed;
  - the recording is read back: every line a frame this process sent, so each ends with T.

    python replay_record.py [project.blobnet] [--out capture.log]

The project defaults to the repository's projects/replay-demo.blobnet; another needs a channel
REPLAY1 with a replay: block. Exits 0 when the replay and the recording agree, and 1 with a FAIL
line otherwise."""
import argparse
import os
import sys
import tempfile
from typing import NoReturn
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
# an installed blobly, else this checkout's python/blobly (the repository root's blobly/ is the V
# engine's source, which Python would take for a namespace package)
if getattr(find_spec("blobly"), "origin", None) is None:
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

REPLAY_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "replay-demo.blobnet"))


def fail(why: str) -> NoReturn:
    sys.exit(f"FAIL: {why}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=REPLAY_DEMO, help="a .blobnet project (default: replay-demo)")
    ap.add_argument("--out", help="where the recording goes (default: a temporary file, removed after)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")
    out = args.out or os.path.join(tempfile.mkdtemp(), "capture.log")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:
        if "REPLAY1" not in net.channels.keys():
            fail("the project has no channel REPLAY1; this example expects replay-demo's")
        ch = net.channels.REPLAY1
        with net.record(out, ch) as rec:
            with net.replay(ch, paused=True, loop=False) as r:
                print("plan: " + "; ".join(r.notes))
                r.seek(1.5)
                r.set_speed(4)
                r.resume()
                if not r.wait_done(5000):
                    fail("the replay did not run out within 5 s")
                st = r.status()
                print(f"replay: {st.state} at {st.position_s:.2f} of {st.duration_s:.2f} s, "
                      f"{st.sent} sent, {st.failed} failed")
        c = rec.counts()
    print(f"recorded {c.frames} frames to {out}: {c.ours} ours, {c.theirs} theirs")
    with open(out, encoding="utf-8") as f:
        lines = f.read().splitlines()
    for line in lines[:3]:
        print("  " + line)
    if st.sent != c.frames or len(lines) != c.frames:
        fail(f"{st.sent} sent but {c.frames} recorded and {len(lines)} lines in the file")
    if not all(line.endswith(" T") for line in lines):
        fail("a frame the replay sent was not recorded as ours")
    if args.out is None:
        os.remove(out)
        os.rmdir(os.path.dirname(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
