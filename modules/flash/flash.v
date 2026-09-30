module flash

// flash — the UDS firmware-download session against a blobly bootloader
// (blobly_emb docs/bootloader.md), shared by cmd/flash (CLI) and the GUI's
// Flash panel. Transport-neutral on the ECU side; this is the CAN binding's
// client half over an isotp.Channel.
//
// Sequence: 0x10 02 -> 0x27 seed/key -> 0x31 FF00 erase -> 0x34 -> 0x36 xN
// -> 0x37 -> 0x31 FF01 check(+mark) -> 0x11 reset. The ECU writes the valid
// mark ONLY after its own full-image CRC passes — a cut transfer leaves an
// image the boot refuses, and a plain re-run recovers (bench-verified).
// Every request goes through uds.Client (`ask`): the responsePending (0x78) wait a bootloader's
// erase may need, P2* from the 0x10 02 answer, and a response that must name the request it
// answers — a duplicated earlier answer (a CAN retransmission) is discarded, not taken for the
// current step's, which on 0x36 would put every later block one answer behind.
import isotp
import uds
import crypto.ed25519 as ed

pub const boot_magic = u32(0x54424C42) // 'BLBT'
pub const hdr_size = 64

// Sink receives progress: the CLI prints, the GUI appends to its scrollback.
pub interface Sink {
mut:
	note(s string)                // one milestone line ("unlocked", "erased ...")
	block(done int, total int)    // transfer progress, in blocks
}

pub struct Opts {
pub mut:
	base       u32 = 0x0802_0000 // the app slot (bootmap.h APP_BASE)
	sw_version u32 = 1
	// 0x29 tester private seed (32 bytes). When set, the flasher authenticates
	// with the boot's challenge/response before erasing. Empty = skip auth (a
	// boot with no key baked; legacy / unsigned targets).
	auth_seed []u8
}

// tester_seed resolves the 0x29 signing seed (the SESSION key, distinct from the
// image-signing key): empty -> the dev tester seed (examples/keys/tester.seed);
// 64 hex chars -> parsed; anything else (0x-prefix, truncated CI secret) -> an
// error, so a misconfigured seed fails fast instead of silently signing wrong.
pub fn tester_seed(env_val string) ![]u8 {
	v := env_val.trim_space()
	if v == '' {
		mut s := []u8{len: 32}
		for i in 0 .. 32 {
			s[i] = u8(0x20 + i) // dev TESTER seed (examples/keys/tester.seed) — 0x29 auth
		}
		return s
	}
	if v.len != 64 {
		return error('seed must be 64 hex chars (32 bytes); got ${v.len}')
	}
	mut s := []u8{len: 32}
	for i in 0 .. 32 {
		hb := v[i * 2..i * 2 + 2]
		if !is_hex(hb) {
			return error('seed has non-hex characters')
		}
		s[i] = u8(('0x' + hb).u8())
	}
	return s
}

fn is_hex(s string) bool {
	for c in s {
		if !((c >= `0` && c <= `9`) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)) {
			return false
		}
	}
	return true
}

pub fn crc32(data []u8) u32 {
	mut crc := u32(0xFFFF_FFFF)
	for b in data {
		crc ^= u32(b)
		for _ in 0 .. 8 {
			mask := -(crc & 1)
			crc = (crc >> 1) ^ (u32(0xEDB8_8320) & mask)
		}
	}
	return crc ^ 0xFFFF_FFFF
}

// authenticate runs the 0x29 challenge/response: the boot sends a random
// challenge, we sign it with the tester private key, the boot verifies with the
// public key it holds. Replaces the legacy 0x27 seed/key.
fn authenticate(mut c uds.Client, seed []u8, mut sink Sink) ! {
	// A boot with NO session key baked (a keyless/legacy build) answers requestChallenge with
	// conditionsNotCorrect / serviceNotSupported — that boot doesn't require 0x29, so flash
	// without it. If it IS secured, erase/download stay gated, so proceeding here can never
	// bypass a real gate.
	cr := c.raw([u8(0x29), 0x01]) or {
		if err is uds.NegativeResponse {
			if err.nrc == 0x22 || err.nrc == 0x11 {
				sink.note('0x29 not required by this boot — flashing without auth')
				return
			}
		}
		return step_error('request challenge', err)
	}
	if cr.len < 2 + 32 {
		return error('request challenge: unexpected response ${cr.hex()}')
	}
	challenge := cr[2..34].clone()
	priv := ed.new_key_from_seed(seed)
	sig := ed.sign(priv, challenge) or { return error('sign challenge: ${err}') }
	mut proof := [u8(0x29), 0x02]
	proof << sig
	ask(mut c, proof, 'send proof')!
	sink.note('authenticated (0x29)')
}

// make_header wraps RAW application bytes: magic, length, CRC, version — the
// valid mark stays 0xFF (the ECU's to write, never ours). A pre-wrapped
// mkimage .img (starts with 'BLBT') is transferred as-is by program().
pub fn make_header(image []u8, sw_version u32) []u8 {
	mut h := []u8{len: hdr_size, init: 0xFF}
	wr32(mut h, 0, boot_magic)
	h[4] = 1 // hdr_ver
	h[5] = 0
	h[6] = 0
	h[7] = 0
	wr32(mut h, 8, u32(image.len))
	wr32(mut h, 12, crc32(image))
	wr32(mut h, 16, sw_version)
	wr32(mut h, 20, u32(hdr_size))
	wr32(mut h, 24, 0)
	wr32(mut h, 28, crc32(h[..28]))
	return h
}

