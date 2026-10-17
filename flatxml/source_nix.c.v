module flatxml

import os

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// C's int is 32 bits; V3's int is 64, so C callbacks and returns are declared i32.
fn C.open(path &char, flags i32, mode i32) i32
fn C.close(fd i32) i32
fn C.madvise(addr voidptr, len usize, advice i32) i32
fn C.fchmod(fd i32, mode u32) i32
fn C.fsync(fd i32) i32

// map_bytes maps size bytes of the file at path read-only into memory.
fn map_bytes(path string, size int) !&u8 {
	fd := C.open(&char(path.str), C.O_RDONLY, 0)
	if fd < 0 {
		return error('${path}: cannot open file')
	}
	p := unsafe { C.mmap(nil, usize(size), C.PROT_READ, C.MAP_PRIVATE, fd, 0) }
	C.close(fd)
	if u64(p) == max_u64 { // MAP_FAILED
		return error('${path}: cannot map file')
	}
	// One forward pass reads the whole file; ask the kernel to read ahead.
	unsafe { C.madvise(p, usize(size), C.MADV_SEQUENTIAL) }
	return unsafe { &u8(p) }
}

fn unmap_file(p &u8, len int) {
	unsafe { C.munmap(voidptr(p), usize(len)) }
}

// sys_create creates path exclusively for writing, with keep's permission bits if given.
fn sys_create(path string, keep ?u32) i32 {
	fd := C.open(&char(path.str), C.O_WRONLY | C.O_CREAT | C.O_EXCL, 0o666)
	if fd >= 0 {
		if mode := keep {
			C.fchmod(fd, mode & 0o7777)
		}
	}
	return fd
}

fn sys_write(fd i32, p voidptr, n int) int {
	return int(C.write(fd, p, usize(n)))
}

fn sys_close(fd i32) i32 {
	return C.close(fd)
}

fn sys_sync(fd i32) i32 {
	return C.fsync(fd)
}

// replace_file renames tmp to target, replacing target if it exists; the new file keeps the
// permission bits sys_create gave it.
fn replace_file(tmp string, target string) ! {
	os.rename(tmp, target)!
}

// sync_dir puts a directory's entries on disk, so a file renamed into it stays renamed.
fn sync_dir(dir string) ! {
	fd := C.open(&char(dir.str), C.O_RDONLY | C.O_DIRECTORY, 0)
	if fd < 0 {
		return error('${dir}: cannot open directory to sync it')
	}
	r := C.fsync(fd)
	C.close(fd)
	if r != 0 {
		return error('${dir}: cannot sync directory')
	}
}
