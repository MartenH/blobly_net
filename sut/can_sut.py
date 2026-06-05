#!/usr/bin/env python3
"""Virtual CAN SUT (System Under Test) for cantester.

A stand-in ECU. It:
  - transmits a periodic Powertrain frame (0x100) with encoded signals, using the
    SAME bit layout the V `candb` module decodes — so the two independent
    implementations cross-validate each other;
  - transmits a rolling heartbeat counter (0x700);
  - answers a request (0x101) with a response (0x102, first byte + 1).

Two transports (stdlib only, no third-party deps):
  - SocketCAN raw on Linux (vcan0) — `python3 sut/can_sut.py vcan0`
  - cross-platform UDP-multicast software bus matching V's `transport/udpbus.v`
    (the vcan stand-in for Windows) — `python3 sut/can_sut.py udp[:group[:port]]`

Run:  python3 sut/can_sut.py [iface]   (default vcan0)
"""
import math
import random
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


# --- transports: same send/recv(timeout)/close contract, two backends --------

class SocketCanBus:
    """Linux SocketCAN raw socket (vcan0/can0)."""

    def __init__(self, iface: str):
        self.s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
        self.s.bind((iface,))

    def send(self, cid: int, data: bytes, extended: bool = False) -> None:
        flags = CAN_EFF_FLAG if (extended or cid > CAN_SFF_MASK) else 0
        mask = CAN_EFF_MASK if flags else CAN_SFF_MASK
        self.s.send(struct.pack(CAN_FRAME_FMT, (cid & mask) | flags, len(data),
                                bytes(data).ljust(8, b"\x00")))

    def recv(self, timeout: float):
        r, _, _ = select.select([self.s], [], [], max(0.0, timeout))
        if not r:
            return None
        can_id, dlc, data = struct.unpack(CAN_FRAME_FMT, self.s.recv(FRAME_SIZE))
        ext = bool(can_id & CAN_EFF_FLAG)
        return can_id & (CAN_EFF_MASK if ext else CAN_SFF_MASK), ext, data[:dlc]

    def close(self) -> None:
        self.s.close()


class UdpBus:
    """Cross-platform UDP-multicast software bus matching V transport/udpbus.v.

    Wire format (little-endian): [src u32][id u32][flags u8][dlc u8][data 0..8];
    flags bit0=extended, bit1=rtr. A per-instance src id filters our own echoes
    (multicast loopback is on so same-host peers receive each other)."""

    DEFAULT_GROUP = "239.63.42.1"
    DEFAULT_PORT = 20000
    _HDR = struct.Struct("<IIBB")

    def __init__(self, group: str, port: int):
        self.group, self.port = group, port
        self.src = random.getrandbits(32)
        self.rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        self.rx.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.rx.bind(("", port))
        mreq = struct.pack("4sl", socket.inet_aton(group), socket.INADDR_ANY)
        self.rx.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
        self.tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        self.tx.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
        self.tx.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)

    def send(self, cid: int, data: bytes, extended: bool = False) -> None:
        flags = (0x01 if (extended or cid > CAN_SFF_MASK) else 0)
        pkt = self._HDR.pack(self.src, cid & CAN_EFF_MASK, flags, len(data)) + bytes(data)
        self.tx.sendto(pkt, (self.group, self.port))

    def recv(self, timeout: float):
        r, _, _ = select.select([self.rx], [], [], max(0.0, timeout))
        if not r:
            return None
        pkt, _ = self.rx.recvfrom(64)
        if len(pkt) < self._HDR.size:
            return None
        src, cid, flags, dlc = self._HDR.unpack(pkt[:self._HDR.size])
        if src == self.src:
            return None  # our own frame echoed back
        return cid, bool(flags & 0x01), pkt[self._HDR.size:self._HDR.size + dlc]

    def close(self) -> None:
        self.rx.close()
        self.tx.close()


def open_bus(iface: str):
    """vcan0/can0 -> SocketCAN; udp[:group[:port]] -> UDP software bus."""
    if iface == "udp" or iface.startswith("udp:"):
        group, port = UdpBus.DEFAULT_GROUP, UdpBus.DEFAULT_PORT
        if iface.startswith("udp:"):
            parts = iface[4:].split(":")
            if parts and parts[0]:
                group = parts[0]
            if len(parts) > 1 and parts[1]:
                port = int(parts[1])
        return UdpBus(group, port)
    return SocketCanBus(iface)


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
    bus = open_bus(iface)
    print(f"[sut] virtual ECU on {iface}: "
          f"TX 0x{POWERTRAIN_ID:X}@{int(1 / PERIOD_S)}Hz + heartbeat 0x{HEARTBEAT_ID:X}, "
          f"responds 0x{REQUEST_ID:X}->0x{RESPONSE_ID:X}", flush=True)
    t0 = time.monotonic()
    next_tx = t0
    hb = 0
    try:
        while True:
            now = time.monotonic()
            frame = bus.recv(next_tx - now)
            if frame:
                cid, _ext, data = frame
                if cid == REQUEST_ID:
                    resp = bytearray(data)
                    if resp:
                        resp[0] = (resp[0] + 1) & 0xFF
                    bus.send(RESPONSE_ID, bytes(resp))
                    print(f"[sut] req 0x{cid:X} {data.hex()} -> "
                          f"resp 0x{RESPONSE_ID:X} {bytes(resp).hex()}", flush=True)
            now = time.monotonic()
            if now >= next_tx:
                t = now - t0
                bus.send(POWERTRAIN_ID, encode_powertrain(t))
                bus.send(HEARTBEAT_ID, bytes([hb & 0xFF]))
                hb += 1
                next_tx += PERIOD_S
                if next_tx < now:
                    next_tx = now + PERIOD_S
    except KeyboardInterrupt:
        print("\n[sut] bye")
    finally:
        bus.close()


if __name__ == "__main__":
    main()
