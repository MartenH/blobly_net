module uds

import os
import crypto.ed25519 as ed
import math.big

// 0x29 Authentication, the tester's side — ONE signing site for both profiles blobly_emb serves:
//   - an APPLICATION with `[uds] access = "authentication"`: ISO 14229-1's challenge-response (ACR),
//     unidirectional, with Ed25519 — 05 requestChallengeForAuthentication naming the level, 06
//     verifyProofOfOwnershipUnidirectional carrying the signature (`Client.authenticate`);
//   - the BOOTLOADER's own profile, 01 challenge / 02 proof (`boot_challenge` / `boot_proof`), which
//     blobly/flash runs.
// Both sign with the tester's Ed25519 seed (`proof_of`), but not the same message: the bootloader's
// proof signs the bare 32-byte challenge (deployed bootloaders verify that), an application's the
// domain-separated `auth_message` — `auth_context`, the level, the challenge (`app_proof_of`) — so a
// proof made for one is never a proof for the other, nor for another level sharing a key. The layout
// is blobly_emb comm/uds auth.v's, mirrored here offset by offset; the golden vectors in
// auth_vectors_test.v are committed byte for byte in both repos.

pub const sid_authentication = u8(0x29)

pub const auth_challenge_len = 32
pub const auth_proof_len = 64
pub const auth_challenge_req_len = 19
pub const auth_proof_req_len = 88
pub const auth_challenge_answer_len = 55
pub const auth_proof_answer_len = 21

// offsets, as blobly_emb comm/uds auth.v states them
pub const auth_level_at = 2 // 05: communicationConfiguration, the level
pub const auth_alg05_at = 3 // 05: algorithmIndicator (16)
pub const auth_alg_at = 2 // 06: algorithmIndicator (16)
pub const auth_proof_len_at = 18 // 06: lengthOfProofOfOwnershipClient = 0x0040
pub const auth_proof_at = 20 // 06: proofOfOwnershipClient (64)
pub const auth_cc_len_at = 84 // 06: lengthOfChallengeClient = 0
pub const auth_ap_len_at = 86 // 06: lengthOfAdditionalParameter = 0
pub const auth_answer_challenge_at = 21 // 05 answer: the challenge
pub const auth_answer_alg_at = 3 // 05 and 06 answers: algorithmIndicator (16), after returnValue

// auth_context: the application proof's context — the ASCII text "blobly uds 0x29 application v1" and
// a terminating zero, as blobly_emb comm/uds auth.v states it — ahead of the level and the challenge
pub const auth_context = 'blobly uds 0x29 application v1\0'.bytes()

// auth_message_len: the application message — the context, the level, the challenge
pub const auth_message_len = 31 + 1 + auth_challenge_len

pub const auth_deauthenticate = u8(0x00)
pub const auth_request_challenge = u8(0x05)
pub const auth_verify_proof = u8(0x06)
pub const auth_request_accepted = u8(0x00)
pub const auth_ownership_verified = u8(0x12)
pub const auth_deauthenticated = u8(0x10)
pub const nrc_ownership_failed = u8(0x58)
pub const nrc_challenge_failed = u8(0x59)

