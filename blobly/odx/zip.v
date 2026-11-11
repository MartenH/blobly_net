module odx

import blobly.inflate
import encoding.binary
import hash.crc32

// zip.v — the entries of a ZIP archive, which is what a PDX (ISO 22901-1's packaged ODX) is: the
// central directory read from the end of the file, each entry stored or deflated (and inflated no
// further than its stated size), its CRC-32 and size checked. ZIP64, encryption and any other
// compression method are refused by name. Only the entries a caller keeps are inflated, and no more
// than `max_zip_total` bytes of them in all.

// ZipEntry is one file of an archive: its name as the archive spells it, and its bytes.
pub struct ZipEntry {
pub:
	name string
	data []u8
}

// ZipRead is what `read_zip` read: the entries kept, and the names of the files it left unread.
pub struct ZipRead {
pub:
	entries []ZipEntry
	skipped []string
}

// max_zip_entry bounds one entry's inflated size: a PDX's ODX documents are text of a few MB.
const max_zip_entry = 256 * 1024 * 1024

// max_zip_total bounds the inflated size of every entry kept from one archive together.
const max_zip_total = i64(512) * 1024 * 1024

const zip_eocd_sig = u32(0x06054b50)
const zip_central_sig = u32(0x02014b50)
const zip_local_sig = u32(0x04034b50)

// ZipRecord is one central directory record of a file entry.
struct ZipRecord {
	name   string
	method u16
	crc    u32
	packed i64
	plain  i64
	local  i64
}

// read_zip reads the file entries of the archive `data` whose name `keep` accepts (directories left
// out), in directory order; the rest are named in `skipped` and never inflated. The whole directory
// is checked before anything is inflated: a local header two records name, or kept entries that
// state more than `max_zip_total` bytes together, refuse the archive.
pub fn read_zip(data []u8, keep fn (string) bool) !ZipRead {
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
	mut kept := []ZipRecord{}
	mut skipped := []string{}
	mut locals := map[i64]string{}
	mut total := i64(0)
	mut at := cd_off
	for _ in 0 .. count {
		if at + 46 > eocd || binary.little_endian_u32_at(data, at) != zip_central_sig {
			return error('a central directory entry is broken at byte ${at}')
		}
		flags := binary.little_endian_u16_at(data, at + 8)
		nlen := int(binary.little_endian_u16_at(data, at + 28))
		xlen := int(binary.little_endian_u16_at(data, at + 30))
		clen := int(binary.little_endian_u16_at(data, at + 32))
		local := i64(binary.little_endian_u32_at(data, at + 42))
		if at + 46 + nlen > eocd {
			return error('a central directory entry is broken at byte ${at}')
		}
		rec := ZipRecord{
			name:   data[at + 46..at + 46 + nlen].bytestr()
			method: binary.little_endian_u16_at(data, at + 10)
			crc:    binary.little_endian_u32_at(data, at + 16)
			packed: i64(binary.little_endian_u32_at(data, at + 20))
			plain:  i64(binary.little_endian_u32_at(data, at + 24))
			local:  local
		}
		at += 46 + nlen + xlen + clen
		if rec.name.ends_with('/') {
			continue // a directory
		}
		if other := locals[local] {
			return error('${rec.name}: its local header is also ${other}\'s')
		}
		locals[local] = rec.name
		if !keep(rec.name) {
			skipped << rec.name
			continue
		}
		if flags & 1 != 0 {
			return error('${rec.name}: encrypted, which is not read here')
		}
		if rec.plain > max_zip_entry {
			return error('${rec.name}: ${rec.plain} bytes inflated, past the ${max_zip_entry} read here')
		}
		total += rec.plain
		if total > max_zip_total {
			return error('the entries read state ${total} bytes inflated by ${rec.name}, past the ${max_zip_total} read here in all')
		}
		kept << rec
	}
	mut out := []ZipEntry{cap: kept.len}
	for rec in kept {
		out << ZipEntry{rec.name, zip_body(data, rec)!}
	}
	return ZipRead{out, skipped}
}

// zip_body is the bytes of the entry `rec`, inflated no further than its stated size and checked.
fn zip_body(data []u8, rec ZipRecord) ![]u8 {
	name := rec.name
	if rec.local + 30 > data.len
		|| binary.little_endian_u32_at(data, int(rec.local)) != zip_local_sig {
		return error('${name}: its local header is not where the directory says')
	}
	l := int(rec.local)
	start := i64(l) + 30 + i64(binary.little_endian_u16_at(data, l + 26)) +
		i64(binary.little_endian_u16_at(data, l + 28))
	if start + rec.packed > data.len {
		return error('${name}: its data runs past the end of the archive')
	}
	raw := data[int(start)..int(start + rec.packed)]
	body := match rec.method {
		0 { raw.clone() }
		8 {
			inflate.raw(raw, int(rec.plain)) or { return error('${name}: ${err}') }
		}
		else { return error('${name}: compression method ${rec.method}, which is not read here') }
	}
	if i64(body.len) != rec.plain {
		return error('${name}: ${body.len} bytes, the directory says ${rec.plain}')
	}
	if crc32.sum(body) != rec.crc {
		return error('${name}: its CRC-32 does not match')
	}
	return body
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
