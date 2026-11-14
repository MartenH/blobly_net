module mf4

import os

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
	// The first read that FAILED (not one that came up short at the end), '' while none. The
	// header helpers below read through `bytes_at`, which zero-fills what it did not get — right
	// for a truncated header, wrong for a failed read, which turned a link count into 0 and a
	// recording into an empty one that parsed clean (codex on #342 round 6). The two readers
	// ask this once the headers are walked, so an I/O failure there is the parse's failure.
	failure() string
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

pub fn (mut m MemSource) failure() string {
	return ''
}

// FileSource is a ByteSource over an open file. One per thread: the file has one position.
pub struct FileSource {
mut:
	f   os.File
	sz  u64
	err string
}

// open_file_source is open_source on the heap: a Stream keeps a reference to its source, so a
// source that outlives the function it was opened in must not live in that function's frame.
pub fn open_file_source(path string) !&FileSource {
	s := open_source(path)!
	return &FileSource{
		...s
	}
}

pub fn open_source(path string) !FileSource {
	mut f := os.open(path)!
	// the size of the HANDLE, not of the path: a path replaced between the open and a lookup by
	// name describes another file, and every offset bound would then be the wrong file's
	// (codex on #342 round 11)
	f.seek(0, .end) or {
		f.close()
		return err
	}
	sz := f.tell() or {
		f.close()
		return err
	}
	f.seek(0, .start) or {
		f.close()
		return err
	}
	return FileSource{
		f:  f
		sz: u64(sz)
	}
}

pub fn (mut f FileSource) read_at(off u64, mut dst []u8) !int {
	if off >= f.sz {
		return 0
	}
	// read_bytes_into answers short at EOF; short means EOF here, and the helpers treat what was
	// not read as zero. A FAILURE is kept and returned: the record readers stop on it, the
	// header walk asks `failure()` when it is done.
	return f.f.read_bytes_into(off, mut dst) or {
		if f.err == '' {
			f.err = 'read at ${off}: ${err}'
		}
		return error('read at ${off}: ${err}')
	}
}

pub fn (mut f FileSource) size() u64 {
	return f.sz
}

pub fn (mut f FileSource) failure() string {
	return f.err
}

pub fn (mut f FileSource) close() {
	f.f.close()
}

// bytes_at reads n bytes at off; what lies past the end reads as zero. Offsets are u64 end to
// end — a recording of tens of GB keeps its later blocks past 2^31, and an `int` there was the
// hazard docs/streaming_replay.md names — and only a bounded read's LENGTH is an int.
fn bytes_at(mut src ByteSource, off u64, n int) []u8 {
	mut out := []u8{len: n}
	if n <= 0 {
		return out
	}
	src.read_at(off, mut out) or {}
	return out
}

// exact_at is bytes_at that FAILS rather than zero-fills: for a read whose zero would be
// believed — a DZ block's header and its compressed bytes, read while the records stream and
// long after the header walk asked `failure()` (codex on #342 round 11).
fn exact_at(mut src ByteSource, off u64, n int) ![]u8 {
	mut out := []u8{len: n}
	if n <= 0 {
		return out
	}
	got := src.read_at(off, mut out) or { return error('read at ${off}: ${err}') }
	if got < n {
		return error('short read at ${off}: ${got} of ${n} bytes')
	}
	return out
}

fn u8_at(mut src ByteSource, off u64) u8 {
	return u8(le_at(mut src, off, 1))
}

fn u16_at(mut src ByteSource, off u64) u16 {
	return u16(le_at(mut src, off, 2))
}

fn u32_at(mut src ByteSource, off u64) u32 {
	return u32(le_at(mut src, off, 4))
}

fn u64_at(mut src ByteSource, off u64) u64 {
	return le_at(mut src, off, 8)
}

// le_at is bytes_at for a little-endian integer of n <= 8 bytes, read into a stack buffer
// rather than a fresh array: the header walk asks this for every link and field it reads.
// What was not read is zero, as in bytes_at.
fn le_at(mut src ByteSource, off u64, n int) u64 {
	mut b := [8]u8{}
	// a view of b, not a copy: slicing a fixed array copies it, and the read would land there
	mut view := unsafe { (&b[0]).vbytes(n) }
	src.read_at(off, mut view) or {}
	mut v := u64(0)
	for i in 0 .. n {
		v |= u64(unsafe { b[i] }) << (8 * i)
	}
	return v
}
