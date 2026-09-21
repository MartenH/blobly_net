// The STREAM: the recording's rows in the order the in-memory loader would hand them out, read
// from the file a chunk at a time and never held whole (docs/streaming_replay.md, PR 1).
//
// The loader's order is `(t_s, order)` where `order` is a record's position on one monotone
// scale across the whole file: sorted groups count their entries in data-group order, an
// unsorted group's ordinals are its records' positions in its interleaved stream lifted above
// everything before it. So the file-wide order is `(t, data-group index, position in the
// group)`, and a merge over one cursor per data group needs no ordinals at all: the earliest
// time wins, then the EARLIER data group, and within a group the cursor emits in position order.
// That order was hardened over several review rounds (equal-timestamp frames across buses, the
// thing multi-bus replay exists to preserve) and the golden test is that this stream reproduces
// parse_log exactly, sample files and hand-built images alike.
//
// Two cursors. A SORTED group is one channel group over fixed-stride records: a ChainStream
// over its data chain, one decode_row per stride, a ChainView over the signal-data chain for a
// VLSD group's payloads. An UNSORTED group interleaves several channel groups' records, each
// prefixed by its record id, VLSD records inline: one ChainStream, the fixed groups decoded as
// they go past into per-group queues, the VLSD groups' bytes kept in a bounded RingVlsd the
// fixed records point into — and a merge over the queues by `(t, record position)`, because an
// unsorted stream is time-monotone per channel group but not across them (a writer can skew two
// groups sharing a stream). The merge reads ahead until every frame group has a row queued or
// the stream ends; a cap bounds that read-ahead and a forced emission past it is counted
// (`forced`), never hidden — the survey (PR 2) will measure the skew so the cap is a number.
// A frame record may name a payload record that has NOT gone past yet (the loader demuxes the
// whole stream first and never notices); such a frame is DEFERRED, decoded the moment its
// bytes arrive, in record order — and at the end of the stream, or past a cap, decoded as it
// is and counted (`unresolved`).
//
// What the loader assumed that the stream cannot: a global sort forgives a group whose time
// runs backwards; the merge takes each cursor as monotone, so a row earlier than the one before
// it is COUNTED (`out_of_order`). And where the loader fails whole on a broken block, a cursor
// stops and records WHY (`err`), so a replay that played half a file says so rather than
// reporting a clean end.
module mf4

import canlog
import encoding.binary

// Cursor yields one data group's rows in the loader's order for that group.
interface Cursor {
mut:
	next(mut log canlog.Log) ?canlog.Row
	failure() string
}

// Stream is the k-way merge over the file's data groups.
pub struct Stream {
mut:
	cursors   []Cursor
	heads     []canlog.Row
	has       []bool
	done      []bool
	prev_t    f64
	have_prev bool
pub mut:
	// Counters the design asks to surface rather than hide: forced emissions past the unsorted
	// read-ahead cap, VLSD payloads already released when a record named them, records refused
	// by the decoder (the loader refuses the same ones; here they are counted), frames decoded
	// without a payload that never arrived, rows earlier than the row before them, and the
	// first error a cursor stopped on.
	forced       int
	evicted      int
	refused      int
	unresolved   int
	out_of_order int
	err          string
}

// open_stream resolves the file's headers and builds one cursor per data group. Nothing of the
// record data is read yet.
pub fn open_stream(mut src ByteSource) !Stream {
	unfin := read_id_block(mut src)!
	mut s := Stream{}
	hd := block_links(mut src, 64)
	mut dg := if hd.len > 0 { hd[0] } else { u64(0) }
	mut group := 0 // the CAN frame group ordinal, for records with no BusChannel — as the loader counts it
	for dg != 0 {
		dgl := block_links(mut src, dg)
		dg_data_off := data_off(mut src, dg)
		rec_id_size := int(u8_at(mut src, dg_data_off))
		cg_first := if dgl.len > 1 { dgl[1] } else { u64(0) }
		data_link := if dgl.len > 2 { dgl[2] } else { u64(0) }
		if cg_first != 0 {
			blocks := chain_blocks(mut src, data_link, unfin)!
			if rec_id_size == 0 {
				c := new_sorted_cursor(mut src, cg_first, blocks, unfin, group)
				group++
				s.cursors << c
			} else {
				mut c := new_unsorted_cursor(mut src, cg_first, blocks, rec_id_size, unfin, group)
				group = c.next_group
				s.cursors << c
			}
		}
		dg = if dgl.len > 0 { dgl[0] } else { u64(0) }
	}
	s.heads = []canlog.Row{len: s.cursors.len}
	s.has = []bool{len: s.cursors.len}
	s.done = []bool{len: s.cursors.len}
	// the header walk read through zero-filling helpers; a read that FAILED in it is this open's
	// failure, not an empty recording
	f := src.failure()
	if f != '' {
		return error(f)
	}
	return s
}

