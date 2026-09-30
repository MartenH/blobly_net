// e2e_profiles — the checksum primitives blobly's end-to-end protection can compute
// (modules/sim/e2e.v implements them; docs/simulation.md names them). Declared here, in the
// module both sim and the ARXML export import, so the accepted list exists ONCE: sim's three
// validation sites and `e2e_profile_primitive` read it, and a primitive added to sim/e2e.v
// that is not added here is refused everywhere at once rather than in some places.
module candb

//
// `autosar_p01` is a whole PROFILE (AUTOSAR E2E Profile 1: its CRC, coverage, Data ID modes and
// 0..14 counter), not a primitive; the rest are primitives under blobly's own coverage rule.
pub const e2e_profiles = ['autosar_p01', 'crc8_j1850', 'crc8_autosar', 'sum8', 'xor8']
