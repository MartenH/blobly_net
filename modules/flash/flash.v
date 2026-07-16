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
import isotp
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
fn authenticate(mut ch isotp.Channel, seed []u8, mut sink Sink) ! {
	cr := ask(mut ch, [u8(0x29), 0x01], 'request challenge')!
	if cr.len < 2 + 32 {
		return error('request challenge: short response')
	}
	challenge := cr[2..34].clone()
	priv := ed.new_key_from_seed(seed)
	sig := ed.sign(priv, challenge) or { return error('sign challenge: ${err}') }
	mut proof := [u8(0x29), 0x02]
	proof << sig
	ask(mut ch, proof, 'send proof')!
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

fn ask(mut ch isotp.Channel, req []u8, what string) ![]u8 {
	rsp := isotp.request(mut ch, req, 3000) or { return error('${what}: ${err}') }
	if rsp.len >= 3 && rsp[0] == 0x7F {
		return error('${what}: NRC 0x${rsp[2].hex()}')
	}
	if rsp.len < 1 || rsp[0] != req[0] + 0x40 {
		return error('${what}: unexpected response ${rsp.hex()}')
	}
	return rsp
}

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

	ask(mut ch, [u8(0x10), 0x02], 'programming session')!
	if opts.auth_seed.len == 32 {
		authenticate(mut ch, opts.auth_seed, mut sink)!
	} else {
		sink.note('no auth seed — skipping 0x29 (boot must have no key baked)')
	}

	mut er := [u8(0x31), 0x01, 0xFF, 0x00]
	er << be32(opts.base)
	er << be32(total)
	err_rsp := ask(mut ch, er, 'erase')!
	if err_rsp.len >= 5 && err_rsp[4] != 0 {
		return error('erase routine failed (result ${err_rsp[4]})')
	}
	sink.note('erased 0x${opts.base.hex()} +${total}')

	mut dl := [u8(0x34), 0x00, 0x44]
	dl << be32(opts.base)
	dl << be32(total)
	dr := ask(mut ch, dl, 'request download')!
	if dr.len < 4 {
		return error('request download: short response')
	}
	max_block := int((u16(dr[2]) << 8 | u16(dr[3])) - 2)
	if max_block <= 0 {
		return error('request download: bad block size')
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
		ask(mut ch, td, 'transfer block ${blk}')!
		off += n
		blk++
		done++
		sink.block(done, nblocks)
	}
	ask(mut ch, [u8(0x37)], 'transfer exit')!
	sink.note('transferred ${blob.len} bytes in ${done} blocks')

	cr := ask(mut ch, [u8(0x31), 0x01, 0xFF, 0x01], 'check image')!
	if cr.len < 5 || cr[4] != 0 {
		return error('image check FAILED on the ECU — not marked valid')
	}
	sink.note('image verified + marked valid')

	ask(mut ch, [u8(0x11), 0x01], 'ecu reset') or {
		// the boot drains its Tx FIFO then resets; on a fast reset the 0x51
		// can still be lost — the app appearing on the bus is the real ack
		sink.note('ECU reset sent (response lost to the reset — normal)')
		return
	}
	sink.note('ECU reset — done')
}