// next is the next row of the recording in the loader's order, interning its bus label into
// `log` as the loader would; none at the end. Standard-frame and error groups are not frames
// and never appear, as with the loader. A cursor that stopped on an error is done; `err` says.
pub fn (mut s Stream) next(mut log canlog.Log) ?canlog.Row {
	for i in 0 .. s.cursors.len {
		if s.has[i] || s.done[i] {
			continue
		}
		if r := s.cursors[i].next(mut log) {
			s.heads[i] = r
			s.has[i] = true
		} else {
			s.done[i] = true
		}
	}
	mut best := -1
	for i in 0 .. s.cursors.len {
		if !s.has[i] {
			continue
		}
		// earliest time, then the EARLIER data group: `order` climbs with the group index
		if best < 0 || s.heads[i].t_s < s.heads[best].t_s {
			best = i
		}
	}
	s.tally()
	if s.err != '' {
		// A cursor has failed: the rows its unread tail held may precede every head still
		// waiting, so nothing more is in order — and a row handed out past the failure is one
		// the caller would replay before learning the recording is broken (codex on #342
		// round 10). The heads stay unreturned; `err` is the answer.
		return none
	}
	if best < 0 {
		return none
	}
	s.has[best] = false
	row := s.heads[best]
	if s.have_prev && row.t_s < s.prev_t {
		s.out_of_order++
	}
	s.prev_t = row.t_s
	s.have_prev = true
	return row
}

// tally folds the cursors' counters into the stream's, so a caller reads one place.
fn (mut s Stream) tally() {
	mut forced := 0
	mut evicted := 0
	mut refused := 0
	mut unresolved := 0
	mut err := ''
	for mut c in s.cursors {
		if err == '' {
			err = c.failure()
		}
		if mut c is UnsortedCursor {
			forced += c.forced
			refused += c.refused
			unresolved += c.unresolved
			for _, r in c.vlsd {
				evicted += r.evicted
			}
		} else if mut c is SortedCursor {
			refused += c.refused
		}
	}
	s.forced = forced
	s.evicted = evicted
	s.refused = refused
	s.unresolved = unresolved
	s.err = err
}

// stream_log drains a stream into a Log — the whole recording in memory again, which is the
// point only for tests, small files and the dump tool's comparison; the player will hold a
// window of it instead. A cursor's error is the call's error, as the loader's would be.
pub fn stream_log(mut src ByteSource) !canlog.Log {
	mut s := open_stream(mut src)!
	mut log := canlog.Log{}
	for {
		r := s.next(mut log) or { break }
		log.rows << r
	}
	if s.err != '' {
		return error(s.err)
	}
	return log
}

// SortedCursor: one channel group, fixed-stride records, read in stride-sized steps.
struct SortedCursor {
mut:
	lay     CgLayout
	ok      bool // a CAN frame group this reader decodes; false yields nothing, as parse_cg did
	labels  Labels
	recs    ChainStream
	vlsd    VlsdBytes
	cycles  u64 // records to read: the chain's length in strides, capped by cg_cycle_count when finalized
	k       u64 // records consumed
	drained bool
	refused int
	err     string
}