fn wr32(mut b []u8, off int, v u32) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
	b[off + 2] = u8(v >> 16)
	b[off + 3] = u8(v >> 24)
}

fn be32(v u32) []u8 {
	return [u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)]
}

// ask is one step of the session: its positive answer, or an error naming the step (a negative
// answer as its NRC).
fn ask(mut c uds.Client, req []u8, what string) ![]u8 {
	return c.raw(req) or { return step_error(what, err) }
}

// step_error names the step a request failed in; a negative answer as its NRC.
fn step_error(what string, err IError) IError {
	if err is uds.NegativeResponse {
		return error('${what}: NRC 0x${err.nrc.hex()}')
	}
	return error('${what}: ${err}')
}

// first_answer_ms: the wait for each step's first answer (the timeout this session always had);
// a server that needs longer says 0x78, and is then waited for its P2*.
const first_answer_ms = 3000

// program drives the full download of `image` (raw .bin or wrapped BLBT .img)
// over an open ISO-TP channel. Milestones + block progress go to the sink.
// The final 0x11 reset's positive response can legitimately be missed if the
// ECU resets fast — treated as success with a note, not an error.
pub fn program(mut ch isotp.Channel, image []u8, opts Opts, mut sink Sink) ! {
	// a pre-wrapped mkimage .img (starts 'BLBT') transfers as-is — mkimage
	// owns the target layout (vector padding); raw .bins get the header here.
	mut blob := []u8{}
	if image.len > 4 && image[0] == 0x42 && image[1] == 0x4C && image[2] == 0x42
		&& image[3] == 0x54 {
		blob = image.clone()
		sink.note('wrapped image (BLBT) — transferring as-is')
	} else {
		blob << make_header(image, opts.sw_version)
		blob << image
		sink.note('raw image — header added (sw_version ${opts.sw_version})')
	}
	total := u32(blob.len)
	sink.note('${blob.len} bytes -> 0x${opts.base.hex()}')

	mut c := uds.new_client(ch)
	c.timeout_ms = first_answer_ms
	ask(mut c, [u8(0x10), 0x02], 'programming session')!
	if opts.auth_seed.len == 32 {
		authenticate(mut c, opts.auth_seed, mut sink)!
	} else {
		sink.note('no auth seed — skipping 0x29 (boot must have no key baked)')
	}

	mut er := [u8(0x31), 0x01, 0xFF, 0x00]
	er << be32(opts.base)
	er << be32(total)
	err_rsp := ask(mut c, er, 'erase')!
	// 71 01 FF 00 <result>: an answer without its result has not said the erase worked
	if err_rsp.len < 5 {
		return error('erase: no routine result in ${err_rsp.hex()}')
	}
	if err_rsp[4] != 0 {
		return error('erase routine failed (result ${err_rsp[4]})')
	}
	sink.note('erased 0x${opts.base.hex()} +${total}')

	mut dl := [u8(0x34), 0x00, 0x44]
	dl << be32(opts.base)
	dl << be32(total)
	dr := ask(mut c, dl, 'request download')!
	// 74 <lengthFormatIdentifier> <maxNumberOfBlockLength, as wide as its high nibble says>: the
	// length counts the 0x36 SID and the block counter, so the data per block is two fewer
	width := if dr.len >= 2 { int(dr[1] >> 4) } else { 0 }
	if width < 1 || width > 4 || dr.len < 2 + width {
		return error('request download: bad block length field in ${dr.hex()}')
	}
	mut block_len := 0
	for i in 0 .. width {
		block_len = block_len << 8 | int(dr[2 + i])
	}
	max_block := block_len - 2
	if max_block <= 0 {
		return error('request download: bad block size ${block_len}')
	}
	nblocks := (blob.len + max_block - 1) / max_block

	mut blk := u8(1)
	mut off := 0
	mut done := 0
	for off < blob.len {
		mut n := blob.len - off
		if n > max_block {
			n = max_block
		}
		mut td := []u8{cap: 2 + n}
		td << u8(0x36)
		td << blk
		td << blob[off..off + n]
		ask(mut c, td, 'transfer block ${blk}')!
		off += n
		blk++
		done++
		sink.block(done, nblocks)
	}
	ask(mut c, [u8(0x37)], 'transfer exit')!
	sink.note('transferred ${blob.len} bytes in ${done} blocks')

	cr := ask(mut c, [u8(0x31), 0x01, 0xFF, 0x01], 'check image')!
	if cr.len < 5 || cr[4] != 0 {
		return error('image check FAILED on the ECU — not marked valid')
	}
	sink.note('image verified + marked valid')

	c.raw([u8(0x11), 0x01]) or {
		// the boot drains its Tx FIFO then resets; on a fast reset the 0x51 can still be lost —
		// the app appearing on the bus is the real ack. A REFUSAL is not that: the boot said no
		// and is still in the boot manager.
		if err is uds.NegativeResponse {
			return step_error('ecu reset', err)
		}
		sink.note('ECU reset sent (response lost to the reset — normal)')
		return
	}
	sink.note('ECU reset — done')
}
