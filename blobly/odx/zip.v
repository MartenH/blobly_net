module odx

import blobly.inflate
import encoding.binary
import hash.crc32

// zip.v — the entries of a ZIP archive, which is what a PDX (ISO 22901-1's packaged ODX) is: the
// central directory read from the end of the file, each entry stored or deflated (and inflated no
// further than its stated size), its CRC-32 and size checked. ZIP64, encryption and any other
// compression method are refused by name.

// ZipEntry is one file of an archive: its name as the archive spells it, and its bytes.
pub struct ZipEntry {
pub:
	name string
	data []u8
}

// max_zip_entry bounds one entry's inflated size: a PDX's ODX documents are text of a few MB.
const max_zip_entry = 256 * 1024 * 1024

const zip_eocd_sig = u32(0x06054b50)
const zip_central_sig = u32(0x02014b50)
const zip_local_sig = u32(0x04034b50)

// read_zip reads every file entry of the archive `data` (directories left out), in directory order.
pub fn read_zip(data []u8) ![]ZipEntry {
	eocd := find_eocd(data) or { return error('not a ZIP archive (no end of central directory)') }
	count := int(binary.little_endian_u16_at(data, eocd + 10))
	cd_size := int(binary.little_endian_u32_at(data, eocd + 12))
	cd_off := int(binary.little_endian_u32_at(data, eocd + 16))
	if count == 0xFFFF || u32(cd_off) == 0xFFFF_FFFF {
		return error('a ZIP64 archive, which is not read here')
	}
	if cd_off < 0 || cd_size < 0 || cd_off + cd_size > eocd {
		return error('the central directory lies outside the archive')
	}
	mut out := []ZipEntry{}
	mut at := cd_off
	for _ in 0 .. count {
		if at + 46 > eocd || binary.little_endian_u32_at(data, at) != zip_central_sig {
			return error('a central directory entry is broken at byte ${at}')
		}
		flags := binary.little_endian_u16_at(data, at + 8)
		method := binary.little_endian_u16_at(data, at + 10)
		crc := binary.little_endian_u32_at(data, at + 16)
		packed_size := i64(binary.little_endian_u32_at(data, at + 20))
		plain_size := i64(binary.little_endian_u32_at(data, at + 24))
		nlen := int(binary.little_endian_u16_at(data, at + 28))
		xlen := int(binary.little_endian_u16_at(data, at + 30))
		clen := int(binary.little_endian_u16_at(data, at + 32))
		local := i64(binary.little_endian_u32_at(data, at + 42))
		if at + 46 + nlen > eocd {
			return error('a central directory entry is broken at byte ${at}')
		}
		name := data[at + 46..at + 46 + nlen].bytestr()
		at += 46 + nlen + xlen + clen
		if name.ends_with('/') {
			continue // a directory
		}
		if flags & 1 != 0 {
			return error('${name}: encrypted, which is not read here')
		}
		if plain_size > max_zip_entry {
			return error('${name}: ${plain_size} bytes inflated, past the ${max_zip_entry} read here')
		}
		if local + 30 > data.len || binary.little_endian_u32_at(data, int(local)) != zip_local_sig {
			return error('${name}: its local header is not where the directory says')
		}
		l := int(local)
		start := i64(l) + 30 + i64(binary.little_endian_u16_at(data, l + 26)) +
			i64(binary.little_endian_u16_at(data, l + 28))
		if start + packed_size > data.len {
			return error('${name}: its data runs past the end of the archive')
		}
		raw := data[int(start)..int(start + packed_size)]
		body := match method {
			0 { raw.clone() }
			8 {
				inflate.raw(raw, int(plain_size)) or { return error('${name}: ${err}') }
			}
			else { return error('${name}: compression method ${method}, which is not read here') }
		}
		if i64(body.len) != plain_size {
			return error('${name}: ${body.len} bytes, the directory says ${plain_size}')
		}
		if crc32.sum(body) != crc {
			return error('${name}: its CRC-32 does not match')
		}
		out << ZipEntry{name, body}
	}
	return out
}

// find_eocd is the offset of the end-of-central-directory record, searched back from the end over
// the longest comment a ZIP may carry.
fn find_eocd(data []u8) ?int {
	if data.len < 22 {
		return none
	}
	lowest := if data.len - 22 - 0xFFFF > 0 { data.len - 22 - 0xFFFF } else { 0 }
	for i := data.len - 22; i >= lowest; i-- {
		if binary.little_endian_u32_at(data, i) == zip_eocd_sig {
			return i
		}
	}
	return none
}
