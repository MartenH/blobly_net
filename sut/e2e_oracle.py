#!/usr/bin/env python3
"""e2e_oracle.py - AUTOSAR E2E Profile 1 vectors from an INDEPENDENT implementation.

blobly_net's autosar_p01 (modules/sim/e2e.v) is pinned by modules/sim/e2e_p01_test.v; this
regenerates that test's table from autosar-e2e (https://github.com/zariiii9003/autosar-e2e,
MIT), so the vectors are the reference's, not blobly's own output fed back.

    pip install autosar-e2e
    python3 sut/e2e_oracle.py

The frame is blobly_emb overspeed's BrakeStatus layout: payload E8 03 5A 00, the CRC in byte 4,
the counter in byte 5's low nibble, Data ID 0x1244, counters 0..14.
"""
from e2e import p01

MODES = {
    'both': p01.E2E_P01_DATAID_BOTH,
    'low': p01.E2E_P01_DATAID_LOW,
    'alt': p01.E2E_P01_DATAID_ALT,
}

for name, mode in MODES.items():
    crcs = []
    for ctr in range(15):
        d = bytearray([0xE8, 0x03, 0x5A, 0x00, 0x00, ctr])
        p01.e2e_p01_protect(d, 0x1244, data_id_mode=mode, offset=4, increment_counter=False)
        crcs.append('0x%02X' % d[4])
    print(f"'{name}': [u8({crcs[0]}), {', '.join(crcs[1:])}]")
