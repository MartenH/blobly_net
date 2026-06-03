#!/usr/bin/env python3
"""Virtual CAN SUT (System Under Test) for cantester.

A stand-in ECU on a SocketCAN bus (vcan0). It:
  - transmits a periodic Powertrain frame (0x100) with encoded signals, using the
    SAME bit layout the V `candb` module decodes — so the two independent
    implementations cross-validate each other;
  - transmits a rolling heartbeat counter (0x700);
  - answers a request (0x101) with a response (0x102, first byte + 1).

Stdlib only (raw AF_CAN socket) — no third-party deps. This is the "virtual"
side of "connect to a SUT, virtual to start with"; a real ECU on real hardware
replaces it later with no change to the V tester.

Run:  python3 sut/can_sut.py [iface]   (default vcan0; needs vcan0 already up)
"""
import math
import select
import socket
import struct
import sys
import time

CAN_FRAME_FMT = "=IB3x8s"               # id(4) dlc(1) pad(3) data(8) = 16 bytes
FRAME_SIZE = struct.calcsize(CAN_FRAME_FMT)
CAN_EFF_FLAG = 0x80000000
CAN_RTR_FLAG = 0x40000000
CAN_SFF_MASK = 0x000007FF
CAN_EFF_MASK = 0x1FFFFFFF

POWERTRAIN_ID = 0x100
HEARTBEAT_ID = 0x700
REQUEST_ID = 0x101
RESPONSE_ID = 0x102
PERIOD_S = 0.1                          # 10 Hz periodic TX


def open_can(iface: str) -> socket.socket:
    s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    s.bind((iface,))
    return s


def pack(can_id: int, data: bytes, extended: bool = False) -> bytes:
    flags = CAN_EFF_FLAG if (extended or can_id > CAN_SFF_MASK) else 0
    mask = CAN_EFF_MASK if flags else CAN_SFF_MASK
    return struct.pack(CAN_FRAME_FMT, (can_id & mask) | flags, len(data),
                       bytes(data).ljust(8, b"\x00"))


def unpack(buf: bytes):
    can_id, dlc, data = struct.unpack(CAN_FRAME_FMT, buf)
    extended = bool(can_id & CAN_EFF_FLAG)
    cid = can_id & (CAN_EFF_MASK if extended else CAN_SFF_MASK)
    return cid, extended, data[:dlc]


def set_signal(data: bytearray, start_bit: int, length: int, raw: int) -> None:
    """Intel/little-endian bit packing — independent of the V implementation."""
    raw &= (1 << length) - 1
    for i in range(length):
        g = start_bit + i
        if (raw >> i) & 1:
            data[g // 8] |= (1 << (g % 8))
        else:
            data[g // 8] &= ~(1 << (g % 8))


def encode_powertrain(t: float) -> bytes:
    data = bytearray(8)
    eng = 1600 + 1500 * math.sin(0.7 * t)          # rpm,  factor 0.25
    veh = 70 + 60 * math.sin(0.9 * t + 1)          # km/h, factor 0.1
    cool = 90 + 15 * math.sin(1.1 * t + 2)         # degC, offset -40
    thr = 45 + 45 * math.sin(1.3 * t + 3)          # %
    gear = (int(t) % 6) + 1
    cruise = int(t * 0.5) % 2
    set_signal(data, 0, 16, round(eng / 0.25))
    set_signal(data, 16, 12, round(veh / 0.1))
    set_signal(data, 28, 8, round(cool + 40))
    set_signal(data, 36, 7, round(thr))
    set_signal(data, 43, 4, gear)
    set_signal(data, 47, 1, cruise)
    return bytes(data)


def main() -> None:
    iface = sys.argv[1] if len(sys.argv) > 1 else "vcan0"
    s = open_can(iface)
    print(f"[sut] virtual ECU on {iface}: "
          f"TX 0x{POWERTRAIN_ID:X}@{int(1 / PERIOD_S)}Hz + heartbeat 0x{HEARTBEAT_ID:X}, "
          f"responds 0x{REQUEST_ID:X}->0x{RESPONSE_ID:X}", flush=True)
    t0 = time.monotonic()
    next_tx = t0
    hb = 0
    try:
        while True:
            now = time.monotonic()
            r, _, _ = select.select([s], [], [], max(0.0, next_tx - now))
            if r:
                cid, _ext, data = unpack(s.recv(FRAME_SIZE))
                if cid == REQUEST_ID:
                    resp = bytearray(data)
                    if resp:
                        resp[0] = (resp[0] + 1) & 0xFF
                    s.send(pack(RESPONSE_ID, bytes(resp)))
                    print(f"[sut] req 0x{cid:X} {data.hex()} -> "
                          f"resp 0x{RESPONSE_ID:X} {bytes(resp).hex()}", flush=True)
            now = time.monotonic()
            if now >= next_tx:
                t = now - t0
                s.send(pack(POWERTRAIN_ID, encode_powertrain(t)))
                s.send(pack(HEARTBEAT_ID, bytes([hb & 0xFF])))
                hb += 1
                next_tx += PERIOD_S
                if next_tx < now:
                    next_tx = now + PERIOD_S
    except KeyboardInterrupt:
        print("\n[sut] bye")
    finally:
        s.close()


if __name__ == "__main__":
    main()
