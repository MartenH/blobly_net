module uds

import blobly.isotp
import crypto.ed25519 as ed

// The GOLDEN 0x29 vectors, committed byte for byte in blobly_net (here) and blobly_emb
// (comm/uds/auth_test.v, comm/udsauth/udsauth_test.v): the dev tester seed 20..3F, its public key,
// the 05 request for level 1, its answer for the challenge 00..1F, the deterministic Ed25519
// signature of that challenge under the seed (RFC 8032) and the 06 request carrying it. They pin
// the wire format independently of the offset constants both repos keep.

const gv_public = [u8(0x29), 0xac, 0xba, 0xe1, 0x41, 0xbc, 0xca, 0xf0, 0xb2, 0x2e, 0x1a, 0x94, 0xd3,
	0x4d, 0x0b, 0xc7, 0x36, 0x1e, 0x52, 0x6d, 0x0b, 0xfe, 0x12, 0xc8, 0x97, 0x94, 0xbc, 0x93, 0x22,
	0x96, 0x6d, 0xd7]

const gv_sig = [u8(0xea), 0x92, 0xd2, 0x4e, 0xda, 0x4c, 0x09, 0x9e, 0xa3, 0xc1, 0xaa, 0xa1, 0x0c,
	0x86, 0xcd, 0x63, 0xe2, 0xa0, 0x43, 0x0a, 0xaf, 0x86, 0x5d, 0xb6, 0xed, 0x60, 0xf8, 0x12, 0x9d,
	0xe7, 0xa3, 0x63, 0xa6, 0x1c, 0xdc, 0x52, 0x51, 0xb5, 0xc7, 0x4f, 0x07, 0x75, 0x56, 0x39, 0xb3,
	0x3d, 0xda, 0xd8, 0x69, 0x9e, 0xf8, 0x5b, 0xe6, 0x1c, 0xbe, 0x8d, 0x60, 0x3e, 0x8e, 0x80, 0xaa,
	0x7c, 0x1b, 0x09]

const gv_req05 = [u8(0x29), 0x05, 0x01, 0x06, 0x03, 0x2B, 0x65, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0]

fn gv_challenge() []u8 {
	return []u8{len: 32, init: u8(index)}
}

fn gv_ans05() []u8 {
	mut a := [u8(0x69), 0x05, 0x00, 0x06, 0x03, 0x2B, 0x65, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		0x00, 0x20]
	a << gv_challenge()
	a << [u8(0), 0]
	return a
}

fn gv_req06() []u8 {
	mut r := [u8(0x29), 0x06, 0x06, 0x03, 0x2B, 0x65, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00,
		0x40]
	r << gv_sig
	r << [u8(0), 0, 0, 0]
	return r
}

// gv_ans06: the 06 answer — ownershipVerified, the algorithmIndicator, lengthOfSessionKeyInfo 0
// (ISO 14229-1:2020; 21 bytes)
fn gv_ans06() []u8 {
	mut a := [u8(0x69), 0x06, 0x12, 0x06, 0x03, 0x2B, 0x65, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	a << [u8(0x00), 0x00]
	return a
}

fn test_the_golden_vectors_are_the_dev_key_s() {
	assert dev_tester_public() == gv_public
	assert proof_of(dev_tester_seed(), gv_challenge())! == gv_sig
	// an independent check of the signature: vlib's verifier
	assert ed.verify(gv_public, gv_challenge(), gv_sig)!
	assert auth_challenge_request(1) == gv_req05
	assert auth_proof_request(gv_sig) == gv_req06()
	assert challenge_of(gv_ans05())! == gv_challenge()
	assert gv_req06()[auth_proof_at..auth_proof_at + auth_proof_len] == gv_sig
	assert auth_proof_answer() == gv_ans06()
	verified_of(gv_ans06())!
}

// the 06 answer is read by ISO 14229-1:2020's layout: the 5-byte form without the algorithmIndicator
// is not it, a session key of the length stated is accepted, and a length that disagrees is refused
fn test_the_proof_answer_is_read_by_its_layout() {
	if _ := verified_of([u8(0x69), 0x06, 0x12, 0, 0]) {
		assert false, 'the 5-byte answer was read as verified'
	}
	mut with_key := gv_ans06()
	with_key[20] = 2
	with_key << [u8(0xAA), 0xBB]
	verified_of(with_key)!
	mut short := gv_ans06()
	short[20] = 3
	if _ := verified_of(short) {
		assert false, 'a session key length the answer does not hold was accepted'
	}
	mut other := gv_ans06()
	other[5] = 0x71 // Ed448's OID
	if _ := verified_of(other) {
		assert false, 'another algorithm was read as verified'
	}
}

// a stub ECU: answers the golden 05 answer, records the 06 it is sent and grants it — after a
// responsePending, as blobly_emb's application does while it verifies
fn stub_ecu(mut ch isotp.SoftChannel, stop chan bool, got chan []u8) {
	for {
		select {
			_ := <-stop {
				ch.close()
				return
			}
			else {}
		}
		req := ch.recv(50) or { continue }
		if req.len >= 2 && req[0] == 0x29 && req[1] == 0x05 {
			ch.send(gv_ans05()) or {}
		} else if req.len >= 2 && req[0] == 0x29 && req[1] == 0x06 {
			got <- req.clone()
			ch.send([u8(0x7F), 0x29, 0x78]) or {}
			ch.send(gv_ans06()) or {}
		}
	}
}

// Client.authenticate's encoder, over the golden 05 answer, emits exactly the golden 06 request
fn test_authenticate_emits_the_golden_proof_request() {
	mut srv := isotp.open_software('inproc:auth-golden', 0x7E8, 0x7E0, false) or { panic(err) }
	mut cli := isotp.open_software('inproc:auth-golden', 0x7E0, 0x7E8, false) or { panic(err) }
	stop := chan bool{cap: 1}
	got := chan []u8{cap: 1}
	th := spawn stub_ecu(mut srv, stop, got)
	defer {
		stop <- true
		th.wait()
		cli.close()
	}
	mut c := new_client(cli)
	c.authenticate(1, dev_tester_seed())!
	sent := <-got
	assert sent == gv_req06()
}

// the described server accepts the golden 06 request for the golden challenge
fn test_a_described_server_accepts_the_golden_proof() {
	mut s := auth_server()
	assert s.handle([u8(0x10), 0x03])[0] == 0x50
	assert s.handle(gv_req05)[0] == 0x69
	s.auth_challenge = gv_challenge() // the challenge the vector signed
	assert s.handle(gv_req06()) == gv_ans06()
	assert s.unlocked == 1
	// a suppressed 06 is answered all the same, as the board's (its 0x78 lifts the suppression)
	assert s.handle(gv_req05)[0] == 0x69
	s.auth_challenge = gv_challenge()
	mut r := gv_req06()
	r[1] = 0x86
	assert s.handle(r) == gv_ans06()
	// and so is a suppressed 05; a suppressed 00 is not
	mut q := gv_req05.clone()
	q[1] = 0x85
	assert s.handle(q)[0] == 0x69
	assert s.handle([u8(0x29), 0x80]) == []u8{}
	assert s.unlocked == 0
}

// auth_server: a described node authenticating level 1 with the dev tester key
fn auth_server() Server {
	return server_from(ServerSpec{
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
		authenticates: true
		auth_keys:     [dev_tester_public()]
	})
}
