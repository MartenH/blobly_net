module player

import canlog
import mf4

// Chunker plays an MF4 recording a chunk at a time instead of loading it whole (#172). Only one
// chunk of rows is resident, so a recording's size stops deciding whether it can be replayed —
// in memory, a loaded recording costs about fifteen times its file size.
//
// It is the in-memory path made incremental, not a second implementation of it: the rows come
// from mf4.Stream, which yields them in the loader's order for a writer whose disorder is within
// the stream's look-ahead window (and counts the rows where it is not), and the decision to play each one is
// the same Planner build_multi_log runs. The planner's walkers hold J1939 transport sessions,
// and a session may straddle any chunk boundary, so the planner lives for the whole pass. For
// the same reason a seek or a loop does not jump: it reopens the stream and plans from the top,
// skipping what lies before the target. A decision depends on everything before it, and
// replanning from the start is the one way to reach the in-memory answer. That costs a read up
// to the target on a seek. A seek index would remove that cost, and is left out until a
// measured stall asks for one.
// chunk_rows is the chunk size a caller passes when it has no reason to pick another. A chunk
// is read synchronously inside due(), so its size is how long playback stalls at each boundary:
// measured at ~2.4 us a row in the GUI's unoptimised build, 256 rows is ~0.6 ms — inside the
// cadence probe's 1 ms bucket, where 4096 rows was a 10 ms stall every 200 ms of a busy capture.
pub const chunk_rows = 256

@[heap]
pub struct Chunker {
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
	src     mf4.FileSource
	stream  mf4.Stream
	raw     canlog.Log // the stream's labels, kept across chunks; the rows of the chunk being read
	planner Planner
	skip_s  f64  // rows earlier than this many seconds into the recording are planned, not played
	counted int  // rows of this pass kept so far, played or skipped
	before  int  // of those, how many precede the chunk last returned
	eof     bool
	// the chunk last returned
	chunk canlog.Log
	sel   []u32
}

// open_chunker opens `path` and reads it through once, keeping nothing, for the census and span
// build_multi_log would report. Replay needs both before its first frame: the span places every
// frame in time, and the census is what the Replay panel shows.
pub fn open_chunker(path string, specs []BusSpec, rows int) !&Chunker {
	if rows <= 0 {
		return error('chunk size must be positive, not ${rows}')
	}
	mut src := mf4.open_source(path)!
	mut s := mf4.open_stream(mut src) or {
		src.close()
		return err
	}
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
		src.close()
		return error(s.err)
	}
	mut c := &Chunker{
		specs: specs
		rows:  rows
		buses: p.plans()
		t0_s:  p.t0
		end_s: p.end
		kept:  kept
		src:   src
	}
	c.rewind(0) or {
		c.close()
		return err
	}
	return c
}

// rewind starts the pass again, `pos_s` seconds into the recording.
fn (mut c Chunker) rewind(pos_s f64) ! {
	c.stream = mf4.open_stream(mut c.src)!
	c.raw = canlog.Log{}
	c.planner = new_planner(c.specs)
	c.skip_s = pos_s
	c.counted = 0
	c.before = 0
	c.eof = false
}

// next_chunk reads until the chunk holds a row to play, or the pass ends. A chunk that is played
// gets rows of its own: a batch the player already handed out holds views into the previous
// chunk's rows, so those are never overwritten. A chunk that played nothing handed out nothing,
// so its rows are reused.
fn (mut c Chunker) next_chunk() bool {
	mut fresh := true
	for !c.eof {
		if fresh {
			c.raw.rows = []canlog.Row{cap: c.rows}
			fresh = false
		} else {
			c.raw.rows.clear()
		}
		mut sel := []u32{}
		for c.raw.rows.len < c.rows {
			r := c.stream.next(mut c.raw) or {
				c.eof = true
				if c.stream.err != '' && c.err == '' {
					c.err = c.stream.err
				}
				break
			}
			c.raw.rows << r
			i := c.raw.rows.len - 1
			if !c.planner.keep(&c.raw, i) {
				continue
			}
			// seek's own rule, spelled the same way: the first row at or after the position
			if r.t_s - c.t0_s >= c.skip_s {
				if sel.len == 0 {
					c.before = c.counted
				}
				sel << u32(i)
			}
			c.counted++
		}
		if sel.len > 0 {
			// resolve replaces dst rather than writing into it, so the chunk may share it
			c.chunk = c.raw.relabelled(c.planner.dst)
			c.sel = sel
			return true
		}
	}
	c.before = c.counted
	return false
}

// close releases the file.
pub fn (mut c Chunker) close() {
	c.src.close()
}

// new_player_chunked plays what `c` reads, over the source recording's span.
pub fn new_player_chunked(c &Chunker, speed f64, repeat bool) Player {
	mut p := new_player_log(canlog.Log{}, []u32{}, speed, repeat, c.t0_s, c.end_s)
	p.chunks = c
	p.open = true
	return p
}
