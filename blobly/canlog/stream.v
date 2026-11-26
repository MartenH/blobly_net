// Streaming a candump `.log`: its rows in the order a replay loads them (`time_ordered`), read
// a chunk of the file at a time instead of whole (docs/streaming_replay.md, "A candump .log").
//
// A candump file does not promise time order (a merged or hand-edited capture), and the loader
// sorts what it holds. A stream cannot sort what it has not read, so it holds the rows read
// within `lookahead_s` of the latest time read (at most `readahead_rows` of them) in a heap
// keyed (time, line), and hands out the earliest once it is that far behind. A row it could not
// put where the loader's sort puts it — one earlier than a row already handed out — is counted
// (`out_of_order`), and a replay then loads the file whole (replay.stream_differs).
module canlog

import os

// lookahead_s is how far behind the latest time read a row is held before it is handed out:
// the disorder a file may have and still stream in the loader's order.
pub const lookahead_s = 2.0

// readahead_rows bounds the rows held (80 bytes each): past it the earliest is handed out
// whatever its time, counted in `forced`.
pub const readahead_rows = 1 << 17

const read_chunk = 1 << 20

// Held is a row waiting in the heap, with its line's position for the loader's tie-break.
struct Held {
	row Row
	ord u64
}

// LineStream reads a candump file's rows in the loader's order. One per thread: the file has
// one position.
@[heap]
pub struct LineStream {
pub:
	size u64 // the size of the handle opened
pub mut:
	err            string // the read that failed; the stream ends there
	out_of_order   int    // rows handed out after a later one, or whose time is not a number
	forced         int    // rows handed out because the heap was full, not because time had passed
	max_queued     int    // the most rows held at once
	max_disorder_s f64    // the furthest a row was behind the latest time read before it
mut:
	cap    int // rows held at most
	f      os.File
	buf    []u8
	carry  []u8 // the part of a line the last chunk ended in
	pos    int
	n      int
	eof    bool // every line has been read into the heap
	heap   []Held
	ord    u64
	latest f64 // the latest time read
	read   bool
	last   f64 // the time of the last row handed out
	handed bool
}

// open_line_stream opens `path` for streaming.
pub fn open_line_stream(path string) !&LineStream {
	return open_line_stream_with(path, read_chunk, readahead_rows)
}

// open_line_stream_with is open_line_stream reading `chunk` bytes at a time and holding at most
// `cap` rows.
fn open_line_stream_with(path string, chunk int, cap int) !&LineStream {
	mut f := os.open(path)!
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
	return &LineStream{
		size: u64(sz)
		cap:  cap
		f:    f
		buf:  []u8{len: chunk}
	}
}

pub fn (mut s LineStream) close() {
	s.f.close()
}

// next is the next row in the loader's order, its bus interned into `l`'s labels — the same
// table across calls, filled in file order as the loader fills its own; none at the end or
// once a read has failed (`err`).
pub fn (mut s LineStream) next(mut l Log) ?Row {
	for s.err == '' {
		if s.heap.len > 0 {
			by_time := s.latest - s.heap[0].row.t_s >= lookahead_s
			if s.eof || by_time || s.heap.len > s.cap {
				if !s.eof && !by_time {
					s.forced++
				}
				return s.pop()
			}
		}
		if s.eof {
			return none
		}
		s.read_row(mut l)
	}
	return none
}

// read_row reads lines until one is a row, which goes into the heap, or the file ends.
fn (mut s LineStream) read_row(mut l Log) {
	for {
		if s.pos >= s.n && !s.fill() {
			s.eof = true
			if s.err == '' && s.carry.len > 0 {
				line := s.carry.bytestr()
				s.carry.clear()
				s.hold(line, mut l)
			}
			return
		}
		// a line ends at a CR, an LF or both, as split_into_lines reads one
		start := s.pos
		mut i := start
		for i < s.n && s.buf[i] != `\n` && s.buf[i] != `\r` {
			i++
		}
		if i == s.n {
			s.carry << s.buf[start..i]
			s.pos = i
			continue
		}
		s.pos = i + 1
		mut line := ''
		if s.carry.len > 0 {
			s.carry << s.buf[start..i]
			line = s.carry.bytestr()
			s.carry.clear()
		} else if i > start {
			line = s.buf[start..i].bytestr()
		}
		if line != '' && s.hold(line, mut l) {
			return
		}
	}
}

// fill reads the next chunk of the file; false at its end or on a failure (`err`).
fn (mut s LineStream) fill() bool {
	n := s.f.read(mut s.buf) or {
		if err !is os.Eof {
			s.err = 'read: ${err}'
		}
		0
	}
	s.pos = 0
	s.n = n
	return n > 0
}