// drain steps over what is left of the chain once nothing more will be decoded from it — a
// group past its declared cycle count, or one this reader does not decode. The loader reads
// every data block whole, so a corrupt trailing block fails it; the stream must fail on it too
// rather than report a clean end (codex on #342 round 3). `skip` inflates the DZ blocks it
// crosses without keeping them and steps over plain blocks by offset, so the cost is the
// loader's inflation without the loader's memory.
fn (mut c SortedCursor) drain() {
	if c.drained {
		return
	}
	c.drained = true
	c.recs.skip(c.recs.remaining()) or {
		c.err = err.msg()
		c.ok = false
		return
	}
	// and the signal-data chain's blocks no payload pointed into
	c.vlsd.validate() or {
		c.err = err.msg()
		c.ok = false
	}
}

fn new_sorted_cursor(mut src ByteSource, cg u64, blocks []ChainBlock, unfin bool, group int) &SortedCursor {
	mut c := &SortedCursor{
		labels: new_labels(group)
		recs:   new_chain_stream(mut src, blocks)
		vlsd:   MemVlsd{}
	}
	lay := resolve_layout(mut src, cg) or { return c }
	c.lay = lay
	c.ok = true
	c.cycles = lay.record_count(chain_len(blocks), unfin)
	if lay.is_vlsd {
		// a sorted group's VLSD payloads live in a signal-data chain (an SD, or an HL/DL of DZ
		// blocks), read at random by offset
		sd := chain_blocks(mut src, lay.vlsd_link, unfin) or {
			c.err = 'signal data: ${err}'
			c.ok = false
			return c
		}
		c.vlsd = new_chain_view(mut src, sd)
	}
	return c
}

fn (c &SortedCursor) failure() string {
	return c.err
}

fn (mut c SortedCursor) next(mut log canlog.Log) ?canlog.Row {
	if !c.ok {
		if c.err == '' {
			c.drain()
		}
		return none
	}
	for c.k < c.cycles {
		have := c.recs.ensure(c.lay.stride) or {
			c.err = err.msg()
			c.ok = false
			return none
		}
		if !have {
			return none
		}
		base := c.recs.pos
		row := decode_row(&c.lay, c.recs.buf, base, mut c.vlsd, mut c.labels, mut log)
		// a payload source that could not answer because the FILE is broken stops the cursor:
		// the frame it would have yielded is one the recording never stated
		f := c.vlsd.failure()
		if f != '' {
			c.err = f
			c.ok = false
			return none
		}
		c.recs.consume(c.lay.stride)
		c.k++
		if r := row {
			return r
		}
		c.refused++
	}
	c.drain()
	return none
}

// UCg is one channel group of an unsorted data group, as the cursor tracks it.
struct UCg {
	info CgInfo
mut:
	lay    CgLayout
	ok     bool // a CAN frame group; a fixed group that is not one is consumed and dropped
	labels Labels
	queue  []Pending // decoded rows waiting for the merge, in record order
	qhead  int
	// Records to decode: cg_cycle_count when the file is finalized and the count is stated,
	// as the loader's record_count caps the demuxed stream; every record past it is consumed
	// and dropped. `seen` counts the group's records as they go past.
	cap  u64
	seen u64
	// Frame records whose payload record had not gone past yet, in record order, decoded the
	// moment their bytes arrive (see the file comment).
	deferred []RawRec
}

// exhausted says nothing more of this group will ever be queued: it is not decoded at all, or
// it has seen its declared cycle count and holds nothing back. The merge must not wait for such
// a group — waiting read the rest of the stream ahead of every emission, and counted the
// emissions as forced (codex on #342 round 3).
fn (u &UCg) exhausted() bool {
	return !u.ok || (u.seen >= u.cap && u.deferred.len == 0)
}

// RawRec is a record held back, and its position. Positions are u64: a recording of tens of
// GB has more records than an int counts, and a wrapped ordinal reorders equal-timestamp rows
// (codex on #342 round 4).
struct RawRec {
	raw []u8
	pos u64
}

// Pending is a decoded row and the record position it came from.
struct Pending {
	row canlog.Row
	pos u64
}

// The read-ahead cap over an unsorted group's queues, in rows: eight thousand rows a queue of
// eighty bytes each is under a megabyte per busy group, and far more than any recorder skews
// two groups by. Past it the merge emits the earliest queued row anyway and counts it. The
// same number bounds how many frames wait for a payload record that has not gone past.
const unsorted_readahead = 8192

