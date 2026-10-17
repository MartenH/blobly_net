module flatxml

import os

// Reading a document's source and writing files, the parts every platform shares. The system
// calls are in source_nix.c.v and source_windows.c.v: map_bytes / unmap_file, sys_create,
// sys_write, sys_close, sys_sync, replace_file and sync_dir.

// Node and attribute offsets are stored as u32, so a document must be smaller than 4 GiB.
pub const max_src_len = int(u32(0xFFFF_FFFF))

// map_file makes the file at path readable in memory, read-only, until unmap_file.
fn map_file(path string) !(&u8, int) {
	if !os.is_file(path) {
		return error('${path}: not a file')
	}
	size := int(os.file_size(path))
	if size == 0 {
		return error('${path}: empty file')
	}
	if size > max_src_len {
		return error('${path}: files of 4 GiB or more are not supported (offsets are u32)')
	}
	return map_bytes(path, size)!, size
}

// FileOut is a file opened for writing, whose every write and close is checked.
struct FileOut {
	path string
mut:
	fd i32 = -1
}

// create_file creates path, which must not exist. With keep, it gets keep's permission bits (those
// of the file it will replace) where the platform has them; without, it is made as any new file.
fn create_file(path string, keep ?u32) !FileOut {
	fd := sys_create(path, keep)
	if fd < 0 {
		return error('${path}: cannot create file')
	}
	return FileOut{
		path: path
		fd:   fd
	}
}

// write writes buf, at most 1 GiB per call.
fn (mut f FileOut) write(buf []u8) !int {
	n := sys_write(f.fd, buf.data, if buf.len > 1 << 30 { 1 << 30 } else { buf.len })
	if n <= 0 {
		return error('${f.path}: write failed')
	}
	return n
}

fn (mut f FileOut) close() ! {
	if f.fd >= 0 && sys_close(f.fd) != 0 {
		f.fd = -1
		return error('${f.path}: write failed')
	}
	f.fd = -1
}

// sync_and_close puts the file's contents on disk, then closes it.
fn (mut f FileOut) sync_and_close() ! {
	if sys_sync(f.fd) != 0 {
		f.close() or {}
		return error('${f.path}: write failed')
	}
	f.close()!
}
