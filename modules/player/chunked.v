module player

import canlog
import mf4

// Chunker plays an MF4 recording a chunk at a time instead of loading it whole, so memory no
// longer grows with the file (a loaded recording costs about fifteen times its size).
//
// A reader thread reads the stream, decides each row with the same Planner build_multi_log uses,
// and queues chunks of rows for the Player. Reading happens off the playback tick because one
// read can take tens of milliseconds (a compressed block is inflated whole).
//
// The planner's state depends on every row before it (J1939 sessions span chunks), so a seek
// starts a new reader that plans from the top of the file and skips rows before the target.
pub const chunk_rows = 256
pub const chunk_ahead = 64

// Chunk is a block of rows and the ones among them to play. Its rows are never written again,
// because entries the player hands out are views into them. An `end` chunk marks the end of a
// pass and carries no rows.
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
	err string // the first read error; a pass ends there
mut:
	ch   chan Chunk
	more chan bool // one token per pass the player finishes; lets the reader start another
}

// open_chunker reads the file once for the census and time span, then starts the reader.
// A file whose rows the stream cannot put in time order is refused; replay it from memory.
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
	// Plan every row, keeping only the counts.
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
		more:  chan bool{cap: 4}
	}
	spawn read_passes(c.job(0), c.ch, c.more)
	return c
}

// rewind stops the reader and starts a new one at `pos_s` seconds into the recording.
fn (mut c Chunker) rewind(pos_s f64) {
	c.close()
	c.ch = chan Chunk{cap: chunk_ahead}
	c.more = chan bool{cap: 4}
	spawn read_passes(c.job(pos_s), c.ch, c.more)
}

// ReadJob is the reader's input. It is one struct because V's `spawn` passes a bare f64
// argument as zero.
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

// take returns the next chunk, waiting for it when `wait`; none if it is not ready. A closed
// channel reads as the end of the pass. Taking an end chunk lets the reader start another pass.
fn (mut c Chunker) take(wait bool) ?Chunk {
	if wait {
		ck := <-c.ch or { return Chunk{
			end: true
		} }
		if ck.end {
			c.more.try_push(true)
		}
		return ck
	}
	mut ck := Chunk{}
	match c.ch.try_pop(mut ck) {
		.success {
			if ck.end {
				c.more.try_push(true)
			}
			return ck
		}
		.closed {
			return Chunk{
				end: true
			}
		}
		.not_ready {
			return none
		}
	}
}

// close ends the reader.
pub fn (mut c Chunker) close() {
	c.ch.close()
	c.more.close()
}

// read_passes is the reader thread. It ends when the channels are closed.
fn read_passes(job ReadJob, ch chan Chunk, more chan bool) {
	mut skip := job.skip
	// Read pass after pass, each ending in an `end` chunk, at most one pass ahead of the player.
	for n := 0; true; n++ {
		if n >= 2 {
			_ := <-more or { return }
		}
		mut r := open_pass(job.path, job.specs, job.rows, job.t0, skip) or {
			offer(ch, Chunk{
				end: true
				err: err.msg()
			})
			ch.close()
			return
		}
		// Queue the pass's chunks.
		for {
			ck := r.next(ch) or { break }
			if !offer(ch, ck) {
				r.src.close()
				return
			}
		}
		r.src.close()
		// A read error ends this pass; the next pass replays the readable part again.
		if !offer(ch, Chunk{ end: true, before: r.counted, err: r.stream.err }) {
			return
		}
		skip = 0
	}
}

// offer queues `ck`, waiting while the queue is full; false once the channel is closed.
fn offer(ch chan Chunk, ck Chunk) bool {
	ch <- ck or { return false }
	return true
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

// next returns the next chunk with a row to play; none at the end of the pass, or once `ch` is
// closed (a seek abandoned this reader).
fn (mut r Pass) next(ch chan Chunk) ?Chunk {
	mut fresh := true
	// Fill chunks until one has a row to play. A chunk with none is reused.
	for !r.eof {
		if ch.closed {
			return none
		}
		if fresh {
			r.raw.rows = []canlog.Row{cap: r.rows}
			fresh = false
		} else {
			r.raw.rows.clear()
		}
		mut sel := []u32{}
		mut before := 0
		// Read up to `rows` rows, planning each and selecting those at or after the skip point.
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
			if row.t_s - r.t0 >= r.skip {
				if sel.len == 0 {
					before = r.counted
				}
				sel << u32(i)
			}
			r.counted++
		}
		if sel.len > 0 {
			// sharing dst is safe: the planner replaces it, never writes into it
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