// The most raw record bytes the deferred frames may hold between them: a frame record is tens
// of bytes, but a stride up to max_record_stride is admitted, and unsorted_readahead of those
// is half a gigabyte (codex on #342 round 3). Past it the oldest waiting frames are decoded as
// they are, and counted, like past the count.
const max_deferred_bytes = u64(8) << 20

// The most a VLSD record is read for: a CAN payload is 64 bytes and a length prefix, and a
// record announcing more is some other signal's — or a corrupt length below the chain's
// remaining bytes but far above any payload, which `ensure` would have buffered whole. Skipped
// without buffering; the ring's offsets stay the writer's.
const max_vlsd_record = u64(1) << 20

// UnsortedCursor: several channel groups interleaved in one record stream.
struct UnsortedCursor {
mut:
	cgs    []UCg
	by_rid map[u64]int       // record id -> index in cgs
	vlsd   map[u64]&RingVlsd // VLSD groups' bytes, by CG block address (what cn_data names)
	// A VLSD channel whose cn_data names a signal-data BLOCK rather than a VLSD channel group —
	// the format allows it inside an unsorted group too, and the loader reads it — decodes
	// through a view over that chain; by index in cgs.
	views       map[int]&ChainView
	stream      ChainStream
	rec_id_size int
	rec_n       u64 // records read so far: the ordinal the loader keys ties by
	queued      int
	deferred    int // frames held back across all groups
	deferred_b  u64 // and their bytes
	ended       bool
	next_group  int
	forced      int
	refused     int
	unresolved  int
	err         string
	none_vlsd   MemVlsd
}

fn new_unsorted_cursor(mut src ByteSource, cg_first u64, blocks []ChainBlock, rec_id_size int, unfin bool, group int) &UnsortedCursor {
	mut c := &UnsortedCursor{
		stream:      new_chain_stream(mut src, blocks)
		rec_id_size: rec_id_size
	}
	mut g := group
	mut cgi := cg_first
	for cgi != 0 {
		cgd := data_off(mut src, cgi)
		info := CgInfo{
			link:   cgi
			rec_id: u64_at(mut src, cgd)
			vlsd:   u16_at(mut src, cgd + 16) & 1 == 1
			size:   record_size(u32_at(mut src, cgd + 24), u32_at(mut src, cgd + 28))
		}
		if info.vlsd {
			c.cgs << UCg{
				info: info
			}
		} else {
			// the group ordinal advances for every fixed group, decodable or not, as demux_unsorted
			// advances it — the labels of a file without BusChannel depend on that count
			mut u := UCg{
				info:   info
				labels: new_labels(g)
				cap:    u64(-1)
			}
			// a later claimant of a record id already owned decodes nothing (the loader's
			// CgInfo.dup) — and so is not `ok`, or the merge would wait forever on a head that
			// can never come (codex on #342 round 5); it still takes its group ordinal
			if info.rec_id !in c.by_rid {
				if lay := resolve_layout(mut src, cgi) {
					u.lay = lay
					u.ok = true
					if !unfin && lay.declared > 0 {
						u.cap = lay.declared
					}
				}
			}
			g++
			c.cgs << u
		}
		// the FIRST group declaring a record id owns it, as the loader's demux takes the first
		// match; a duplicate id is a malformed file, and the two paths must read it the same way
		if info.rec_id !in c.by_rid {
			c.by_rid[info.rec_id] = c.cgs.len - 1
		}
		l := block_links(mut src, cgi)
		cgi = if l.len > 0 { l[0] } else { u64(0) }
	}
	// A ring for a VLSD group only where a decoded frame group READS it: an unsorted group of a
	// measurement file carries VLSD channels for signals that are not CAN frames at all, and a
	// ring for each held up to 8 MiB of bytes nothing would ever decode (codex on #342 round 8).
	// A VLSD group nobody reads has its records stepped over instead.
	mut vlsd_cgs := map[u64]bool{}
	for u in c.cgs {
		if u.info.vlsd {
			vlsd_cgs[u.info.link] = true
		}
	}
	for u in c.cgs {
		if u.ok && u.lay.is_vlsd && u.lay.vlsd_link in vlsd_cgs && u.lay.vlsd_link !in c.vlsd {
			c.vlsd[u.lay.vlsd_link] = &RingVlsd{}
		}
	}
	// one byte budget across the rings, not one per ring
	if c.vlsd.len > 0 {
		each := ring_budget / c.vlsd.len
		for _, mut r in c.vlsd {
			r.cap = each
		}
	}
	// a frame group's VLSD link that names no VLSD group here is a signal-data chain: a view
	for i in 0 .. c.cgs.len {
		if !c.cgs[i].ok || !c.cgs[i].lay.is_vlsd || c.cgs[i].lay.vlsd_link in c.vlsd {
			continue
		}
		sd := chain_blocks(mut src, c.cgs[i].lay.vlsd_link, unfin) or {
			c.err = 'signal data: ${err}'
			c.ended = true
			continue
		}
		view := new_chain_view(mut src, sd)
		c.views[i] = &view
	}
	c.next_group = g
	return c
}

