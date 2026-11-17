module uds

import os
import crypto.ed25519 as ed
import blobly.isotp

// 0x29 Authentication from the tester's side (auth.v) and on the described server (described.v): the
// key forms, the signature, Client.authenticate against a described node over inproc — success, a
// wrong key counted to the lockout, a proof with no challenge, an undecodable challenge answer, the
// refusals before anything is sent — the described server's NRC order (blobly_emb comm/uds auth.v's),
// one way to unlock, the relock, deAuthenticate, and a dropped connection voiding the challenge.

@[heap]
struct AuthClock {
mut:
	t i64 = 1000
}

fn authed_server(now &AuthClock) Server {
	mut s := server_from(ServerSpec{
		dids:              [
			DidSpec{
				id:   0x0102
				data: [u8(7)]
				read: GateSpec{
					sessions: in_extended
					level:    1
				}
			},
			DidSpec{
				id:   0x0103
				data: [u8(8)]
				read: GateSpec{
					sessions: in_extended
					level:    2
				}
			},
		]
		authenticates:     true
		auth_keys:         [dev_tester_public()] // level 2 is gated and has no key
		security_attempts: 3
		security_delay_ms: 1000
	})
	s.clock = fn [now] () i64 {
		return now.t
	}
	return s
}

fn other_seed() []u8 {
	return []u8{len: 32, init: 0x11}
}

// a 0x29 06 for a level-1 challenge answer, signed with `seed`
fn proof_for(ans []u8, seed []u8) []u8 {
	return auth_proof_request(app_proof_of(seed, 1, challenge_of(ans) or { panic(err) }) or {
		panic(err)
	})
}

fn hex_nul() string {
	return '11'.repeat(16) + '\0' + '11'.repeat(15)
}

