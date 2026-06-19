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