fn (c &UnsortedCursor) failure() string {
	return c.err
}

// fits says whether n more bytes can still come out of the stream; a length past the end is a
// corrupt field — the unwritten filler an unfinalized file's extended last block decodes as
// records reads as 0xFFFFFFF0 — and is refused BEFORE it sizes a read or a slice: as a signed
// int it went negative and a slice ran backwards, as a huge count it buffered the rest of the
// file, which is the memory the stream exists not to hold.
fn (c &UnsortedCursor) fits(n u64) bool {
	return n <= c.stream.remaining()
}

// payload_ready says whether the payload a frame record names has gone past: its length
// prefix and its bytes are within the ring's end. An offset already released is "ready" — the
// decoder will find nothing and the release is counted there, not here.
fn payload_ready(lay &CgLayout, raw []u8, base int, ring &RingVlsd) bool {
	off := read_uint(raw, base + lay.c_db.byte_off, int(lay.c_db.bit_off), int(lay.c_db.bit_count))
	if off < ring.base {
		return true
	}
	end := ring.end()
	if off > end || end - off < 4 {
		return false
	}
	n := u64(binary.little_endian_u32_at(ring.buf, int(off - ring.base)))
	return end - off - 4 >= n
}

// decode_into decodes one fixed record of group `ci` into its queue, through whatever its
// payload source is.
fn (mut c UnsortedCursor) decode_into(ci int, raw []u8, base int, pos u64, mut log canlog.Log) {
	mut u := &c.cgs[ci]
	row := if mut ring := c.vlsd[u.lay.vlsd_link] {
		decode_row(&u.lay, raw, base, mut ring, mut u.labels, mut log)
	} else if mut view := c.views[ci] {
		r := decode_row(&u.lay, raw, base, mut view, mut u.labels, mut log)
		// a broken signal-data block stops the cursor BEFORE the row it would have altered is
		// queued — the sorted cursor's rule, missing here in round 1 (codex on #342 round 2)
		f := view.failure()
		if f != '' {
			c.err = f
			c.ended = true
			return
		}
		r
	} else {
		decode_row(&u.lay, raw, base, mut c.none_vlsd, mut u.labels, mut log)
	}
	if r := row {
		u.queue << Pending{
			row: r
			pos: pos
		}
		c.queued++
	} else {
		c.refused++
	}
}

// resolve decodes every deferred frame whose payload has gone past, in record order, for the
// groups that read from `ring`; `flush` decodes them all regardless (the stream ended, or too
// many are waiting) and counts the ones still without their bytes.
fn (mut c UnsortedCursor) resolve(ring &RingVlsd, flush bool, mut log canlog.Log) {
	for ci in 0 .. c.cgs.len {
		if !c.cgs[ci].ok || c.cgs[ci].deferred.len == 0 {
			continue
		}
		own := c.vlsd[c.cgs[ci].lay.vlsd_link] or { continue }
		if own != ring && !flush {
			continue
		}
		mut done := 0
		mut freed := u64(0)
		for d in c.cgs[ci].deferred {
			ready := payload_ready(&c.cgs[ci].lay, d.raw, 0, own)
			if !ready && !flush {
				break
			}
			if !ready {
				c.unresolved++
			}
			c.decode_into(ci, d.raw, 0, d.pos, mut log)
			done++
			freed += u64(d.raw.len)
		}
		if done > 0 {
			c.cgs[ci].deferred.delete_many(0, done)
			c.deferred -= done
			c.deferred_b -= freed
		}
	}
}

