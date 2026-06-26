#!/usr/bin/env python3
"""Virtual UDS (ISO 14229) server for the SUT — the verification oracle for the V
`uds` client.

Runs on a kernel ISO-TP socket (stdlib only: socket.CAN_ISOTP), so no can-isotp /
udsoncan third-party deps — the kernel does segmentation. Implements the handful
of services the V client speaks:

  0x10 DiagnosticSessionControl  -> 0x50 <session> <P2 timings>
  0x22 ReadDataByIdentifier      -> 0x62 <did> <data>   (table below)
  0x3E TesterPresent             -> 0x7E 0x00
  anything else                  -> 0x7F <sid> 0x11 (serviceNotSupported)
  unknown DID                    -> 0x7F 0x22 0x31 (requestOutOfRange)

Addressing (OBD/UDS convention): tester sends to 0x7E0, ECU replies on 0x7E8.
So this server binds rx=0x7E0, tx=0x7E8.

Run:  python3 sut/uds_server.py [iface]   (default vcan0; vcan0 must be up)
"""
import socket
import struct
import sys

CAN_ISOTP = getattr(socket, "CAN_ISOTP", 6)
REQUEST_ID = 0x7E0   # tester -> ECU
RESPONSE_ID = 0x7E8  # ECU -> tester

# ReadDataByIdentifier table: DID -> data bytes.
DIDS = {
    0xF190: b"BLOBLYNETV0SUT001",            # VIN (17 chars, forces multi-frame)
    0xF18C: b"SN-0001",                       # ECU serial number
    0xF195: bytes([0x01, 0x00]),              # software version 1.00
    0x0100: struct.pack(">H", 6400),          # EngineSpeed raw (0.25 rpm/bit -> 1600 rpm)
}

# Negative response codes.
NRC_SERVICE_NOT_SUPPORTED = 0x11
NRC_REQUEST_OUT_OF_RANGE = 0x31


def handle(req: bytes) -> bytes:
    if not req:
        return b""
    sid = req[0]
    if sid == 0x10:  # DiagnosticSessionControl
        session = req[1] if len(req) > 1 else 0x01
        # 0x50 <session> <P2_max(2)> <P2*_max(2)>  (default timings)
        return bytes([0x50, session, 0x00, 0x32, 0x01, 0xF4])
    if sid == 0x22:  # ReadDataByIdentifier
        if len(req) < 3:
            return bytes([0x7F, sid, 0x13])  # invalid length
        did = (req[1] << 8) | req[2]
        if did in DIDS:
            return bytes([0x62, req[1], req[2]]) + DIDS[did]
        return bytes([0x7F, sid, NRC_REQUEST_OUT_OF_RANGE])
    if sid == 0x3E:  # TesterPresent
        return bytes([0x7E, 0x00])
    return bytes([0x7F, sid, NRC_SERVICE_NOT_SUPPORTED])


def main() -> None:
    iface = sys.argv[1] if len(sys.argv) > 1 else "vcan0"
    s = socket.socket(socket.AF_CAN, socket.SOCK_DGRAM, CAN_ISOTP)
    s.bind((iface, REQUEST_ID, RESPONSE_ID))  # (iface, rx, tx)
    print(f"[uds] server on {iface}: rx 0x{REQUEST_ID:X} tx 0x{RESPONSE_ID:X}; "
          f"DIDs {[f'0x{d:04X}' for d in DIDS]}", flush=True)
    try:
        while True:
            req = s.recv(4096)
            resp = handle(req)
            if resp:
                s.send(resp)
                print(f"[uds] {req.hex()} -> {resp.hex()}", flush=True)
    except KeyboardInterrupt:
        print("\n[uds] bye")
    finally:
        s.close()


if __name__ == "__main__":
    main()
