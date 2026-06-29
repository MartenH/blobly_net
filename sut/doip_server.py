#!/usr/bin/env python3
"""Independent DoIP oracle (scapy) for the V `doip` module.

scapy's automotive stack is a third-party DoIP/UDS implementation, the same role
`uds_server.py` (stdlib ISO-TP) and `dbc_oracle.py` play for their modules. This
script drives our native V DoIP entity as a *client*: it does the routing-
activation handshake and UDS-over-DoIP exchanges with an independent stack, so if
our framing/addressing is wrong the handshake or decode breaks here.

Requires scapy (`.venv-doip/bin/python`, see scripts/setup_doip_oracle.sh).

Start the V entity first:
    v -enable-globals -path "@vlib|@vmodules|modules" run cmd/doip_smoke/smoke.v serve
Then:
    .venv-doip/bin/python sut/doip_server.py [host] [port]

Exit code 0 = all oracle checks passed (the V entity interoperates with scapy).
"""
import sys

from scapy.contrib.automotive.doip import UDS_DoIPSocket
from scapy.contrib.automotive.uds import UDS, UDS_DSC, UDS_RDBI

TESTER = 0x0E80
ECU = 0x1000
EXPECTED_VIN = b"BLOBLYNETV0SUT001"


def main() -> int:
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 13400

    # Connecting performs routing activation with an independent implementation —
    # if our 0x0005/0x0006 framing or response code is wrong, this raises.
    # UDS_DoIPSocket auto-wraps bare UDS() packets in DoIP diagnostic messages
    # (plain DoIPSocket would require building DoIP(payload_type=0x8001)/UDS()).
    sock = UDS_DoIPSocket(
        host, port=port, source_address=TESTER, target_address=ECU, doip_version=2
    )
    print(f"[oracle] routing activation OK (scapy ↔ V entity {host}:{port})")

    fails = 0

    # 1) DiagnosticSessionControl (extended, 0x03)
    resp = sock.sr1(UDS() / UDS_DSC(diagnosticSessionType=3), timeout=2, verbose=False)
    if resp is not None and resp.service == 0x50:
        print(f"[oracle] session 0x03 → 0x{resp.service:02X} ✓")
    else:
        print(f"[oracle] session 0x03 FAILED (resp={resp})")
        fails += 1

    # 2) ReadDataByIdentifier VIN (0xF190)
    resp = sock.sr1(UDS() / UDS_RDBI(identifiers=[0xF190]), timeout=2, verbose=False)
    if resp is not None and resp.service == 0x62:
        data = bytes(resp[UDS_RDBI].load) if resp.haslayer(UDS_RDBI) else bytes(resp.payload.payload)
        # The record sits after the 2-byte DID echo.
        raw = bytes(resp)
        vin = raw[raw.index(b"\x62") + 3 :]
        ok = vin == EXPECTED_VIN
        print(f'[oracle] RDBI 0xF190 = "{vin.decode(errors="replace")}" {"✓" if ok else "✗"}')
        fails += 0 if ok else 1
    else:
        print(f"[oracle] RDBI 0xF190 FAILED (resp={resp})")
        fails += 1

    # 3) Negative response: unknown DID → 0x7F .. 0x31
    resp = sock.sr1(UDS() / UDS_RDBI(identifiers=[0x9999]), timeout=2, verbose=False)
    raw = bytes(resp) if resp is not None else b""
    if len(raw) >= 3 and raw[-3] == 0x7F and raw[-1] == 0x31:
        print("[oracle] RDBI 0x9999 → NRC 0x31 (requestOutOfRange) ✓")
    else:
        print(f"[oracle] expected NRC 0x31, got {raw.hex()}")
        fails += 1

    sock.close()
    if fails == 0:
        print("[oracle] ALL ORACLE CHECKS PASSED")
        return 0
    print(f"[oracle] {fails} check(s) FAILED")
    return 1


if __name__ == "__main__":
    sys.exit(main())