// evict decodes the OLDEST deferred frames as they are — payload-less, counted — until the
// backlog is under both caps again, and only as many as that takes: a flush of every waiting
// frame on every ring turned a valid stream's whole backlog into payload-less rows when one
// record tipped it over the cap, payloads that were a few records away (codex on #342 round 6).
// The oldest across groups is the lowest record position among the heads, since each group's
// list is in record order; evicting a head may leave the next one ready, so its ring's frames
// are resolved after.
fn (mut c UnsortedCursor) evict(mut log canlog.Log) {
	for c.deferred > unsorted_readahead || c.deferred_b > max_deferred_bytes {
		mut oldest := -1
		for i, u in c.cgs {
			if u.deferred.len == 0 {
				continue
			}
			if oldest < 0 || u.deferred[0].pos < c.cgs[oldest].deferred[0].pos {
				oldest = i
			}
		}
		if oldest < 0 {
			return
		}
		d := c.cgs[oldest].deferred[0]
		c.cgs[oldest].deferred.delete(0)
		c.deferred--
		c.deferred_b -= u64(d.raw.len)
		c.unresolved++
		c.decode_into(oldest, d.raw, 0, d.pos, mut log)
		if own := c.vlsd[c.cgs[oldest].lay.vlsd_link] {
			c.resolve(own, false, mut log)
		}
	}
}

// read_record consumes one record from the stream into its group's queue (or VLSD ring); false
// at the end of the stream, at an unknown record id or at a length past the end (a corrupt
// tail, common in unfinalized files — the loader stops there too).
fn (mut c UnsortedCursor) read_record(mut log canlog.Log) bool {
	have := c.stream.ensure(c.rec_id_size) or {
		c.err = err.msg()
		return false
	}
	if !have {
		return false
	}
	rid := read_uint(c.stream.buf, c.stream.pos, 0, c.rec_id_size * 8)
	ci := c.by_rid[rid] or { return false }
	c.rec_n++
	c.stream.consume(c.rec_id_size)
	if c.cgs[ci].info.vlsd {
		if !c.fits(4) || !(c.stream.ensure(4) or {
			c.err = err.msg()
			false
		}) {
			return false
		}
		n := u64(binary.little_endian_u32_at(c.stream.buf, c.stream.pos))
		if !c.fits(4 + n) {
			return false
		}
		mut ring := c.vlsd[c.cgs[ci].info.link] or {
			// a VLSD group no frame group reads: its record is stepped over, never kept
			c.stream.skip(4 + n) or {
				c.err = err.msg()
				return false
			}
			return true
		}
		if 4 + n > max_vlsd_record {
			// not a payload: stepped over, never buffered, the ring's offsets kept in step
			c.stream.skip(4 + n) or {
				c.err = err.msg()
				return false
			}
			ring.skip(4 + n)
			return true
		}
		len := int(4 + n)
		if !(c.stream.ensure(len) or {
			c.err = err.msg()
			false
		}) {
			return false
		}
		ring.append(c.stream.buf[c.stream.pos..c.stream.pos + len]) // the prefix stays
		c.stream.consume(len)
		c.resolve(ring, false, mut log)
		return true
	}
	size := c.cgs[ci].info.size
	if size < 0 || !c.fits(u64(size)) {
		return false
	}
	c.cgs[ci].seen++
	if size == 0 {
		// a group with no channels: its record is the record id alone, already consumed, and
		// the loader steps over it — ending the stream here lost every frame after it (codex on
		// #342 round 10)
		return true
	}
	if !c.cgs[ci].ok || c.cgs[ci].seen > c.cgs[ci].cap {
		// a record nobody decodes — another signal's group, or one past the declared count — is
		// stepped over, never buffered: its stride is bounded by nothing this reader trusts
		c.stream.skip(u64(size)) or {
			c.err = err.msg()
			return false
		}
		return true
	}
	if !(c.stream.ensure(size) or {
		c.err = err.msg()
		false
	}) {
		return false
	}
	base := c.stream.pos
	// Held back while its payload record has not gone past — or while an earlier frame of
	// its group is held back, so the queue keeps record order. Past the cap the oldest
	// waiting frame is decoded as it is, and counted.
	mut wait := c.cgs[ci].deferred.len > 0
	if !wait {
		if ring := c.vlsd[c.cgs[ci].lay.vlsd_link] {
			wait = !payload_ready(&c.cgs[ci].lay, c.stream.buf, base, ring)
		}
	}
	if wait {
		c.cgs[ci].deferred << RawRec{
			raw: c.stream.buf[base..base + size].clone()
			pos: c.rec_n
		}
		c.deferred++
		c.deferred_b += u64(size)
		c.evict(mut log)
	} else {
		c.decode_into(ci, c.stream.buf, base, c.rec_n, mut log)
	}
	c.stream.consume(size)
	return true
}

