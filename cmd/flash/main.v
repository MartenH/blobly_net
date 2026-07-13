module main

// flash — the host flasher: drives a blobly bootloader's UDS programming
// session (blobly_emb docs/bootloader.md) over ISO-TP on SocketCAN. Transport-
// neutral by construction on the ECU side; this tool is the CAN binding's
// client half (a DoIP client is a later sibling, same sequence).
//
//   v run cmd/flash <iface> <image.bin> [base_hex] [req_id_hex] [rsp_id_hex]
//   v run cmd/flash vcan0 app.bin 08020000 7B0 7B8
//
// The image file is RAW application bytes: this tool computes the CRC, builds
// the 64-byte blobly header (valid mark NOT set — the ECU's check routine
// writes that after verifying), and transfers header + payload.
//
// Sequence: 0x10 02 -> 0x27 seed/key -> 0x31 erase -> 0x34 -> 0x36 xN -> 0x37
// -> 0x31 check -> 0x11 reset.
import os
import isotp

const boot_magic = u32(0x54424C42) // 'BLBT'
const hdr_size = 64

fn crc32(data []u8) u32 {
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

// the same placeholder algorithm as boot.expected_key — replaced together (P5)
fn expected_key(seed u32) u32 {
	return (seed ^ 0xA5A5_A5A5) + (seed << 3 | seed >> 29)
}

fn make_header(image []u8, sw_version u32) []u8 {
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
	// bytes 32..63 stay 0xFF: the valid mark is the ECU's to write, never ours
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

fn main() {
	if os.args.len < 3 {
		eprintln('usage: flash <iface> <image.bin> [base_hex=08020000] [req=7B0] [rsp=7B8] [sw_version=1]')
		exit(2)
	}
	iface := os.args[1]
	image := os.read_bytes(os.args[2]) or {
		eprintln('flash: read ${os.args[2]}: ${err}')
		exit(1)
	}
	base := u32('0x${if os.args.len > 3 { os.args[3] } else { '08020000' }}'.u64())
	req_id := u32('0x${if os.args.len > 4 { os.args[4] } else { '7B0' }}'.u64())
	rsp_id := u32('0x${if os.args.len > 5 { os.args[5] } else { '7B8' }}'.u64())
	sw_version := u32(if os.args.len > 6 { os.args[6].u64() } else { 1 })

	mut ch := isotp.open_software(iface, req_id, rsp_id, false) or {
		eprintln('flash: open ${iface}: ${err}')
		exit(1)
	}
	defer {
		ch.close()
	}

	// a pre-wrapped mkimage .img (starts with 'BLBT') transfers as-is — mkimage
	// owns the target layout (vector padding); raw .bins get the header here.
	mut blob := []u8{}
	if image.len > 4 && image[0] == 0x42 && image[1] == 0x4C && image[2] == 0x42 && image[3] == 0x54 {
		blob = image.clone()
		println('flash: ${os.args[2]} is a wrapped image (BLBT) — transferring as-is')
	} else {
		hdr := make_header(image, sw_version)
		blob << hdr
		blob << image
	}
	total := u32(blob.len)
	println('flash: ${os.args[2]} -> ${iface} @0x${base.hex()}: ${blob.len} bytes total, sw_version ${sw_version}')

	// 1) programming session
	ask(mut ch, [u8(0x10), 0x02], 'programming session') or {
		eprintln('flash: ${err}')
		exit(1)
	}
	// 2) unlock
	seed_rsp := ask(mut ch, [u8(0x27), 0x01], 'request seed') or {
		eprintln('flash: ${err}')
		exit(1)
	}
	seed := (u32(seed_rsp[2]) << 24) | (u32(seed_rsp[3]) << 16) | (u32(seed_rsp[4]) << 8) | u32(seed_rsp[5])
	if seed != 0 {
		key := expected_key(seed)
		mut kr := [u8(0x27), 0x02]
		kr << be32(key)
		ask(mut ch, kr, 'send key') or {
			eprintln('flash: ${err}')
			exit(1)
		}
	}
	println('flash: unlocked')
	// 3) erase the target extent
	mut er := [u8(0x31), 0x01, 0xFF, 0x00]
	er << be32(base)
	er << be32(total)
	err_rsp := ask(mut ch, er, 'erase') or {
		eprintln('flash: ${err}')
		exit(1)
	}
	if err_rsp.len >= 5 && err_rsp[4] != 0 {
		eprintln('flash: erase routine failed (result ${err_rsp[4]})')
		exit(1)
	}
	println('flash: erased 0x${base.hex()} +${total}')
	// 4) request download
	mut dl := [u8(0x34), 0x00, 0x44]
	dl << be32(base)
	dl << be32(total)
	dr := ask(mut ch, dl, 'request download') or {
		eprintln('flash: ${err}')
		exit(1)
	}
	max_block := int((u16(dr[2]) << 8 | u16(dr[3])) - 2)
	// 5) transfer
	mut blk := u8(1)
	mut off := 0
	for off < blob.len {
		mut n := blob.len - off
		if n > max_block {
			n = max_block
		}
		mut td := []u8{cap: 2 + n}
		td << u8(0x36)
		td << blk
		td << blob[off..off + n]
		ask(mut ch, td, 'transfer block ${blk}') or {
			eprintln('flash: ${err}')
			exit(1)
		}
		off += n
		blk++
	}
	ask(mut ch, [u8(0x37)], 'transfer exit') or {
		eprintln('flash: ${err}')
		exit(1)
	}
	println('flash: transferred ${blob.len} bytes in ${blk - 1} blocks')
	// 6) verify + mark
	cr := ask(mut ch, [u8(0x31), 0x01, 0xFF, 0x01], 'check image') or {
		eprintln('flash: ${err}')
		exit(1)
	}
	if cr.len < 5 || cr[4] != 0 {
		eprintln('flash: image check FAILED on the ECU — not marked valid')
		exit(1)
	}
	println('flash: image verified + marked valid')
	// 7) reset
	ask(mut ch, [u8(0x11), 0x01], 'ecu reset') or {
		eprintln('flash: ${err}')
		exit(1)
	}
	println('flash: ECU reset — done')
}
