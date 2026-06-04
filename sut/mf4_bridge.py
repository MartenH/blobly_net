#!/usr/bin/env python3
"""MF4 <-> CAN bridge + semantic diff (dev tool, asammdf-backed).

Real CAN recordings ship as ASAM MDF4 (.mf4) — e.g. CANedge / CSS Electronics
logs — usually paired with a DBC. MF4 is a heavy binary container, so instead of
parsing it natively in V we bridge it here with the mature `asammdf` library:

  convert <in.mf4> <out.log> [iface]   extract CAN frames -> candump .log
  tomf4   <in.log> <out.mf4>           candump .log -> MF4 (python-can writer)
  frames  <in.mf4>                     print canonical frames (ts id[#]data)
  diff    <a.mf4> <b.mf4> [t_tol_ms]   SEMANTIC diff of two recordings

Why a semantic diff and not `cmp`: two MF4 files of identical traffic are never
byte-equal (start-time, file history, block offsets, zlib DZ blocks all vary).
So we compare the canonical frame stream — (id, extended, data) must match
exactly and in order; timestamps (normalised to start at 0) must match within a
tolerance, since replay/record adds scheduling jitter. That makes the round-trip
test "SUT replays an MF4, we record an MF4, diff == empty" actually meaningful.

Runs from the project's tools venv:  .venv-tools/bin/python sut/mf4_bridge.py ...
"""
import sys

try:
    from asammdf import MDF
except ImportError:
    sys.exit("asammdf not installed — use .venv-tools/bin/python (see CLAUDE.md)")


def extract_frames(mf4_path):
    """Return canonical frames [(t_rel, can_id, extended, bytes)], time-sorted,
    t_rel in seconds from the first frame. Reads the MDF bus-logging layout.

    CANedge MF4s split CAN frames across many data groups (one CAN_DataFrame per
    group), so we extract from every group that carries the channel."""
    m = MDF(mf4_path)
    frames = []
    for group, _index in m.channels_db.get("CAN_DataFrame.ID", []):
        ids = m.get("CAN_DataFrame.ID", group=group)
        ide = m.get("CAN_DataFrame.IDE", group=group)
        dlen = m.get("CAN_DataFrame.DataLength", group=group)
        data = m.get("CAN_DataFrame.DataBytes", group=group)
        ts = ids.timestamps
        for i in range(len(ts)):
            n = int(dlen.samples[i])
            row = data.samples[i]
            payload = bytes(int(b) for b in row[:n])
            frames.append((float(ts[i]), int(ids.samples[i]) & 0x1FFFFFFF,
                           bool(ide.samples[i]), payload))
    m.close()
    frames.sort(key=lambda f: f[0])
    if frames:
        t0 = frames[0][0]
        frames = [(t - t0, cid, ext, d) for (t, cid, ext, d) in frames]
    return frames


def frame_str(t, cid, ext, data):
    idhex = f"{cid:08X}" if ext else f"{cid:03X}"
    return f"({t:.6f}) {idhex}#{data.hex().upper()}"


def cmd_frames(mf4_path):
    for t, cid, ext, d in extract_frames(mf4_path):
        print(frame_str(t, cid, ext, d))


def cmd_convert(mf4_path, out_log, iface="vcan0"):
    frames = extract_frames(mf4_path)
    with open(out_log, "w") as fh:
        for t, cid, ext, d in frames:
            idhex = f"{cid:08X}" if ext else f"{cid:03X}"
            # candump -l style: (epoch.usec) iface id#data — relative epoch is fine
            fh.write(f"({t:.6f}) {iface} {idhex}#{d.hex().upper()}\n")
    print(f"wrote {len(frames)} frames -> {out_log}")


def cmd_diff(a_path, b_path, t_tol_ms=1.0):
    a = extract_frames(a_path)
    b = extract_frames(b_path)
    tol = t_tol_ms / 1000.0
    diffs = []
    if len(a) != len(b):
        diffs.append(f"frame count differs: {len(a)} vs {len(b)}")
    for i, (fa, fb) in enumerate(zip(a, b)):
        ta, ida, exta, da = fa
        tb, idb, extb, db = fb
        if (ida, exta, da) != (idb, extb, db):
            diffs.append(f"#{i}: {frame_str(*fa)}  !=  {frame_str(*fb)}")
        elif abs(ta - tb) > tol:
            diffs.append(f"#{i} timing: {ta:.6f}s vs {tb:.6f}s "
                         f"(>{t_tol_ms}ms) for 0x{ida:X}")
    if not diffs:
        print(f"OK: {len(a)} frames identical (ids+data exact, timing within "
              f"{t_tol_ms}ms)")
        return 0
    print(f"DIFF: {len(diffs)} difference(s):")
    for d in diffs[:40]:
        print("  ", d)
    if len(diffs) > 40:
        print(f"   ... and {len(diffs) - 40} more")
    return 1


def cmd_tomf4(in_log, out_mf4):
    """candump .log -> MF4 (asammdf bus-logging layout) via python-can's
    MF4Writer. Inverse of `convert`. Lets us mint a real MF4 from any candump
    capture we own (e.g. sut/can_sut.py traffic), so MF4 features can be demoed
    on non-J1939 data that decodes against dbc/cantester.dbc, and so the round
    trip log -> mf4 -> convert -> frames closes on traffic we control."""
    try:
        import can
        from can.io import MF4Writer
    except ImportError:
        sys.exit("python-can not installed — pip install python-can into "
                 ".venv-tools (see CLAUDE.md)")
    n = 0
    with MF4Writer(out_mf4) as writer:
        for msg in can.CanutilsLogReader(in_log):
            writer.on_message_received(msg)
            n += 1
    print(f"wrote {n} frames -> {out_mf4}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == "frames":
        cmd_frames(sys.argv[2])
    elif cmd == "convert":
        cmd_convert(sys.argv[2], sys.argv[3], *(sys.argv[4:5]))
    elif cmd == "tomf4":
        cmd_tomf4(sys.argv[2], sys.argv[3])
    elif cmd == "diff":
        tol = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
        return cmd_diff(sys.argv[2], sys.argv[3], tol)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