// finish ends the cursor: nothing more will be decoded — the stream ended, an unknown record id
// or a corrupt length stopped the parse where the loader's demux stops, or every group is past
// its count — but the loader inflated the WHOLE chain before it demultiplexed anything, and read
// every signal-data chain whole, so the rest of the chain is stepped over and every view
// validated, and a corrupt block there fails the stream as it fails the loader (codex on #342
// rounds 3 and 5). Not after a read error: that is already the failure. And only THEN — the
// whole chain validated — is whatever still waits for a payload decoded as it is and counted:
// a payload-less row queued before the validation, or after a read failure, was handed out
// ahead of the failure it should have been refused by (rounds 6 and 7, the same defect in two
// orders; this function is the one order now).
fn (mut c UnsortedCursor) finish(mut log canlog.Log) {
	c.ended = true
	if c.err != '' {
		return
	}
	c.stream.skip(c.stream.remaining()) or {
		c.err = err.msg()
		return
	}
	for _, mut v in c.views {
		v.validate() or {
			c.err = err.msg()
			return
		}
	}
	if c.deferred > 0 {
		none_ring := &RingVlsd{}
		c.resolve(none_ring, true, mut log)
	}
}

// needs_more says whether some frame group has nothing queued while the stream may still hold
// its next row — the condition under which emitting would risk the order.
fn (c &UnsortedCursor) needs_more() bool {
	for u in c.cgs {
		if !u.exhausted() && u.qhead >= u.queue.len {
			return true
		}
	}
	return false
}

// exhausted_all says no group will queue anything more, however much stream is left.
fn (c &UnsortedCursor) exhausted_all() bool {
	for u in c.cgs {
		if !u.exhausted() {
			return false
		}
	}
	return true
}

fn (mut c UnsortedCursor) next(mut log canlog.Log) ?canlog.Row {
	for !c.ended && c.needs_more() {
		if c.queued >= unsorted_readahead {
			c.forced++
			break
		}
		if !c.read_record(mut log) {
			c.finish(mut log)
		}
	}
	if !c.ended && c.exhausted_all() {
		c.finish(mut log)
	}
	// the earliest queued row, ties by record position — the loader's (t_s, ordinal)
	mut best := -1
	for i, u in c.cgs {
		if u.qhead >= u.queue.len {
			continue
		}
		h := u.queue[u.qhead]
		if best < 0 {
			best = i
			continue
		}
		b := c.cgs[best].queue[c.cgs[best].qhead]
		if h.row.t_s < b.row.t_s || (h.row.t_s == b.row.t_s && h.pos < b.pos) {
			best = i
		}
	}
	if best < 0 {
		return none
	}
	mut u := &c.cgs[best]
	r := u.queue[u.qhead].row
	u.qhead++
	c.queued--
	// release what the merge has passed, in halves, so a queue never grows without bound
	if u.qhead >= 1024 && u.qhead >= u.queue.len / 2 {
		u.queue.delete_many(0, u.qhead)
		u.qhead = 0
	}
	return r
}
