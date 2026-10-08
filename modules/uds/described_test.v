module uds

// FakeClock is a clock the test moves.
@[heap]
struct FakeClock {
mut:
	t i64 = 1000
}

// a node with one write-gated DID and the reference key, on a clock the test moves
fn gated(now &FakeClock) Server {
	mut s := server_from(ServerSpec{
		dids:              [
			DidSpec{
				id:       0x0102
				data:     [u8(0)]
				writable: true
				write:    GateSpec{
					sessions: in_extended
					level:    1
				}
			},
		]
		reference_key:     true
		serves_reset:      true
		security_attempts: 2
		security_delay_ms: 3000
		s3_ms:             5000
	})
	s.clock = fn [now] () i64 {
		return now.t
	}
	return s
}

fn test_wrong_keys_lock_the_level_out_for_the_delay() {
	mut now := &FakeClock{}
	mut s := gated(now)
	assert s.handle([u8(0x10), 0x03])[0] == 0x50
	assert s.handle([u8(0x27), 0x01])[0] == 0x67
	assert s.handle([u8(0x27), 0x02, 0, 0, 0, 0]) == [u8(0x7F), 0x27, 0x35]
	assert s.handle([u8(0x27), 0x01])[0] == 0x67
	assert s.handle([u8(0x27), 0x02, 0, 0, 0, 0]) == [u8(0x7F), 0x27, 0x36] // the last allowed
	assert s.handle([u8(0x27), 0x01]) == [u8(0x7F), 0x27, 0x37]
	now.t += 2999
	assert s.handle([u8(0x27), 0x01]) == [u8(0x7F), 0x27, 0x37]
	now.t += 1
	seed := s.handle([u8(0x27), 0x01])
	assert seed[0] == 0x67
	mut key := [u8(0x27), 0x02]
	key << security_key(seed[2..])
	assert s.handle(key) == [u8(0x67), 0x02]
	assert s.handle([u8(0x27), 0x02, 0, 0, 0]) == [u8(0x7F), 0x27, 0x13]
}

fn test_s3_ends_a_quiet_session() {
	mut now := &FakeClock{}
	mut s := gated(now)
	assert s.handle([u8(0x10), 0x03])[0] == 0x50
	now.t += 4000
	assert s.handle([u8(0x3E), 0x00]) == [u8(0x7E), 0x00] // kept alive
	now.t += 4000
	assert s.handle([u8(0x2E), 0x01, 0x02, 0x05]) == [u8(0x7F), 0x2E, 0x33] // still extended
	now.t += 5001
	assert s.handle([u8(0x2E), 0x01, 0x02, 0x05]) == [u8(0x7F), 0x2E, 0x31] // back in default
}

fn test_suppressed_positive_answers_are_withheld() {
	mut now := &FakeClock{}
	mut s := gated(now)
	assert s.handle([u8(0x10), 0x83]) == []u8{}
	assert s.session == 3
	assert s.handle([u8(0x3E), 0x80]) == []u8{}
	assert s.handle([u8(0x3E), 0x81]) == [u8(0x7F), 0x3E, 0x12]
}

fn test_a_reset_between_wrong_keys_costs_the_delay() {
	mut now := &FakeClock{}
	mut s := gated(now)
	assert s.handle([u8(0x10), 0x03])[0] == 0x50
	assert s.handle([u8(0x27), 0x01])[0] == 0x67
	assert s.handle([u8(0x27), 0x02, 0, 0, 0, 0]) == [u8(0x7F), 0x27, 0x35]
	assert s.handle([u8(0x11), 0x01]) == [u8(0x51), 0x01]
	assert s.handle([u8(0x10), 0x03])[0] == 0x50
	assert s.handle([u8(0x27), 0x01]) == [u8(0x7F), 0x27, 0x37]
}

fn test_a_functional_security_access_is_ignored_but_keeps_the_session() {
	mut now := &FakeClock{}
	mut s := gated(now)
	assert s.handle([u8(0x10), 0x03])[0] == 0x50
	now.t += 4000
	assert s.handle_functional([u8(0x27), 0x01]) == []u8{}
	assert s.seed_lvl == 0
	now.t += 4000
	assert s.handle([u8(0x2E), 0x01, 0x02, 0x05]) == [u8(0x7F), 0x2E, 0x33] // still extended
}

fn test_a_read_longer_than_the_carrier_is_refused() {
	mut s := server_from(ServerSpec{
		dids:         [DidSpec{
			id:   0x0100
			data: []u8{len: 32}
		}]
		max_response: 100
	})
	mut req := [u8(0x22)]
	for _ in 0 .. 3 {
		req << [u8(0x01), 0x00]
	}
	assert s.handle(req) == [u8(0x7F), 0x22, 0x14] // 1 + 3 * 34 = 103
	assert s.handle([u8(0x22), 0x01, 0x00, 0x01, 0x00])[0] == 0x62
}

fn test_a_duplicate_did_serves_the_first_declaration() {
	mut s := server_from(ServerSpec{
		dids: [DidSpec{
			id:   0x0100
			data: [u8(1)]
		}, DidSpec{
			id:   0x0100
			data: [u8(2)]
			read: GateSpec{
				level: 1
			}
		}]
	})
	assert s.handle([u8(0x22), 0x01, 0x00]) == [u8(0x62), 0x01, 0x00, 0x01]
}

fn test_an_ignored_functional_request_after_s3_still_ends_the_session() {
	mut now := &FakeClock{}
	mut s := gated(now)
	assert s.handle([u8(0x10), 0x03])[0] == 0x50
	now.t += 6000 // past S3
	assert s.handle_functional([u8(0x27), 0x01]) == []u8{}
	now.t += 1000 // within S3 of the ignored request: it did not revive the session
	assert s.handle([u8(0x2E), 0x01, 0x02, 0x05]) == [u8(0x7F), 0x2E, 0x31] // back in default
}
