module player

import canlog
import mf4
import time

// Chunker plays an MF4 recording a chunk at a time instead of loading it whole (#172). Only the
// chunks read ahead are resident, so a recording's size stops deciding whether it can be
// replayed — in memory, a loaded recording costs about fifteen times its file size.
//
// It is the in-memory path made incremental, not a second implementation of it: the rows come
// from mf4.Stream, which yields them in the loader's order for a writer whose disorder is within
// the stream's look-ahead window (a file where it is not is refused at open), and the decision
// to play each one is the same Planner build_multi_log runs. The planner's walkers hold J1939
// transport sessions, and a session may straddle any chunk boundary, so the planner lives for
// the whole pass. For the same reason a seek does not jump: it starts a new pass and plans from
// the top, skipping what lies before the target. A decision depends on everything before it, and
// replanning from the start is the one way to reach the in-memory answer. That costs a read up
// to the target on a seek. A seek index would remove that cost, and is left out until a
// measured stall asks for one.
//
// The reading happens on a thread of its own, never inside due(). Measured on real recordings,
// one read of the stream can take 60 ms — a compressed block is inflated whole — and on the
// worker's tick that is 60 ms of frames sent late and then all at once. The reader keeps up to
// `chunk_ahead` chunks queued, which covers such a stall many times over.
pub const chunk_rows = 256
pub const chunk_ahead = 64

// Chunk is one read of the recording: rows of their own (a batch the player hands out holds
// views into them, so the reader never writes them again) and the play order among them. A chunk
// with `end` set carries no rows: the pass is over, `before` rows were kept in it.
struct Chunk {
	log    canlog.Log
	sel    []u32
	before int // rows of this pass kept before this chunk's first
	end    bool
	err    string
}

@[heap]
pub struct Chunker {
	path  string
	specs []BusSpec
	rows  int // rows read per chunk
pub:
	buses []BusPlan // the whole-file census, from the pass open_chunker makes
	t0_s  f64
	end_s f64
	kept  int // rows a pass plays
pub mut:
	err string // the first read error; the pass ends there, as a truncated file's would
mut:
	ch chan Chunk
}

// open_chunker reads `path` through once, keeping nothing, for the census and span
// build_multi_log would report — replay needs both before its first frame: the span places every
// frame in time, and the census is what the Replay panel shows — and starts the reader.
//
// A file the stream cannot put in the loader's order (`out_of_order`: an unsorted group whose
// disorder exceeds the look-ahead) is refused: a row handed out after a later one would be sent
// late and out of sequence, so such a file is replayed from memory instead.
pub fn open_chunker(path string, specs []BusSpec, rows int) !&Chunker {
	if rows <= 0 {
		return error('chunk size must be positive, not ${rows}')
	}
	mut src := mf4.open_source(path)!
	defer {
		src.close()
	}
	mut s := mf4.open_stream(mut src)!
	mut p := new_planner(specs)
	mut raw := canlog.Log{}
	mut kept := 0
	for {
		r := s.next(mut raw) or { break }
		raw.rows.clear()
		raw.rows << r
		if p.keep(&raw, 0) {
			kept++
		}
	}
	if s.err != '' {
		return error(s.err)
	}
	if s.out_of_order > 0 {
		return error('${s.out_of_order} rows out of time order; not streamable')
	}
	mut c := &Chunker{
		path:  path
		specs: specs
		rows:  rows
		buses: p.plans()
		t0_s:  p.t0
		end_s: p.end
		kept:  kept
		ch:    chan Chunk{cap: chunk_ahead}
	}
	spawn read_passes(c.job(0), c.ch)
	return c
}

// rewind abandons the reader and starts another, its first pass `pos_s` seconds in.
fn (mut c Chunker) rewind(pos_s f64) {
	c.ch.close()
	c.ch = chan Chunk{cap: chunk_ahead}
	spawn read_passes(c.job(pos_s), c.ch)
}

// ReadJob is what the reader needs, handed over as one struct: V's `spawn` passes an f64
// argument as zero (measured: a seek to 0.03 s arrived at the reader as 0.0), a struct intact.
struct ReadJob {
	path  string
	specs []BusSpec
	rows  int
	t0    f64
	skip  f64
}

