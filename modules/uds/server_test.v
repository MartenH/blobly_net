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
	// unsupported sub-function; a supported one of the wrong length
	assert s.handle([u8(0x19), 0x05]) == [u8(0x7F), 0x19, 0x12]
	assert s.handle([u8(0x19), 0x04]) == [u8(0x7F), 0x19, 0x13]
	// 0x19 03 / 04 / 06 answered as blobly_emb's fault memory answers them
	assert s.handle([u8(0x19), 0x03]) == [u8(0x59), 0x03, 0x12, 0x34, 0x56, 0x01]
	assert s.handle([u8(0x19), 0x04, 0xAB, 0xCD, 0xEF, 0x01]) == [u8(0x59), 0x04, 0xAB, 0xCD, 0xEF, 0x08]
	assert s.handle([u8(0x19), 0x06, 0x12, 0x34, 0x56, 0x03]) == [u8(0x59), 0x06, 0x12, 0x34, 0x56,
		0x09, 0x03, 0x01]
	assert s.handle([u8(0x19), 0x06, 0x12, 0x34, 0x56, 0xFE]) == [u8(0x7F), 0x19, 0x31]
	assert s.handle([u8(0x19), 0x04, 0x00, 0x00, 0x01, 0x01]) == [u8(0x7F), 0x19, 0x31]
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

fn test_reset_dtc_setting_and_clear_and_no_faked_communication_control() {
	mut s := default_server()
	s.handle([u8(0x10), 0x03])
	assert s.handle([u8(0x11), 0x01]) == [u8(0x51), 0x01]
	assert s.session == 1 // the diagnostic state back to power-on
	assert s.handle([u8(0x11), 0x09]) == [u8(0x7F), 0x11, 0x12] // sub-function before length
	assert s.handle([u8(0x28), 0x03, 0x01]) == [u8(0x7F), 0x28, 0x11] // not acknowledged unacted
	assert s.handle([u8(0x85), 0x02]) == [u8(0xC5), 0x02]
	assert s.handle([u8(0x14), 0x12, 0x34, 0x56]) == [u8(0x54)]
	assert s.dtcs.len == 1
	assert s.handle([u8(0x14), 0x12, 0x34, 0x56]) == [u8(0x7F), 0x14, 0x31]
	assert s.handle([u8(0x14), 0xFF, 0xFF, 0xFF]) == [u8(0x54)]
	assert s.dtcs.len == 0
}

// a snapshot DID the server's table does not hold is left out of the record — and a DTC whose
// snapshot holds nothing is listed by neither 0x19 03 nor 0x19 04
fn test_a_snapshot_names_only_dids_the_server_holds() {
	mut s := Server{
		dids: {
			u16(0xF190): [u8(0x41)]
		}
		dtcs: [Dtc{
			code:     0x010203
			snapshot: [u16(0xF1A0), 0xF190]
		}, Dtc{
			code:     0x040506
			snapshot: [u16(0xF1A0)]
		}]
	}
	assert s.handle([u8(0x19), 0x04, 0x01, 0x02, 0x03, 0x01]) == [u8(0x59), 0x04, 0x01, 0x02, 0x03,
		0x09, 0x01, 0x01, 0xF1, 0x90, 0x41]
	assert s.handle([u8(0x19), 0x03]) == [u8(0x59), 0x03, 0x01, 0x02, 0x03, 0x01]
	assert s.handle([u8(0x19), 0x04, 0x04, 0x05, 0x06, 0xFF]) == [u8(0x59), 0x04, 0x04, 0x05, 0x06, 0x09]
}

// a freeze frame is history: the snapshot holds the DID values captured when the server first
// served, and a later write to one of its DIDs does not rewrite it
fn test_a_snapshot_keeps_its_captured_values() {
	mut s := default_server()
	before := s.dids[0xF195].clone()
	s.handle([u8(0x3E), 0x00]) // the first request captures
	s.dids[0xF195] = [u8(0xEE), 0xEE]
	r := s.handle([u8(0x19), 0x04, 0x12, 0x34, 0x56, 0x01])
	assert r[0] == 0x59
	// 59 04 DTC(3) status record count, then the first DID: id(2) and its captured bytes
	assert r[8..10] == [u8(0xF1), 0x95]
	assert r[10..10 + before.len] == before, 'the snapshot read the live DID'
}

// more DIDs than a count byte holds are sent with count 0 ("not stated"), which the decoder reads
// to the end of the answer
fn test_an_oversized_snapshot_count_is_sent_as_not_stated() {
	mut s := default_server()
	mut ids := []u16{}
	for i in 0 .. 300 {
		id := u16(0xA000 + i)
		s.dids[id] = [u8(i)]
		ids << id
	}
	s.dtcs = [Dtc{
		code:     0x123456
		snapshot: ids
	}]
	r := s.handle([u8(0x19), 0x04, 0x12, 0x34, 0x56, 0x01])
	assert r[6] == 0x01 && r[7] == 0, 'a count of 300 was truncated into one byte'
}

// ISO 14229-1: an unlocked server answers its seed request with zeros; a session change relocks it.
fn test_an_unlocked_server_answers_an_all_zero_seed_until_a_session_change() {
	mut s := Server{}
	seed := s.handle([u8(0x27), 0x01])[2..].clone()
	mut send := [u8(0x27), 0x02]
	send << security_key(seed)
	assert s.handle(send) == [u8(0x67), 0x02]
	assert s.handle([u8(0x27), 0x01]) == [u8(0x67), 0x01, 0, 0, 0, 0]
	s.handle([u8(0x10), 0x03])
	assert s.handle([u8(0x27), 0x01])[2..] == server_security_seed
}
