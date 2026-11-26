module player

import blobly.canlog
import blobly.mf4
import os

// RowReader is a recording read a row at a time in the order its loader puts the rows: an MF4
// stream or a candump line stream. What the Chunker's passes read through.
interface RowReader {
mut:
	next(mut log canlog.Log) ?canlog.Row
	failure() string // the read that ended the rows early; '' at a clean end
	unplaced() int   // rows the reader could not read where the loader reads them
	size() u64       // the bytes it reads
	// the file's modification time at the open, which a later pass must match; 0 for a candump
	// file, which is written by appending and read to a stated size, so a file still being
	// recorded is not refused
	mtime() i64
	close()
}

struct Mf4Rows {
mut:
	src    &mf4.FileSource // on the heap: `stream` reads through it
	stream mf4.Stream
	mtime  i64
}

fn (mut m Mf4Rows) next(mut log canlog.Log) ?canlog.Row {
	return m.stream.next(mut log)
}

fn (mut m Mf4Rows) failure() string {
	return m.stream.err
}

fn (mut m Mf4Rows) unplaced() int {
	return m.stream.out_of_order
}

fn (mut m Mf4Rows) size() u64 {
	return m.src.size()
}

fn (mut m Mf4Rows) mtime() i64 {
	return m.mtime
}

fn (mut m Mf4Rows) close() {
	m.src.close()
}

struct LogRows {
mut:
	s &canlog.LineStream
}

fn (mut l LogRows) next(mut log canlog.Log) ?canlog.Row {
	return l.s.next(mut log)
}

fn (mut l LogRows) failure() string {
	return l.s.err
}

// rows out of time order, and the lines too long to read, which the loader reads
fn (mut l LogRows) unplaced() int {
	return l.s.out_of_order + l.s.long_lines
}

fn (mut l LogRows) size() u64 {
	return l.s.size
}

fn (mut l LogRows) mtime() i64 {
	return 0
}

fn (mut l LogRows) close() {
	l.s.close()
}

// open_rows opens `path` for reading row by row: an MDF file (mf4.is_mdf_file) through its
// stream, whole; anything else as a candump file, its first `upto` bytes (canlog.whole_file:
// all it has now).
fn open_rows(path string, upto u64) !RowReader {
	if mf4.is_mdf_file(path) {
		mtime := os.file_last_mod_unix(path)
		mut src := mf4.open_file_source(path)!
		s := mf4.open_stream(mut src) or {
			src.close()
			return err
		}
		return RowReader(Mf4Rows{
			src:    src
			stream: s
			mtime:  mtime
		})
	}
	return RowReader(LogRows{
		s: canlog.open_line_stream_upto(path, upto)!
	})
}
