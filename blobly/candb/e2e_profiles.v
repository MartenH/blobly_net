// e2e_profiles — the checksum primitives blobly's end-to-end protection can compute
// (blobly/sim/e2e.v implements them; docs/simulation.md names them). Declared here, in the
// module both sim and the ARXML export import, so the accepted list exists ONCE: sim's three
// validation sites and `e2e_profile_primitive` read it, and a primitive added to sim/e2e.v
// that is not added here is refused everywhere at once rather than in some places.
module candb

//
// `autosar_p01` and `autosar_p05` are whole PROFILES (AUTOSAR E2E Profile 1: its CRC, coverage,
// Data ID modes and 0..14 counter; Profile 5: its 16-bit CRC, coverage and 0..255 counter), not
// primitives; the rest are primitives under blobly's own coverage rule.
pub const e2e_profiles = ['autosar_p01', 'autosar_p05', 'crc8_j1850', 'crc8_autosar', 'sum8', 'xor8']
