module flatxml

import os
import time

#include <io.h>
#include <fcntl.h>
#include <sys/stat.h>

// C's int is 32 bits; V3's int is 64, so C returns are declared i32.
fn C._wopen(path &u16, flags i32, mode i32) i32
fn C._write(fd i32, buf voidptr, n u32) i32
fn C._close(fd i32) i32
fn C._commit(fd i32) i32
fn C.MoveFileExW(src &u16, dst &u16, flags u32) i32
fn C.ReplaceFileW(replaced &u16, replacement &u16, backup &u16, flags u32, exclude voidptr, reserved voidptr) i32
fn C.GetFileAttributesW(path &u16) u32

// map_bytes reads size bytes of the file at path into memory that unmap_file releases (Windows
// has no mmap of the POSIX kind, and a mapping through the Windows API would keep the file open
// and so stop it being replaced).
fn map_bytes(path string, size int) !&u8 {
	mut f := os.open(path) or { return error('${path}: cannot open file') }
	defer {
		f.close()
	}
	p := unsafe { &u8(C.malloc(usize(size))) }
	if p == unsafe { nil } {
		return error('${path}: out of memory')
	}
	mut got := 0
	for got < size {
		n := f.read_into_ptr(unsafe { p + got }, size - got) or { 0 }
		if n <= 0 {
			unsafe { C.free(p) }
			return error('${path}: cannot read file')
		}
		got += n
	}
	return p
}

fn unmap_file(p &u8, _ int) {
	unsafe { C.free(voidptr(p)) }
}

// sys_create creates path exclusively for binary writing. Windows has no permission bits to
// keep: replace_file keeps the replaced file's attributes and access control instead.
fn sys_create(path string, _ ?u32) i32 {
	w := path.replace('/', '\\').to_wide()
	defer {
		unsafe { free(w) }
	}
	return C._wopen(w, C._O_WRONLY | C._O_CREAT | C._O_EXCL | C._O_BINARY, C._S_IREAD | C._S_IWRITE)
}

fn sys_write(fd i32, p voidptr, n int) int {
	return int(C._write(fd, p, u32(n)))
}

fn sys_close(fd i32) i32 {
	return C._close(fd)
}

fn sys_sync(fd i32) i32 {
	return C._commit(fd)
}

// the Windows errors a replacement is tried again on: another process (a virus scanner, the
// search indexer) has one of the files open for a moment
const replace_retry_codes = [u32(5), 32, 33, 1175, 1176] // access denied, sharing and lock

// violations, ReplaceFileW unable to remove the replaced file or to move the replacement

// replace_file puts tmp in target's place. An existing target is replaced by ReplaceFileW, which
// keeps its attributes and access control; a read-only one is refused. A missing target is moved
// to with MoveFileExW. A file another process holds open for a moment is tried again, for up to
// about two and a half seconds; an error says Windows' error code.
fn replace_file(tmp string, target string) ! {
	wt := target.replace('/', '\\').to_wide()
	wn := tmp.replace('/', '\\').to_wide()
	defer {
		unsafe {
			free(wt)
			free(wn)
		}
	}
	attrs := C.GetFileAttributesW(wt)
	mut exists := attrs != u32(0xFFFF_FFFF)
	if exists && attrs & 0x1 != 0 { // FILE_ATTRIBUTE_READONLY
		return error('${target}: read-only, not replaced')
	}
	mut wait := 10
	for attempt := 0; true; attempt++ {
		ok := if exists {
			// REPLACEFILE_IGNORE_MERGE_ERRORS
			C.ReplaceFileW(wt, wn, unsafe { nil }, 0x2, unsafe { nil }, unsafe { nil }) != 0
		} else {
			C.MoveFileExW(wn, wt, 0x8) != 0 // MOVEFILE_WRITE_THROUGH
		}
		if ok {
			return
		}
		code := C.GetLastError()
		if exists && code == 2 { // ERROR_FILE_NOT_FOUND: the target went meanwhile
			exists = false
			continue
		}
		if code !in replace_retry_codes || attempt >= 8 {
			return error('${target}: cannot replace it with ${tmp} (Windows error ${code})')
		}
		time.sleep(wait * time.millisecond)
		wait *= 2
	}
}

// sync_dir has no Windows counterpart: a directory cannot be flushed like a file. The rename is
// recorded by the file system's own journal, so after a crash the target is the old file or the
// new one, but a rename made just before a power loss may be lost.
fn sync_dir(_ string) ! {
}
