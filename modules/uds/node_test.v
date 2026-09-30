module uds

// ISO 14229-1: to a FUNCTIONAL request a server keeps quiet instead of refusing with these —
// every ECU on the bus would otherwise answer a broadcast it does not support
fn test_functional_suppression_is_exactly_isos_list() {
	for nrc in [u8(0x11), 0x12, 0x31, 0x7E, 0x7F] {
		assert functional_suppressed([u8(0x7F), 0x22, nrc]), 'NRC 0x${nrc:02X}'
	}
	for nrc in [u8(0x13), 0x22, 0x33, 0x35, 0x78] {
		assert !functional_suppressed([u8(0x7F), 0x22, nrc]), 'NRC 0x${nrc:02X} must still be answered'
	}
	assert !functional_suppressed([u8(0x62), 0xF1, 0x90])
}