// ed25519_algorithm: the algorithmIndicator — Ed25519's object identifier 1.3.101.112 in DER
// (06 03 2B 65 70), left-aligned and zero-padded to 16 bytes
pub const ed25519_algorithm = [u8(0x06), 0x03, 0x2B, 0x65, 0x70, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

// the bootloader's own profile (blobly_emb boot/prog.v, REQ-BOOT-016)
pub const boot_request_challenge = u8(0x01)
pub const boot_send_proof = u8(0x02)

// dev_tester_seed is blobly_emb's DEV tester seed (examples/keys/tester.seed: 20 21 .. 3F) — the key a
// bootloader's session_key and an application's `auth_keys = { "<level>" = "reference" }` trust.
// Published, so it authenticates nobody over a network; a bench key.
pub fn dev_tester_seed() []u8 {
	mut s := []u8{len: 32}
	for i in 0 .. 32 {
		s[i] = u8(0x20 + i)
	}
	return s
}

// dev_tester_public is the public half of the dev tester seed (29ac..6dd7)
pub fn dev_tester_public() []u8 {
	return ed.new_key_from_seed(dev_tester_seed()).public_key()
}

// tester_seed reads a tester seed: empty is the dev tester seed; otherwise exactly 64 hex characters
// (surrounding space ignored). Anything else — a 0x prefix, a truncated CI secret — is an error naming
// what was wrong, never a silent fall-through to another key.
pub fn tester_seed(text string) ![]u8 {
	v := text.trim_space()
	if v == '' {
		return dev_tester_seed()
	}
	if v.len != 64 {
		return error('seed must be 64 hex chars (32 bytes); got ${v.len}')
	}
	mut s := []u8{len: 32}
	for i in 0 .. 32 {
		hb := v[i * 2..i * 2 + 2]
		if !hb.bytes().all(it.is_hex_digit()) {
			return error('seed has non-hex characters')
		}
		s[i] = u8(('0x' + hb).u8())
	}
	return s
}

// tester_seed_file reads a seed file as blobly_emb keeps one (examples/keys/tester.seed: the 64 hex
// characters on one line). An empty file is an error, never the dev seed: a path was named.
pub fn tester_seed_file(path string) ![]u8 {
	text := os.read_file(path) or { return error('seed file ${path}: ${err}') }
	if text.trim_space() == '' {
		return error('seed file ${path} is empty')
	}
	return tester_seed(text) or { return error('seed file ${path}: ${err}') }
}

// tester_key resolves a key spec as a script names one: 'reference' is the dev tester seed; a spec
// made only of hex digits is a seed and must be exactly 64 of them (the length named otherwise);
// anything else is a seed file's path. An empty spec, or one holding a NUL (which a C string or a
// path would cut, naming another key), is refused: a key that was given names something — the dev
// key is asked for by leaving the key out, or by "reference".
pub fn tester_key(spec string) ![]u8 {
	if spec.contains_u8(0) {
		return error('a key holds a NUL byte, which would cut it short; not used')
	}
	v := spec.trim_space()
	if v == '' {
		return error('an empty key names no key — leave it out, or write "reference", for the dev tester key')
	}
	if v == 'reference' {
		return dev_tester_seed()
	}
	if is_hex_text(v) {
		return tester_seed(v)
	}
	return tester_seed_file(v)
}

// names_key_text: `spec` is a key by name or by value, not a path — what a script resolves no path
// for ('' (refused by tester_key), 'reference', hex digits)
pub fn names_key_text(spec string) bool {
	v := spec.trim_space()
	return v == '' || v == 'reference' || is_hex_text(v)
}

fn is_hex_text(v string) bool {
	return v.len > 0 && v.bytes().all(it.is_hex_digit())
}

// proof_of signs `msg` with the tester `seed` (32 bytes): the Ed25519 signature both profiles carry
// as the proof of ownership — the bootloader's over the bare challenge (boot_proof), an
// application's over auth_message (app_proof_of)
pub fn proof_of(seed []u8, msg []u8) ![]u8 {
	if seed.len != 32 {
		return error('0x29: a tester seed is 32 bytes, got ${seed.len}')
	}
	priv := ed.new_key_from_seed(seed)
	return ed.sign(priv, msg) or { return error('0x29: sign the challenge: ${err}') }
}

// auth_message: what an APPLICATION proof for `level` signs — auth_context, the level (one byte),
// the 32-byte challenge (blobly_emb comm/udsauth verifies exactly this)
pub fn auth_message(level u8, challenge []u8) []u8 {
	mut m := auth_context.clone()
	m << level
	m << challenge
	return m
}

// app_proof_of: the application proof of `level` for `challenge`, signed with `seed`
pub fn app_proof_of(seed []u8, level u8, challenge []u8) ![]u8 {
	if challenge.len != auth_challenge_len {
		return error('0x29: a challenge is ${auth_challenge_len} bytes, got ${challenge.len}')
	}
	return proof_of(seed, auth_message(level, challenge))
}

// auth_challenge_request: the 0x29 05 request for `level` (19 bytes)
pub fn auth_challenge_request(level u8) []u8 {
	mut r := [sid_authentication, auth_request_challenge, level]
	r << ed25519_algorithm
	return r
}

// auth_proof_request: the 0x29 06 request carrying `proof` (64 bytes; 88 in all)
pub fn auth_proof_request(proof []u8) []u8 {
	mut r := [sid_authentication, auth_verify_proof]
	r << ed25519_algorithm
	r << [u8(0x00), u8(auth_proof_len)]
	r << proof
	r << [u8(0), 0, 0, 0]
	return r
}

// challenge_of reads the challenge out of a 0x29 05 answer, by its layout exactly: anything else is
// an UndecodableAnswer (the ECU answered — the connection is not at fault)
pub fn challenge_of(resp []u8) ![]u8 {
	ok := resp.len == auth_challenge_answer_len && resp[0] == sid_authentication + 0x40
		&& resp[1] == auth_request_challenge && resp[2] == auth_request_accepted
		&& resp[3..19] == ed25519_algorithm && resp[19] == 0x00
		&& resp[20] == u8(auth_challenge_len) && resp[53] == 0 && resp[54] == 0
	if !ok {
		return UndecodableAnswer{
			why:  '0x29 05: not a challenge answer: ${resp.hex()}'
			resp: resp
		}
	}
	return resp[auth_answer_challenge_at..auth_answer_challenge_at + auth_challenge_len].clone()
}

// auth_proof_answer: the 0x29 06 positive answer, ISO 14229-1:2020's layout — ownershipVerified,
// the algorithmIndicator, lengthOfSessionKeyInfo 0 (no session key): 21 bytes. blobly_emb's
// application answers it after a responsePending (0x78), which Client.raw waits through.
pub fn auth_proof_answer() []u8 {
	mut a := [sid_authentication + 0x40, auth_verify_proof, auth_ownership_verified]
	a << ed25519_algorithm
	a << [u8(0x00), 0x00]
	return a
}

// verified_of checks a 0x29 06 answer is ownershipVerified in ISO 14229-1:2020's layout: the
// algorithmIndicator Ed25519's, and a sessionKeyInfo of exactly the length it states (blobly_emb
// sends none; one sent is accepted and not used). Anything else is an UndecodableAnswer.
pub fn verified_of(resp []u8) ! {
	ok := resp.len >= auth_proof_answer_len && resp[0] == sid_authentication + 0x40
		&& resp[1] == auth_verify_proof && resp[2] == auth_ownership_verified
		&& resp[auth_answer_alg_at..auth_answer_alg_at + 16] == ed25519_algorithm
		&& resp.len == auth_proof_answer_len + (int(resp[19]) << 8 | int(resp[20]))
	if !ok {
		return UndecodableAnswer{
			why:  '0x29 06: not ownershipVerified: ${resp.hex()}'
			resp: resp
		}
	}
}

// authenticate unlocks `level` (1..8) on an ECU that serves 0x29 ACR (blobly_emb `[uds] access =
// "authentication"`): 0x29 05 naming the level, the application message for the level and the
// challenge (auth_message) signed with `seed` (the tester's Ed25519 seed, 32 bytes — dev_tester_seed()
// for a bench node trusting "reference"), 0x29 06 with the proof, and ownershipVerified required. The level and the seed are refused before anything is sent;
// a refusal by the ECU is its NegativeResponse (0x58 a wrong proof, 0x36 the last one, 0x37 the
// lockout, 0x24 no challenge, 0x7F not in this session).
pub fn (mut c Client) authenticate(level int, seed []u8) ! {
	if level < 1 || level > 8 {
		return error('0x29: security level ${level} is out of range (1..8)')
	}
	if seed.len != 32 {
		return error('0x29: a tester seed is 32 bytes, got ${seed.len}')
	}
	ch := challenge_of(c.raw(auth_challenge_request(u8(level)))!)!
	proof := app_proof_of(seed, u8(level), ch)!
	verified_of(c.raw(auth_proof_request(proof))!)!
}

// boot_challenge asks a blobly_emb BOOTLOADER for its 0x29 challenge (its own profile, sub-function
// 01): the 32 bytes after `69 01`
pub fn (mut c Client) boot_challenge() ![]u8 {
	resp := c.raw([sid_authentication, boot_request_challenge])!
	if resp.len < 2 + auth_challenge_len {
		return UndecodableAnswer{
			why:  'request challenge: unexpected response ${resp.hex()}'
			resp: resp
		}
	}
	return resp[2..2 + auth_challenge_len].clone()
}

// boot_proof sends the bootloader the proof for `challenge`, signed with `seed` (sub-function 02):
// its own profile's message, the bare challenge — never auth_message, which no bootloader verifies
pub fn (mut c Client) boot_proof(seed []u8, challenge []u8) ! {
	mut req := [sid_authentication, boot_send_proof]
	req << proof_of(seed, challenge)!
	c.raw(req)!
}

// small_order_key: `key` (32 bytes) decodes to an Ed25519 point of small order — one the cofactor 8
// takes to the neutral point: the neutral point and the points of order 2, 4 and 8, in every
// encoding (a y at or above p reduces like any other). Under such a key a forged proof verifies —
// under the neutral point R = neutral, S = 0 for every message — so a configured key must not be
// one (blobly_emb refuses it at generation: bcrypto.small_order). Computed, not a list: y decoded,
// x² from the curve equation, three doublings on y alone (an Edwards doubling's y needs only x²
// and y²), compared with the neutral point's y = 1. A key that is no point answers false.
pub fn small_order_key(key []u8) bool {
	if key.len != 32 {
		return false
	}
	p := big.integer_from_int(1).left_shift(255) - big.integer_from_int(19) // the field prime
	mut le := key.clone()
	le[31] &= 0x7F
	mut y := big.integer_from_radix(le.reverse().hex(), 16) or { return false }
	y = y.mod_euclid(p)
	one := big.integer_from_int(1)
	two := big.integer_from_int(2)
	// d = -121665 / 121666
	inv := big.integer_from_int(121666).mod_inverse(p) or { return false }
	d := (p - big.integer_from_int(121665)) * inv % p
	for i in 0 .. 3 {
		y2 := y * y % p
		den := (d * y2 + one).mod_euclid(p)
		den_inv := den.mod_inverse(p) or { return false }
		x2 := ((y2 - one).mod_euclid(p) * den_inv) % p
		if i == 0 {
			// a point only where x² is a square (Euler's criterion)
			e := x2.big_mod_pow((p - one) / two, p) or { return false }
			if !(e == one || x2 == big.zero_int) {
				return false
			}
		}
		// doubled: y' = (x² + y²) / (2 + x² - y²) on -x² + y² = 1 + d x² y²
		dd := (two + x2 - y2).mod_euclid(p)
		dd_inv := dd.mod_inverse(p) or { return false }
		y = (x2 + y2).mod_euclid(p) * dd_inv % p
	}
	return y == one
}

// auth_refusal_keeps_challenge: whether a 0x29 `sub` (05 or 06) refused with `nrc` leaves the
// challenge outstanding on the server — the ONE table of blobly_emb comm/uds auth.v's (and the
// described server's, d_auth) refusal order: a request refused before it touches the challenge (its
// length 0x13, the algorithm or the level 0x31, the answer's room 0x14 — and for 05 its level's
// delay 0x37, judged before a new challenge voids the old one) keeps it; a 06 refused after it is
// spent (0x37 voiding it, the verdict 0x58 / 0x36, an owed answer given up 0x22) or with none
// outstanding (0x24), a 05 whose new challenge failed (0x59), and every code not named, do not. Only
// a refusal given BEFORE the server's 0x78: a 06 answered 0x14 after its 0x78 is a valid proof whose
// owing transport could not carry ownershipVerified (blobly_emb auth_owed), its challenge spent at
// the verify — the caller asks that apart (ConnState.observe_auth, by the exchange's 0x78 count).
pub fn auth_refusal_keeps_challenge(sub u8, nrc u8) bool {
	return match sub {
		auth_request_challenge { nrc in [u8(0x13), 0x31, 0x37, 0x14] }
		auth_verify_proof { nrc in [u8(0x13), 0x31, 0x14] }
		else { false }
	}
}
