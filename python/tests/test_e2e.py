"""blobly.e2e against the vectors blobly/sim/e2e_p01_test.v pins: AUTOSAR E2E Profile 1 from an
independent implementation (autosar-e2e, sut/e2e_oracle.py), on blobly_emb overspeed's BrakeStatus
layout — payload E8 03 5A 00, the CRC in byte 4, the counter in byte 5's low nibble, Data ID 0x1244
(distinct bytes, so alt's choice of byte shows), counters 0..14. No project is needed."""
import re

import pytest

from blobly import e2e

pytestmark = pytest.mark.usefixtures("engine")

VECTORS = {
    "both": [0xE8, 0xF5, 0xD2, 0xCF, 0x9C, 0x81, 0xA6, 0xBB, 0x00, 0x1D, 0x3A, 0x27, 0x74, 0x69, 0x4E],
    "low": [0x92, 0x8F, 0xA8, 0xB5, 0xE6, 0xFB, 0xDC, 0xC1, 0x7A, 0x67, 0x40, 0x5D, 0x0E, 0x13, 0x34],
    "alt": [0x92, 0x42, 0xA8, 0x78, 0xE6, 0x36, 0xDC, 0x0C, 0x7A, 0xAA, 0x40, 0x90, 0x0E, 0xDE, 0x34],
}
BASE = bytes([0xE8, 0x03, 0x5A, 0x00, 0x00, 0x00])
DATA_ID = 0x1244


class TestReference:
    def test_crc_and_protect_are_the_reference_in_every_mode(self):
        for mode, want in VECTORS.items():
            for n in range(15):
                frame = BASE[:5] + bytes([n])
                assert e2e.p01_crc(frame, DATA_ID, 4, 5, mode) == want[n], f"{mode}, counter {n}"
                assert e2e.p01_protect(BASE, DATA_ID, 4, 5, n, mode) == BASE[:4] + bytes([want[n], n]), \
                    f"{mode}, counter {n}"

    def test_both_is_the_default_mode(self):
        assert e2e.p01_crc(BASE[:5] + b"\x03", DATA_ID, 4, 5) == VECTORS["both"][3]
        assert e2e.p01_protect(BASE, DATA_ID, 4, 5, 3)[4] == VECTORS["both"][3]

    def test_protect_keeps_the_counter_bytes_high_nibble_and_leaves_its_input(self):
        src = bytearray(BASE[:5] + b"\xA7")
        out = e2e.p01_protect(src, DATA_ID, 4, 5, 3, "alt")
        assert isinstance(out, bytes)
        assert out[5] == 0xA3
        assert out[4] == e2e.p01_crc(out, DATA_ID, 4, 5, "alt")
        assert src == bytearray(BASE[:5] + b"\xA7"), "the caller's bytes were written"
        assert e2e.p01_protect(list(BASE), DATA_ID, 4, 5, 0) == BASE[:4] + bytes([VECTORS["both"][0], 0])


class TestRefusals:
    def test_what_profile_1_cannot_be_is_a_value_error_naming_it(self):
        cases = [
            (lambda: e2e.p01_protect(BASE, DATA_ID, 4, 5, 15), "a Profile 1 counter is 0..14, not 15"),
            (lambda: e2e.p01_protect(BASE, DATA_ID, 4, 5, -1), "a Profile 1 counter is 0..14, not -1"),
            (lambda: e2e.p01_crc(BASE, 0x10000, 4, 5), "data_id 0x10000 does not fit its 16 bits"),
            (lambda: e2e.p01_crc(BASE, -1, 4, 5), "data_id -1 is not a Data ID"),
            (lambda: e2e.p01_crc(BASE, DATA_ID, 4, 4), "crc_pos 4 / counter_pos 4 must be distinct bytes of the 6-byte frame"),
            (lambda: e2e.p01_crc(BASE, DATA_ID, 6, 5), "crc_pos 6 / counter_pos 5 must be distinct bytes"),
            (lambda: e2e.p01_protect(b"", DATA_ID, 0, 1, 0), "of the 0-byte frame"),
            (lambda: e2e.p01_crc(BASE, DATA_ID, 4, 5, "ALT"), 'data_id_mode "ALT" is not both, low or alt'),
            (lambda: e2e.p01_crc(BASE, 2**40, 4, 5), "past what a 32-bit C integer holds"),
            (lambda: e2e.p01_crc(BASE, DATA_ID, 4, 5, "alt\0x"), "NUL"),
        ]
        for call, want in cases:
            with pytest.raises(ValueError, match=re.escape(want)):
                call()

    def test_an_argument_of_the_wrong_type_is_a_type_error(self):
        for call in (lambda: e2e.p01_crc("E8035A000000", DATA_ID, 4, 5),
                     lambda: e2e.p01_crc(6, DATA_ID, 4, 5),
                     lambda: e2e.p01_crc(BASE, 0x44 + 0.5, 4, 5),
                     lambda: e2e.p01_crc(BASE, DATA_ID, True, 5),
                     lambda: e2e.p01_protect(BASE, DATA_ID, 4, 5, None),
                     lambda: e2e.p01_crc(BASE, DATA_ID, 4, 5, None)):
            with pytest.raises(TypeError):
                call()


# Profile 5, the vectors blobly/sim/e2e_p05_test.v pins (autosar-e2e): a 12-byte CAN-FD frame with
# the header at byte 3, Data ID 0x0BEE, and an 8-byte frame with the header at byte 0, Data ID 0x1234
P05_COUNTERS = [0, 1, 2, 3, 127, 128, 254, 255]
P05_FD = [0x8D87, 0x66A4, 0x4BE0, 0xA0C3, 0xBE08, 0x3235, 0xEA99, 0x01BA]
P05_FD_BASE = bytes.fromhex("E8035A000000102030405060")
P05_CLASSIC_BASE = bytes.fromhex("0000001122334455")


class TestProfile5:
    def test_crc_and_protect_are_the_reference(self):
        for n, want in zip(P05_COUNTERS, P05_FD):
            out = e2e.p05_protect(P05_FD_BASE, 0x0BEE, n, offset=3)
            assert out == P05_FD_BASE[:3] + bytes([want & 0xFF, want >> 8, n]) + P05_FD_BASE[6:], f"counter {n}"
            assert e2e.p05_crc(out, 0x0BEE, 3) == want

    def test_offset_defaults_to_0_and_the_input_is_left(self):
        src = bytearray(P05_CLASSIC_BASE)
        out = e2e.p05_protect(src, 0x1234, 1)
        assert isinstance(out, bytes)
        assert out[:3] == bytes([0xF2, 0x4F, 1])
        assert src == bytearray(P05_CLASSIC_BASE), "the caller's bytes were written"

    def test_what_profile_5_cannot_be_is_a_value_error_naming_it(self):
        cases = [
            (lambda: e2e.p05_protect(P05_CLASSIC_BASE, 0x1234, 256), "a Profile 5 counter is 0..255, not 256"),
            (lambda: e2e.p05_crc(P05_CLASSIC_BASE, 0x10000), "data_id 65536 does not fit its 16 bits"),
            (lambda: e2e.p05_crc(P05_CLASSIC_BASE, 0x1234, 6), "offset 6 leaves no room for the 3-byte header"),
            (lambda: e2e.p05_crc(b"\x00\x00", 0x1234), "in the 2-byte frame"),
        ]
        for call, want in cases:
            with pytest.raises(ValueError, match=re.escape(want)):
                call()
        with pytest.raises(TypeError):
            e2e.p05_crc(P05_CLASSIC_BASE, 0x1234, 1.5)
