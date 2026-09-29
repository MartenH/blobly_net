module uds

fn test_write_then_read_did() {
	mut s := default_server()
	// 0x2E write DID 0xF100 = DE AD
	w := s.handle([u8(0x2E), 0xF1, 0x00, 0xDE, 0xAD])
	assert w == [u8(0x6E), 0xF1, 0x00]
	// 0x22 reads it back
	r := s.handle([u8(0x22), 0xF1, 0x00])
	assert r == [u8(0x62), 0xF1, 0x00, 0xDE, 0xAD]
}

fn test_security_access_unlock() {
	mut s := default_server()
	seed_resp := s.handle([u8(0x27), 0x01]) // request seed
	assert seed_resp[0] == 0x67
	assert seed_resp[1] == 0x01
	seed := seed_resp[2..]
	assert seed.len > 0
	// correct key unlocks
	mut send := [u8(0x27), 0x02]
	send << security_key(seed)
	ok := s.handle(send)
	assert ok == [u8(0x67), 0x02]
	assert s.unlocked
}

fn test_security_access_bad_key() {
	mut s := default_server()
	s.handle([u8(0x27), 0x01]) // seed
	bad := s.handle([u8(0x27), 0x02, 0x00, 0x00, 0x00, 0x00])
	assert bad == [u8(0x7F), 0x27, 0x35] // invalidKey
	assert !s.unlocked
}

fn test_read_dtc() {
	mut s := default_server()
	r := s.handle([u8(0x19), 0x02, 0xFF])
	assert r[0] == 0x59
	assert r[1] == 0x02
	assert r.len >= 3
	// unsupported sub-function
	bad := s.handle([u8(0x19), 0x01])
	assert bad == [u8(0x7F), 0x19, 0x12]
}

// suppress-positive-response: served on the plain sub-function, the positive answer withheld, a
// refusal still answered
fn test_suppress_positive_response_withholds_only_the_positive_answer() {
	mut s := default_server()
	assert s.handle([u8(0x10), 0x83]) == []u8{}
	assert s.session == 0x03
	assert s.handle([u8(0x3E), 0x80]) == []u8{}
	assert s.handle([u8(0x11), 0x85]) == [u8(0x7F), 0x11, 0x12] // a refusal is still said
	assert s.handle([u8(0x10), 0x03]) == [u8(0x50), 0x03, 0x00, 0x32, 0x01, 0xF4]
}

fn test_reset_communication_control_dtc_setting_and_clear() {
	mut s := default_server()
	assert s.handle([u8(0x11), 0x01]) == [u8(0x51), 0x01]
	assert s.handle([u8(0x28), 0x03, 0x01]) == [u8(0x68), 0x03]
	assert s.comm_control == 0x03
	assert s.handle([u8(0x85), 0x02]) == [u8(0xC5), 0x02]
	assert s.dtc_setting_off
	assert s.handle([u8(0x14), 0x12, 0x34, 0x56]) == [u8(0x54)]
	assert s.dtcs.len == 1
	assert s.handle([u8(0x14), 0x12, 0x34, 0x56]) == [u8(0x7F), 0x14, 0x31]
	assert s.handle([u8(0x14), 0xFF, 0xFF, 0xFF]) == [u8(0x54)]
	assert s.dtcs.len == 0
}