fn (c &Chunker) job(skip f64) ReadJob {
	return ReadJob{
		path:  c.path
		specs: c.specs
		rows:  c.rows
		t0:    c.t0_s
		skip:  skip
	}
}

// take is the next chunk: waiting for it when `wait`, or none when it is not read yet.
fn (mut c Chunker) take(wait bool) ?Chunk {
	if wait {
		ck := <-c.ch or { return none }
		return ck
	}
	mut ck := Chunk{}
	if c.ch.try_pop(mut ck) == .success {
		return ck
	}
	return none
}

// close ends the reader.
pub fn (mut c Chunker) close() {
	c.ch.close()
}

// read_passes is the reader: pass after pass, each ending in an `end` chunk, so a loop wrap finds
// the next pass already queued. It holds its own file and planner and shares nothing but the
// channel, and it ends when the channel is closed.
fn read_passes(job ReadJob, ch chan Chunk) {
	mut skip := job.skip
	for {
		mut r := open_pass(job.path, job.specs, job.rows, job.t0, skip) or {
			offer(ch, Chunk{
				end: true
				err: err.msg()
			})
			ch.close() // nothing more is coming: a player waiting on the next pass is told so
			return
		}
		for {
			ck := r.next() or { break }
			if !offer(ch, ck) {
				r.src.close()
				return
			}
		}
		r.src.close()
		if !offer(ch, Chunk{ end: true, before: r.counted, err: r.stream.err }) {
			return
		}
		if r.stream.err != '' {
			ch.close() // the next pass would stop at the same place
			return
		}
		skip = 0
	}
}

// offer queues `ck`, waiting while the queue is full; false once the channel is closed.
fn offer(ch chan Chunk, ck Chunk) bool {
	for {
		match ch.try_push(ck) {
			.success { return true }
			.closed { return false }
			.not_ready { time.sleep(2 * time.millisecond) }
		}
	}
	return false
}

// Pass is one read of the recording from the top.
struct Pass {
	rows int
	t0   f64
	skip f64 // rows earlier than this many seconds into the recording are planned, not played
mut:
	src     mf4.FileSource
	stream  mf4.Stream
	raw     canlog.Log // the stream's labels, kept across chunks; the rows of the chunk being read
	planner Planner
	counted int // rows kept so far, played or skipped
	eof     bool
}

fn open_pass(path string, specs []BusSpec, rows int, t0 f64, skip f64) !Pass {
	mut src := mf4.open_source(path)!
	s := mf4.open_stream(mut src) or {
		src.close()
		return err
	}
	return Pass{
		rows:    rows
		t0:      t0
		skip:    skip
		src:     src
		stream:  s
		planner: new_planner(specs)
	}
}

// next reads until a chunk holds a row to play; none at the end of the pass. A chunk that played
// nothing handed nothing out, so its rows are reused.
fn (mut r Pass) next() ?Chunk {
	mut fresh := true
	for !r.eof {
		if fresh {
			r.raw.rows = []canlog.Row{cap: r.rows}
			fresh = false
		} else {
			r.raw.rows.clear()
		}
		mut sel := []u32{}
		mut before := 0
		for r.raw.rows.len < r.rows {
			row := r.stream.next(mut r.raw) or {
				r.eof = true
				break
			}
			r.raw.rows << row
			i := r.raw.rows.len - 1
			if !r.planner.keep(&r.raw, i) {
				continue
			}
			// seek's own rule, spelled the same way: the first row at or after the position
			if row.t_s - r.t0 >= r.skip {
				if sel.len == 0 {
					before = r.counted
				}
				sel << u32(i)
			}
			r.counted++
		}
		if sel.len > 0 {
			// resolve replaces dst rather than writing into it, so the chunk may share it
			return Chunk{
				log:    r.raw.relabelled(r.planner.dst)
				sel:    sel
				before: before
			}
		}
	}
	return none
}

// new_player_chunked plays what `c` reads, over the source recording's span.
pub fn new_player_chunked(c &Chunker, speed f64, repeat bool) Player {
	mut p := new_player_log(canlog.Log{}, []u32{}, speed, repeat, c.t0_s, c.end_s)
	p.chunks = c
	p.open = true
	p.anchor = true
	return p
}