// hold parses a line into the heap as the loader's parse_log would push it; false when the
// line is not a row.
fn (mut s LineStream) hold(line string, mut l Log) bool {
	e := parse_line(line) or { return false }
	b := l.intern(e.iface) or { return false }
	t := e.t_s
	if t != t {
		s.out_of_order++ // no place in a time order
	} else {
		if s.read && s.latest - t > s.max_disorder_s {
			s.max_disorder_s = s.latest - t
		}
		if !s.read || t > s.latest {
			s.latest = t
		}
		s.read = true
	}
	s.push(Held{
		row: row_of(e, b)
		ord: s.ord
	})
	s.ord++
	if s.heap.len > s.max_queued {
		s.max_queued = s.heap.len
	}
	return true
}

fn before(a &Held, b &Held) bool {
	return a.row.t_s < b.row.t_s || (a.row.t_s == b.row.t_s && a.ord < b.ord)
}

fn (mut s LineStream) push(h Held) {
	s.heap << h
	mut i := s.heap.len - 1
	for i > 0 {
		p := (i - 1) / 2
		if !before(&s.heap[i], &s.heap[p]) {
			break
		}
		s.heap[i], s.heap[p] = s.heap[p], s.heap[i]
		i = p
	}
}

fn (mut s LineStream) pop() Row {
	top := s.heap[0].row
	last := s.heap.len - 1
	s.heap[0] = s.heap[last]
	s.heap.delete_last()
	mut i := 0
	for {
		lc := 2 * i + 1
		if lc >= s.heap.len {
			break
		}
		mut m := lc
		if lc + 1 < s.heap.len && before(&s.heap[lc + 1], &s.heap[lc]) {
			m = lc + 1
		}
		if !before(&s.heap[m], &s.heap[i]) {
			break
		}
		s.heap[i], s.heap[m] = s.heap[m], s.heap[i]
		i = m
	}
	if s.handed && top.t_s < s.last {
		s.out_of_order++
	}
	s.last = top.t_s
	s.handed = true
	return top
}

// time_ordered is the recording in time order, rows of one time as the file has them: what a
// replay loads (a plan keeps file order, and the player's schedule needs time order). The rule
// the line stream reproduces.
pub fn (l Log) time_ordered() Log {
	mut sorted := true
	for i in 1 .. l.rows.len {
		if l.rows[i].t_s < l.rows[i - 1].t_s {
			sorted = false
			break
		}
	}
	if sorted {
		return l
	}
	rows := l.rows
	mut order := []int{len: rows.len, init: index}
	order.sort_with_compare(fn [rows] (a &int, b &int) int {
		ta, tb := rows[*a].t_s, rows[*b].t_s
		if ta != tb {
			return if ta < tb { -1 } else { 1 }
		}
		return *a - *b
	})
	// the rows themselves, permuted: a row carries its payload, so nothing else is copied
	return Log{
		rows:   order.map(rows[it])
		labels: l.labels
	}
}

// Survey is one pass over a candump file through the stream: its buses and frames, the span,
// and the stream's counters. Nothing of the recording is kept.
pub struct Survey {
pub mut:
	labels         []string // the buses, in the order the file first names them
	counts         []int    // frames per label
	frames         u64
	t0             f64 // the earliest and the latest time a row carried
	end            f64
	out_of_order   int
	forced         int
	max_queued     int
	max_disorder_s f64
}

// RowSink is told every row the survey reads, in the stream's order, with the label table the
// row's bus indexes. Answering false stops the survey, which then fails with `stopped`.
pub interface RowSink {
mut:
	row(labels &Log, r Row) bool
}

struct NoSink {}

fn (mut n NoSink) row(_ &Log, _ Row) bool {
	return true
}

// survey_file surveys a candump file.
pub fn survey_file(path string) !Survey {
	mut none_ := NoSink{}
	return survey_file_into(path, mut none_)
}

// survey_file_into surveys a candump file, handing every row to `sink` as it is read.
pub fn survey_file_into(path string, mut sink RowSink) !Survey {
	mut s := open_line_stream(path)!
	defer {
		s.close()
	}
	mut sv := Survey{}
	mut log := Log{}
	for {
		r := s.next(mut log) or { break }
		for sv.counts.len <= int(r.bus) {
			sv.counts << 0
		}
		if sv.frames == 0 {
			sv.t0 = r.t_s
			sv.end = r.t_s
		} else if r.t_s > sv.end {
			sv.end = r.t_s
		} else if r.t_s < sv.t0 {
			sv.t0 = r.t_s
		}
		sv.frames++
		sv.counts[r.bus]++
		if !sink.row(&log, r) {
			return error('stopped')
		}
	}
	if s.err != '' {
		return error(s.err)
	}
	sv.labels = log.labels
	sv.out_of_order = s.out_of_order
	sv.forced = s.forced
	sv.max_queued = s.max_queued
	sv.max_disorder_s = s.max_disorder_s
	return sv
}
