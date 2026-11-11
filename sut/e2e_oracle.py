#!/usr/bin/env python3
"""e2e_oracle.py - AUTOSAR E2E Profile 1 and 5 vectors from an INDEPENDENT implementation.

blobly_net's autosar_p01 and autosar_p05 (blobly/sim/e2e.v) are pinned by
blobly/sim/e2e_p01_test.v and e2e_p05_test.v; this regenerates those tests' tables from autosar-e2e (https://github.com/zariiii9003/autosar-e2e,
MIT), so the vectors are the reference's, not blobly's own output fed back.

    pip install autosar-e2e
    python3 sut/e2e_oracle.py

The frame is blobly_emb overspeed's BrakeStatus layout: payload E8 03 5A 00, the CRC in byte 4,
the counter in byte 5's low nibble, Data ID 0x1244, counters 0..14.

Profile 5 on two layouts: the header at byte 0 of 00 00 00 11 22 33 44 55, Data ID 0x1234 (a), and
at byte 3 of the CAN-FD frame E8 03 5A 00 00 00 10 20 30 40 50 60, Data ID 0x0BEE (b), at the
counters P05_COUNTERS; each CRC as the 16-bit value its two bytes hold, low byte first.
"""
from e2e import p01, p05

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

P05_COUNTERS = [0, 1, 2, 3, 127, 128, 254, 255]
P05_LAYOUTS = {
    'a': ([0, 0, 0, 0x11, 0x22, 0x33, 0x44, 0x55], 0, 0x1234),
    'b': ([0xE8, 0x03, 0x5A, 0, 0, 0, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60], 3, 0x0BEE),
}

for name, (base, off, data_id) in P05_LAYOUTS.items():
    crcs = []
    for ctr in P05_COUNTERS:
        d = bytearray(base)
        d[off + 2] = ctr
        p05.e2e_p05_protect(d, data_id, offset=off, increment_counter=False)
        crcs.append('0x%04X' % (d[off] | d[off + 1] << 8))
    print(f"p05_vectors_{name} = [u16({crcs[0]}), {', '.join(crcs[1:])}]")
