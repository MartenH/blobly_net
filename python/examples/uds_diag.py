"""UDS diagnostics over CAN: a session, DID reads, a refused request, a security unlock, and the
fault memory with a snapshot.

Starts the project, which brings its simulated ECUs up inside this process, and talks to one of
them over UDS (ISO 14229) on ISO-TP: switches to the default session, reads the VIN (17 bytes, a
multi-frame answer), the serial number and the software version, shows how long the last exchange
took, asks for a DID the ECU does not have and catches the negative response, unlocks security
level 1 with blobly_net's reference key and asks again (an all-zero seed: unlocked), then reads the
DTCs with their status bits, and the snapshot and extended data of each DTC that stored one.

    python uds_diag.py [project.blobnet] [--channel NAME] [--tx ID] [--rx ID]

The project defaults to the repository's projects/sim-demo.blobnet, whose CAN2 runs the built-in
UDS server on 0x7E0 / 0x7E8 (the defaults here too), the one that stores a snapshot. Exits 0 when
every check held, and 1 with a FAIL line otherwise."""
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

SIM_DEMO = os.path.normpath(os.path.join(HERE, os.pardir, os.pardir, "projects", "sim-demo.blobnet"))
VIN, SERIAL, SW_VERSION = 0xF190, 0xF18C, 0xF195
NO_SUCH_DID = 0xABCD


def fail(why: str) -> NoReturn:
    sys.exit(f"FAIL: {why}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("project", nargs="?", default=SIM_DEMO, help="a .blobnet project (default: sim-demo)")
    ap.add_argument("--channel", default="CAN2", help="the CAN channel the ECU is on (default: CAN2)")
    ap.add_argument("--tx", type=lambda s: int(s, 0), default=0x7E0, help="the request id (default: 0x7E0)")
    ap.add_argument("--rx", type=lambda s: int(s, 0), default=0x7E8, help="the response id (default: 0x7E8)")
    args = ap.parse_args(argv)
    if not os.path.isfile(args.project):
        fail(f"no project at {args.project}; pass the path of a .blobnet file")

    sys.stdout.reconfigure(line_buffering=True)  # in order with the engine's own lines
    blobly.init()  # loads the library, on the main thread
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")
    with blobly.Project(args.project) as net:  # loaded and started; stopped when the block ends
        if args.channel not in net.channels.keys():
            fail(f"no enabled channel named {args.channel!r}; there are: {', '.join(net.channels.keys())}")
        with net.channels[args.channel].uds(tx=args.tx, rx=args.rx) as diag:  # closed when the block ends
            print(f"UDS on {args.channel}, requests on 0x{diag.tx:X}, answers on 0x{diag.rx:X}")

            record = diag.session(0x01)  # 0x10: the session, then its timing record
            print(f"default session: {record.hex(' ').upper()}")

            vin = diag.read_did(VIN)  # 0x22; 17 bytes come back over several CAN frames
            print(f"VIN {vin.decode('ascii', 'replace')}, "
                  f"in {diag.last.rtt_us} us")  # diag.last: the timing of the last exchange
            print(f"serial number {diag.read_did(SERIAL).decode('ascii', 'replace')}, "
                  f"software version {diag.read_did(SW_VERSION).hex(' ').upper()}")

            try:
                diag.read_did(NO_SUCH_DID)
                fail(f"DID 0x{NO_SUCH_DID:04X} was answered; the ECU should not have it")
            except blobly.NegativeResponse as e:  # a typed error, carrying the NRC
                print(f"DID 0x{NO_SUCH_DID:04X}: NRC 0x{e.nrc:02X} {e.nrc_name}")

            seed = diag.security_access(0x01)  # 0x27 01 / 02 with the reference key
            print(f"level 1 unlocked, seed {seed.hex(' ').upper()}")
            again = diag.security_access(0x01)
            if any(again):
                fail(f"a second seed request answered {again.hex(' ').upper()}, not all zeros")
            print("asked again: an all-zero seed, already unlocked, no key sent")

            dtcs = diag.supported_dtcs()  # 0x19 0A: every DTC, each with its whole status
            print(f"{len(dtcs)} DTC(s):")
            for d in dtcs:
                on = [name for name, set_ in d.bits.items() if set_]  # the bits the ECU reports
                print(f"  {d.name} status 0x{d.status:02X} {', '.join(on) or '(none set)'}")
            stored = diag.snapshot_ids()  # 0x19 03: which DTCs hold a snapshot
            if not stored:
                fail("no DTC holds a snapshot; sim-demo's CAN2 server stores one for P1234-56")
            for s in stored:
                snap = diag.snapshot(s.code, s.record)  # 0x19 04; each DID's size learned by reading it
                for rec in snap.records:
                    values = ", ".join(f"0x{did:04X} = {v.hex(' ').upper()}" for did, v in rec.dids.items())
                    print(f"  {s.name} snapshot {rec.number}: {values}")
                ext = diag.extended(s.code)  # 0x19 06: blobly_emb's counters
                print(f"  {s.name} occurred {ext.occurrence} time(s), aging {ext.aging}, "
                      f"failed cycles {ext.failed_cycles}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