fn test_the_key_forms() {
	dev := dev_tester_seed()
	assert tester_key('reference')! == dev && tester_key(' reference ')! == dev
	// a key that was given names something: empty, or cut by a NUL, is never the dev key
	for bad in ['', '  ', '\0bad', 'reference\0', hex_nul()] {
		if _ := tester_key(bad) {
			assert false, 'the key ${bad.bytes()} was taken'
		}
	}
	hex := '11'.repeat(32)
	assert tester_key(hex)! == other_seed()
	if _ := tester_key('11'.repeat(31) + '1') {
		assert false, '63 hex characters were taken'
	} else {
		assert err.msg().contains('got 63'), err.msg()
	}
	dir := os.join_path(os.temp_dir(), 'blobly_auth_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	f := os.join_path(dir, 'tester.seed')
	os.write_file(f, hex + '\n')!
	assert tester_key(f)! == other_seed()
	// a path cut by a NUL would open the file before it: refused, never read
	if _ := tester_key(f + '\0.other') {
		assert false, 'a path cut by a NUL was read'
	}
	empty := os.join_path(dir, 'empty.seed')
	os.write_file(empty, '')!
	if _ := tester_key(empty) {
		assert false, 'an empty file was taken'
	} else {
		assert err.msg().contains('is empty')
	}
	if _ := tester_key(os.join_path(dir, 'missing.seed')) {
		assert false, 'a missing file was taken'
	}
	assert names_key_text('') && names_key_text('reference') && names_key_text(hex)
	assert !names_key_text('keys/tester.seed')
	assert proof_of(dev, []u8{len: 32})!.len == 64
	if _ := proof_of([]u8{len: 31}, []u8{len: 32}) {
		assert false, 'a 31-byte seed signed'
	}
}

// the described server's NRC order: blobly_emb comm/uds auth.v's
fn test_the_described_nrc_order() {
	mut now := &AuthClock{}
	mut s := authed_server(now)
	assert s.handle(auth_challenge_request(1)) == [u8(0x7F), 0x29, 0x7F], 'served in the default session'
	s.handle([u8(0x10), 0x03])
	assert s.handle([u8(0x29)]) == [u8(0x7F), 0x29, 0x13]
	for sub in [u8(0x01), 0x02, 0x03, 0x04, 0x07, 0x08] {
		assert s.handle([u8(0x29), sub]) == [u8(0x7F), 0x29, 0x12]
	}
	assert s.handle([u8(0x29), 0x00, 0x00]) == [u8(0x7F), 0x29, 0x13]
	assert s.handle(auth_challenge_request(1)[..18]) == [u8(0x7F), 0x29, 0x13]
	for at in [auth_proof_len_at + 1, auth_cc_len_at + 1, auth_ap_len_at + 1] {
		mut lenf := auth_proof_request([]u8{len: 64})
		lenf[at] ^= 1
		assert s.handle(lenf) == [u8(0x7F), 0x29, 0x13], 'length field at ${at}'
	}
	assert s.handle(auth_challenge_request(0)) == [u8(0x7F), 0x29, 0x31]
	assert s.handle(auth_challenge_request(9)) == [u8(0x7F), 0x29, 0x31]
	assert s.handle(auth_challenge_request(3)) == [u8(0x7F), 0x29, 0x31], 'a level nothing gates'
	assert s.handle(auth_challenge_request(2)) == [u8(0x7F), 0x29, 0x31], 'a level with no key'
	mut alg := auth_challenge_request(1)
	alg[auth_alg05_at + 4] = 0x71
	assert s.handle(alg) == [u8(0x7F), 0x29, 0x31]
	assert s.handle(auth_proof_request([]u8{len: 64})) == [u8(0x7F), 0x29, 0x24]
	ans := s.handle(auth_challenge_request(1))
	mut alg6 := proof_for(ans, dev_tester_seed())
	alg6[auth_alg_at] = 0x07
	assert s.handle(alg6) == [u8(0x7F), 0x29, 0x31]
	assert s.handle(proof_for(ans, dev_tester_seed())) == auth_proof_answer(), 'the refused algorithm voided the challenge'
	// a challenge drawn before its level's lockout began (on the board, over the other transport):
	// the algorithm (0x31) first, then 0x37 — the challenge void, the proof not verified or counted
	a2 := s.handle(auth_challenge_request(1))
	s.sa_delay_until[0] = now.t + 1000
	mut alg62 := proof_for(a2, dev_tester_seed())
	alg62[auth_alg_at] = 0x07
	assert s.handle(alg62) == [u8(0x7F), 0x29, 0x31]
	assert s.handle(proof_for(a2, dev_tester_seed())) == [u8(0x7F), 0x29, 0x37]
	assert s.sa_since[0] == 0
	assert s.handle(proof_for(a2, dev_tester_seed())) == [u8(0x7F), 0x29, 0x24]
	s.sa_delay_until[0] = 0
	// one way to unlock
	assert s.handle([u8(0x27), 0x01]) == [u8(0x7F), 0x27, 0x11]
	assert physical_only(auth_challenge_request(1))
}

// failed proofs are wrong keys: 0x58, 0x58, 0x36, then 0x37 until the delay ends; a session entry,
// deAuthenticate and a dropped connection relock and void the challenge
fn test_the_described_lockout_relock_and_drop() {
	mut now := &AuthClock{}
	mut s := authed_server(now)
	s.handle([u8(0x10), 0x03])
	for want in [u8(0x58), 0x58, 0x36] {
		ans := s.handle(auth_challenge_request(1))
		assert s.handle(proof_for(ans, other_seed())) == [u8(0x7F), 0x29, want]
	}
	assert s.handle(auth_challenge_request(1)) == [u8(0x7F), 0x29, 0x37]
	now.t += 1000
	ans := s.handle(auth_challenge_request(1))
	assert s.handle(proof_for(ans, dev_tester_seed()))[0] == 0x69
	assert s.handle([u8(0x22), 0x01, 0x02]) == [u8(0x62), 0x01, 0x02, 7]
	assert s.handle([u8(0x29), 0x00]) == [u8(0x69), 0x00, 0x10]
	assert s.handle([u8(0x22), 0x01, 0x02]) == [u8(0x7F), 0x22, 0x33]
	a2 := s.handle(auth_challenge_request(1))
	s.handle([u8(0x10), 0x03])
	assert s.handle(proof_for(a2, dev_tester_seed())) == [u8(0x7F), 0x29, 0x24], 'a session entry kept the challenge'
	a3 := s.handle(auth_challenge_request(1))
	s.connection_dropped()
	s.handle([u8(0x10), 0x03])
	assert s.handle(proof_for(a3, dev_tester_seed())) == [u8(0x7F), 0x29, 0x24], 'a dropped connection kept the challenge'
	a4 := s.handle(auth_challenge_request(1))
	s.handle(proof_for(a4, dev_tester_seed()))
	s.connection_dropped()
	assert s.unlocked == 0 && s.session == 1, 'a dropped connection kept the unlock or the session'
}

fn auth_serve(mut ch isotp.SoftChannel, srv Server, stop chan bool) {
	mut s := srv
	s.serve(mut ch, stop)
	ch.close()
}

// Client.authenticate against a described node over inproc
fn test_client_authenticate_over_inproc() {
	mut now := &AuthClock{}
	mut srv := isotp.open_software('inproc:auth-client', 0x7E8, 0x7E0, false) or { panic(err) }
	mut cli := isotp.open_software('inproc:auth-client', 0x7E0, 0x7E8, false) or { panic(err) }
	stop := chan bool{cap: 1}
	th := spawn auth_serve(mut srv, authed_server(now), stop)
	defer {
		stop <- true
		th.wait()
		cli.close()
	}
	mut c := new_client(cli)
	c.diagnostic_session(0x03)!
	if _ := c.read_data_by_identifier(0x0102) {
		assert false, 'read before authenticating'
	}
	c.authenticate(1, dev_tester_seed())!
	assert c.read_data_by_identifier(0x0102)! == [u8(7)]
	assert c.state.security.unlocked() == 1, 'ConnState did not learn the 0x29 unlock'
	// refused before anything is sent
	before := c.sent_count
	if _ := c.authenticate(0, dev_tester_seed()) {
		assert false
	}
	if _ := c.authenticate(1, []u8{len: 3}) {
		assert false
	}
	assert c.sent_count == before, 'a refused authenticate sent something'
	// a wrong key: the ECU's NegativeResponse
	c.authenticate(1, other_seed()) or {
		assert err is NegativeResponse && (err as NegativeResponse).nrc == 0x58, err.msg()
		assert c.state.security.unlocked() == 0
		return
	}
	assert false, 'a wrong key authenticated'
}

fn test_an_undecodable_challenge_answer() {
	if _ := challenge_of([u8(0x69), 0x05, 0x00]) {
		assert false
	} else {
		assert err is UndecodableAnswer
	}
}

// small_order_encodings: every encoding of a small-order point — the eight canonical ones (the
// neutral point, the point of order 2, the two of order 4, the four of order 8), the sign bit set on
// an x of zero, and y at or above p (p, p+1: the order-4 and neutral y's again) — blobly_emb's
// bcrypto and doipcfg tests hold the same list
const small_order_encodings = [
	'0100000000000000000000000000000000000000000000000000000000000000',
	'ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
	'0000000000000000000000000000000000000000000000000000000000000000',
	'0000000000000000000000000000000000000000000000000000000000000080',
	'26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05',
	'26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc85',
	'c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a',
	'c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac03fa',
	'0100000000000000000000000000000000000000000000000000000000000080',
	'ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
	'edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
	'edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
	'eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
	'eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
]

fn unhex(h string) []u8 {
	mut out := []u8{len: h.len / 2}
	for i in 0 .. out.len {
		out[i] = u8(('0x' + h[2 * i..2 * i + 2]).u8())
	}
	return out
}

// small_order_key recognises every small-order encoding, computed, and no key of large order
fn test_small_order_keys_are_recognised() {
	for h in small_order_encodings {
		assert small_order_key(unhex(h)), h
	}
	assert !small_order_key(dev_tester_public())
	for i in 0 .. 16 {
		k := ed.new_key_from_seed([]u8{len: 32, init: u8(i * 7 + 1)}).public_key()
		assert !small_order_key(k)
	}
	// 02 00..00 is no point: not small-order either (the curve-point check refuses it)
	assert !small_order_key(unhex('02' + '00'.repeat(31)))
	assert !small_order_key([]u8{len: 31})
}

// the described server's refusals keep or spend the challenge exactly as the client's table says
// (auth_refusal_keeps_challenge): each refusal is followed by the proof for the first challenge,
// which verifies only where the challenge was kept
fn test_the_challenge_table_matches_the_described_server() {
	mut now := &AuthClock{}
	mut s := authed_server(now)
	s.handle([u8(0x10), 0x03])
	// 06 refusals: its length (0x13), its algorithm (0x31), the verdict (0x58)
	for nrc in [u8(0x13), 0x31, 0x58] {
		ans := s.handle(auth_challenge_request(1))
		mut req := proof_for(ans, if nrc == 0x58 { other_seed() } else { dev_tester_seed() })
		if nrc == 0x13 {
			req[auth_proof_len_at + 1] ^= 1
		} else if nrc == 0x31 {
			req[auth_alg_at] = 0x07
		}
		assert s.handle(req) == [u8(0x7F), 0x29, nrc]
		kept := s.handle(proof_for(ans, dev_tester_seed())) == auth_proof_answer()
		assert kept == auth_refusal_keeps_challenge(auth_verify_proof, nrc), '06 0x${nrc:02X}'
		s.handle([u8(0x10), 0x03])
	}
	// 0x37: a challenge drawn before the lockout is spent by the refusal
	a37 := s.handle(auth_challenge_request(1))
	s.sa_delay_until[0] = now.t + 1000
	assert s.handle(proof_for(a37, dev_tester_seed())) == [u8(0x7F), 0x29, 0x37]
	s.sa_delay_until[0] = 0
	assert (s.handle(proof_for(a37, dev_tester_seed())) == auth_proof_answer()) == auth_refusal_keeps_challenge(auth_verify_proof,
		0x37)
	// 05 refusals: the challenge outstanding stays
	s.handle([u8(0x10), 0x03])
	a5 := s.handle(auth_challenge_request(1))
	assert s.handle(auth_challenge_request(9)) == [u8(0x7F), 0x29, 0x31]
	assert auth_refusal_keeps_challenge(auth_request_challenge, 0x31)
	assert s.handle(proof_for(a5, dev_tester_seed())) == auth_proof_answer()
}

// 0x29 00 deAuthenticate relocks the level as blobly_emb's does: the IO controls gated on it are
// returned to the ECU, not left in force; a dropped connection likewise; controls gated on no level
// stay
fn test_deauthenticate_returns_the_controls_its_level_gated() {
	for gated in [true, false] {
		mut now := &AuthClock{}
		mut s := server_from(ServerSpec{
			dids:          [
				DidSpec{
					id:   0x0102
					data: [u8(7)]
					read: GateSpec{
						sessions: in_extended
						level:    1
					}
				},
			]
			table:         true
			services:      [
				ServiceSpec{
					sid: 0x10
				},
				ServiceSpec{
					sid: 0x22
				},
				ServiceSpec{
					sid: 0x29
				},
				ServiceSpec{
					sid:   0x2F
					level: if gated { u8(1) } else { u8(0) }
				},
			]
			authenticates: true
			auth_keys:     [dev_tester_public()]
		})
		s.clock = fn [now] () i64 {
			return now.t
		}
		s.declare_io(0x1234, 1)
		s.handle([u8(0x10), 0x03])
		ans := s.handle(auth_challenge_request(1))
		assert s.handle(proof_for(ans, dev_tester_seed())) == auth_proof_answer()
		assert s.handle([u8(0x2F), 0x12, 0x34, 0x03, 0x05])[0] == 0x6F
		assert s.handle([u8(0x22), 0x12, 0x34]) == [u8(0x62), 0x12, 0x34, 0x05]
		assert s.handle([u8(0x29), 0x00]) == [u8(0x69), 0x00, 0x10]
		want := if gated { u8(0x00) } else { u8(0x05) }
		assert s.handle([u8(0x22), 0x12, 0x34]) == [u8(0x62), 0x12, 0x34, want], 'gated ${gated}: deAuthenticate'
		// the end of the connection that earned the unlock, in the extended session it keeps
		a2 := s.handle(auth_challenge_request(1))
		s.handle(proof_for(a2, dev_tester_seed()))
		s.handle([u8(0x2F), 0x12, 0x34, 0x03, 0x06])
		s.relock(s.unlocked)
		want2 := if gated { u8(0x00) } else { u8(0x06) }
		assert s.handle([u8(0x22), 0x12, 0x34]) == [u8(0x62), 0x12, 0x34, want2], 'gated ${gated}: relock'
	}
}
