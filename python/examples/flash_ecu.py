"""Flashing a blobly_emb bootloader: the download session (programming session, 0x29
authentication, erase, transfer, the check routine, reset) with a progress bar, and its report.

Starts the project and, unless --board is given, a simulated bootloader on the channel — strict
where a real one is: it verifies the 0x29 proof against the dev tester key and checks the image's
CRC before it marks it valid — so the example runs with no hardware. With --board the bootloader
is a real one on the channel (a blobly_emb board in its boot manager, on 0x7B0 / 0x7B8).

    python flash_ecu.py [project.blobnet] [--channel NAME] [--image FILE] [--board]

The project defaults to the repository's projects/sim-demo.blobnet, the channel to CAN1, the image
to 20 kB of test bytes (a raw image: the session adds its header). Exits 0 when the image was
verified and marked valid, and 1 with a FAIL line otherwise."""
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
from blobly import flash  # noqa: E402

SIM_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "sim-demo.blobnet"))


def fail(why: str) -> None:
    sys.exit(f"FAIL: {why}")


def quarters():
    """A progress callback printing a bar at each quarter of the transfer (it is called at each
    whole percent)."""
    shown = [-1]

    def show(done: int, total: int) -> None:
        q = done * 4 // total
        if q != shown[0]:
            shown[0] = q
            print(f"  [{'#' * (q * 10)}{'.' * (40 - q * 10)}] {done}/{total} blocks")
    return show


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    ap.add_argument("--channel", default="CAN1", help="the channel the bootloader is on (default: CAN1)")
    ap.add_argument("--image", help="the image: a raw .bin or a BLBT .img (default: 20 kB of test bytes)")
    ap.add_argument("--board", action="store_true", help="flash a real bootloader: start no simulated one")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")
    image = args.image or bytes(i * 31 & 0xFF for i in range(20_000))

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()  # loads the library, on the main thread
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:  # loaded and started; stopped when the block ends
        if args.channel not in net.channels.keys():
            fail(f"no enabled channel named {args.channel!r}; there are: {', '.join(net.channels.keys())}")
        ch = net.channels[args.channel]
        boot = None if args.board else flash.BootSim(ch)  # stands in for the board
        try:
            report = flash.program(ch, image, sw_version=2, progress=quarters())
        except blobly.BloblyError as e:  # a step refused or unanswered, or the session's own verdict
            fail(f"the flash: {e}")
        finally:
            asked = boot.stop() if boot else None
        print(f"flashed {report.bytes} bytes in {report.blocks} blocks, 0x29 {report.auth}, "
              f"reset {'acknowledged' if report.reset_acknowledged else 'sent'}")
        if asked is not None:
            print(f"the bootloader verified the image: {asked.verified} ({asked.bytes} bytes, {asked.erases} erase)")
            if not asked.verified:
                fail("the simulated bootloader did not verify the image")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
