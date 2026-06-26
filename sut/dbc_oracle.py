#!/usr/bin/env python3
"""Independent DBC parser + signal decoder — a verification oracle for the V
`candb` DBC implementation.

This is written from scratch against the DBC spec (NOT a port of the V code), so
agreement between the two is real cross-validation rather than a shared bug. It
deliberately uses only the Python stdlib (no cantools/python-can), matching the
SUT's "stdlib only" rule.

Usage:
  python3 sut/dbc_oracle.py decode <dbc> <id_hex> <data_hex>   # print decode
  python3 sut/dbc_oracle.py crosscheck [dbc] [n]               # diff vs V decoder
"""
import os
import random
import re
import struct
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DBC = os.path.join(REPO, "dbc", "blobly_net.dbc")

_SG_RE = re.compile(
    r"SG_\s+(\w+)\s*(?:\w+\s+)?:\s*"        # name (+ optional mux marker)
    r"(\d+)\|(\d+)@([01])([+-])\s*"          # start|len@order sign
    r"\(([^,]+),([^)]+)\)"                    # (factor,offset)
)
_BO_RE = re.compile(r"BO_\s+(\d+)\s+(\w+)\s*:\s*(\d+)")


def parse_dbc(path):
    """Return {msg_id: {'name','dlc','signals':[...]}}. Independent of the V code."""
    msgs, cur = {}, None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("BO_ "):
                m = _BO_RE.match(s)
                if not m:
                    continue
                mid = int(m.group(1)) & 0x1FFFFFFF
                cur = mid
                msgs[mid] = {"name": m.group(2), "dlc": int(m.group(3)), "signals": []}
            elif s.startswith("SG_ ") and cur is not None:
                m = _SG_RE.match(s)
                if not m:
                    continue
                name, start, length, order, sign, factor, offset = m.groups()
                msgs[cur]["signals"].append({
                    "name": name,
                    "start": int(start),
                    "length": int(length),
                    "byte_order": "little" if order == "1" else "big",
                    "signed": sign == "-",
                    "factor": float(factor),
                    "offset": float(offset),
                })
    return msgs


def raw_value(sig, data):
    raw = 0
    if sig["byte_order"] == "little":
        for i in range(sig["length"]):
            g = sig["start"] + i
            bidx, bit = g // 8, g % 8
            if bidx < len(data):
                raw |= ((data[bidx] >> bit) & 1) << i
    else:  # Motorola/big-endian sawtooth, MSB first
        pos = sig["start"]
        for _ in range(sig["length"]):
            bidx, bit = pos // 8, pos % 8
            raw = (raw << 1) | (((data[bidx] >> bit) & 1) if bidx < len(data) else 0)
            pos = pos + 15 if bit == 0 else pos - 1
    return raw


def physical(sig, data):
    raw = raw_value(sig, data)
    v = raw
    if sig["signed"] and 0 < sig["length"] < 64 and (raw >> (sig["length"] - 1)) & 1:
        v = raw - (1 << sig["length"])
    return v * sig["factor"] + sig["offset"]


def decode(msg, data):
    return [(s["name"], physical(s, data)) for s in msg["signals"]]


def build_v_decoder():
    v = os.path.expanduser("~/v/v")
    if not os.path.exists(v):
        v = "v"
    out = "/tmp/blobly_net_dbc_decode"
    subprocess.run(
        [v, "-path", "@vlib|@vmodules|modules", "-o", out,
         os.path.join("cmd", "dbc_decode", "decode.v")],
        cwd=REPO, check=True,
    )
    return out


def v_decode(binary, dbc, msg_id, data):
    res = subprocess.run(
        [binary, dbc, f"{msg_id:x}", data.hex()],
        capture_output=True, text=True, check=True,
    )
    out = {}
    for ln in res.stdout.splitlines():
        if "=" in ln:
            k, val = ln.split("=", 1)
            out[k] = val.strip()
    return out


def crosscheck(dbc, n):
    msgs = parse_dbc(dbc)
    binary = build_v_decoder()
    rnd = random.Random(0xC0FFEE)  # seeded -> reproducible
    checked = 0
    for mid, msg in msgs.items():
        for _ in range(n):
            data = bytes(rnd.getrandbits(8) for _ in range(msg["dlc"]))
            v_out = v_decode(binary, dbc, mid, data)
            for name, val in decode(msg, data):
                want = f"{val:.6f}"
                got = v_out.get(name)
                if got != want:
                    print(f"MISMATCH 0x{mid:X} {name} on {data.hex()}: "
                          f"python={want} v={got}")
                    return 1
                checked += 1
    print(f"OK: V and Python agree on {checked} signal decodes "
          f"across {len(msgs)} messages x {n} random frames each")
    return 0


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "decode":
        dbc, id_hex, data_hex = sys.argv[2], sys.argv[3], sys.argv[4]
        msgs = parse_dbc(dbc)
        msg = msgs[int(id_hex, 16) & 0x1FFFFFFF]
        for name, val in decode(msg, bytes.fromhex(data_hex)):
            print(f"{name}={val:.6f}")
        return 0
    if len(sys.argv) >= 2 and sys.argv[1] == "crosscheck":
        dbc = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_DBC
        n = int(sys.argv[3]) if len(sys.argv) > 3 else 200
        return crosscheck(dbc, n)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
