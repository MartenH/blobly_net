module player

import blobly.canlog
import blobly.mf4

// RowReader is a recording read a row at a time in the order its loader puts the rows: an MF4
// stream or a candump line stream. What the Chunker's passes read through.
interface RowReader {
mut:
	next(mut log canlog.Log) ?canlog.Row
	failure() string // the read that ended the rows early; '' at a clean end
	disorder() int   // rows the reader could not put in the loader's order
	size() u64       // the size of the handle opened
	close()
}

struct Mf4Rows {
mut:
	src    &mf4.FileSource // on the heap: `stream` reads through it
	stream mf4.Stream
}

fn (mut m Mf4Rows) next(mut log canlog.Log) ?canlog.Row {
	return m.stream.next(mut log)
}

fn (mut m Mf4Rows) failure() string {
	return m.stream.err
}

fn (mut m Mf4Rows) disorder() int {
	return m.stream.out_of_order
}

fn (mut m Mf4Rows) size() u64 {
	return m.src.size()
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

fn (mut l LogRows) disorder() int {
	return l.s.out_of_order
}

fn (mut l LogRows) size() u64 {
	return l.s.size
}

fn (mut l LogRows) close() {
	l.s.close()
}

// open_rows opens `path` for reading row by row: an MDF file (mf4.is_mdf_file) through its
// stream, anything else as a candump file.
fn open_rows(path string) !RowReader {
	if mf4.is_mdf_file(path) {
		mut src := mf4.open_file_source(path)!
		s := mf4.open_stream(mut src) or {
			src.close()
			return err
		}
		return RowReader(Mf4Rows{
			src:    src
			stream: s
		})
	}
	return RowReader(LogRows{
		s: canlog.open_line_stream(path)!
	})
}
