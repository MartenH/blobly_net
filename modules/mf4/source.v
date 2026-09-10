module mf4

import os
import encoding.binary

// ByteSource is where the reader gets a file's bytes: the whole image in memory (the tests build
// images in V; small files), or a file read at offsets — the shape a recording that does not
// fit in memory needs (docs/streaming_replay.md). The header walk reads a few bytes at a time
// through it; the record blocks come out of read_data_block as before. A read past the end is
// SHORT, never an error: the helpers below read zeros there, which is how a truncated header
// reads as an empty link rather than a panic.
pub interface ByteSource {
mut:
	read_at(off u64, mut dst []u8) !int
	size() u64
}

// MemSource is a ByteSource over an image already in memory.
pub struct MemSource {
pub:
	buf []u8
}

pub fn (mut m MemSource) read_at(off u64, mut dst []u8) !int {
	if off >= u64(m.buf.len) {
		return 0
	}
	mut n := dst.len
	if u64(n) > u64(m.buf.len) - off {
		n = int(u64(m.buf.len) - off)
	}
	if n > 0 {
		unsafe { vmemcpy(dst.data, &m.buf[int(off)], n) }
	}
	return n
}

pub fn (mut m MemSource) size() u64 {
	return u64(m.buf.len)
}

// FileSource is a ByteSource over an open file. One per thread: the file has one position.
pub struct FileSource {
mut:
	f  os.File
	sz u64
}

pub fn open_source(path string) !FileSource {
	return FileSource{
		f:  os.open(path)!
		sz: os.file_size(path)
	}
}

pub fn (mut f FileSource) read_at(off u64, mut dst []u8) !int {
	if off >= f.sz {
		return 0
	}
	// read_bytes_into swallows a seek failure and answers short at EOF; short means EOF here,
	// and the helpers treat what was not read as zero.
	return f.f.read_bytes_into(off, mut dst) or { 0 }
}

pub fn (mut f FileSource) size() u64 {
	return f.sz
}

pub fn (mut f FileSource) close() {
	f.f.close()
}

// bytes_at reads n bytes at off; what lies past the end reads as zero.
fn bytes_at(mut src ByteSource, off int, n int) []u8 {
	mut out := []u8{len: n}
	if n <= 0 || off < 0 {
		return out
	}
	src.read_at(u64(off), mut out) or {}
	return out
}

fn u8_at(mut src ByteSource, off int) u8 {
	return bytes_at(mut src, off, 1)[0]
}

fn u16_at(mut src ByteSource, off int) u16 {
	return binary.little_endian_u16(bytes_at(mut src, off, 2))
}

fn u32_at(mut src ByteSource, off int) u32 {
	return binary.little_endian_u32(bytes_at(mut src, off, 4))
}

fn u64_at(mut src ByteSource, off int) u64 {
	return binary.little_endian_u64(bytes_at(mut src, off, 8))
}
