// The DATA CHAIN of a data group or a signal-data link, as the stream reads it: which blocks
// hold the bytes, in order, and how many logical bytes each contributes — resolved once from
// the headers (docs/streaming_replay.md, "What the file allows") and then read either
// SEQUENTIALLY in bounded chunks (ChainStream: the record stream of a data group) or at RANDOM
// (ChainView: a VLSD group's payloads, which records name by offset into the chain). A DZ block
// is the one unit that cannot be split: zlib is one stream and zip_type 1 transposes the whole
// block, so it is inflated whole and is the unit of memory for either reader.
//
// read_data_block, the in-memory loader's "give me the bytes", is this chain concatenated — one
// walker for both, so the stream cannot resolve a link the loader resolves differently.
module mf4

import compress.zlib

// ChainBlock is one block of a chain: where its bytes are and how many.
struct ChainBlock {
	off     u64 // file offset of the payload bytes (DT/DV/DI/RD/SD), or of the DZ block itself
	len     u64 // logical bytes: the payload length, or a DZ block's original length
	dz      bool
	logical u64 // logical offset of this block's first byte within the chain
}

// chain_blocks resolves a data link to its blocks, reading headers only. Offsets are u64 end to
// end: a 10 GB recording keeps its later blocks past 2^31. An unfinalized file's last block may
// declare a stale length (the logger died before writing it); the block then runs to the end of
// the file when nothing but the end follows its declared end — MDF blocks are 8-byte aligned,
// so a '##' header at the aligned boundary is what says the length was right.
fn chain_blocks(mut src ByteSource, link u64, unfin bool) ![]ChainBlock {
	mut out := []ChainBlock{}
	chain_walk(mut src, link, unfin, mut out, 0)!
	return out
}

// chain_walk appends `link`'s blocks to `out` from logical offset `at` and returns the offset
// after them.
fn chain_walk(mut src ByteSource, link u64, unfin bool, mut out []ChainBlock, at u64) !u64 {
	mut logical := at
	if link == 0 {
		return logical
	}
	id := block_id(mut src, link)
	match id {
		'##DT', '##DV', '##DI', '##RD', '##SD' {
			length := u64_at(mut src, link + 8)
			d := data_off(mut src, link)
			// The block's end, clamped to the file BEFORE the addition: a corrupt length near
			// 2^64 wrapped `link + length` to a small number, and the block vanished from the
			// chain instead of running to the end of the file like any other over-long block
			// (codex on #342). The clamp is the existing rule for a length past the file.
			mut end := if link > src.size() || length > src.size() - link {
				src.size()
			} else {
				link + length
			}
			if unfin {
				if end > src.size() {
					end = src.size()
				} else {
					ae := (end + 7) / 8 * 8
					if ae + 4 > src.size() || bytes_at(mut src, ae, 2) != [u8(`#`), `#`] {
						end = src.size()
					}
				}
			}
			if end > src.size() {
				end = src.size()
			}
			if d < end {
				out << ChainBlock{
					off:     d
					len:     end - d
					logical: logical
				}
				logical += end - d
			}
		}
		'##DZ' {
			d := data_off(mut src, link)
			org_len := u64_at(mut src, d + 8)
			if org_len > 0 {
				out << ChainBlock{
					off:     link
					len:     org_len
					dz:      true
					logical: logical
				}
				logical += org_len
			}
		}
		'##DL' {
			mut dl := link
			for dl != 0 {
				dll := block_links(mut src, dl)
				for i := 1; i < dll.len; i++ {
					if dll[i] != 0 {
						logical = chain_walk(mut src, dll[i], unfin, mut out, logical)!
					}
				}
				dl = if dll.len > 0 { dll[0] } else { u64(0) }
			}
		}
		'##HL' {
			hll := block_links(mut src, link)
			logical = chain_walk(mut src, if hll.len > 0 { hll[0] } else { u64(0) }, unfin, mut
				out, logical)!
		}
		else {
			return error('unknown data block ${id}')
		}
	}

	return logical
}

// chain_len is the logical length of a chain.
fn chain_len(blocks []ChainBlock) u64 {
	if blocks.len == 0 {
		return 0
	}
	last := blocks[blocks.len - 1]
	return last.logical + last.len
}

// block_bytes reads one block whole: the payload bytes, or a DZ block inflated.
fn block_bytes(mut src ByteSource, b ChainBlock) ![]u8 {
	if b.dz {
		return dz_decompress(mut src, b.off)!
	}
	if b.len > u64(max_int) {
		return error('data block of ${b.len} bytes cannot be held in memory whole')
	}
	// An EXACT read: `bytes_at` zero-fills what it could not read, which handed the decoder
	// fabricated records after a truncation or a failed read and called it a recording (codex
	// on #342 round 4) — the check `fill` makes, made here too, since load_file reads through a
	// FileSource now rather than one whole-file read.
	mut out := []u8{len: int(b.len)}
	got := src.read_at(b.off, mut out) or { return error('read at ${b.off}: ${err}') }
	if got < out.len {
		return error('short read at ${b.off}: ${got} of ${out.len} bytes')
	}
	return out
}

// The most a DZ block may inflate to. The format says an uncompressed data block should not
// exceed 4 MB (ASAM MDF 4.1, the DZBLOCK / DLBLOCK rules), and writers keep to it; this is four
// times that. It is the stream's unit of memory PER DATA GROUP — every cursor may hold one
// inflated block (and one more in its signal-data view) while its head waits in the merge, so
// the bound is data groups times this, and a 256 MB cap made that gigabytes for a valid
// multi-bus file (codex on #342 round 4). A block past it is refused rather than inflated, by
// either reader.
const max_dz_block = u64(16) << 20

// The read size of a sequential chunk. Large enough that a 1 Mbit/s bus's second of records is
// one read; small enough that the buffer is not the memory the window exists to avoid.
const chain_chunk = 1 << 20

// ChainStream reads a chain SEQUENTIALLY through a bounded buffer: `ensure(n)` makes at least n
// bytes available at `pos` (or says the chain has ended), the caller decodes in place and
// `consume`s. A record straddling two chunks — or two blocks — is simply one `ensure` that
// spans the boundary; the carry is the unconsumed tail, compacted to the front when the buffer
// is more than half read. A DZ block is inflated whole into `dz_buf` and served from there in
// chunks, so the buffer itself never holds more than a chunk plus a record.
struct ChainStream {
mut:
	src      ByteSource
	blocks   []ChainBlock
	total    u64 // the chain's logical length
	consumed u64 // bytes the caller has consumed
	bi       int // the block being read
	bpos     u64 // logical position within it
	buf      []u8
	pos      int  // the read position in buf
	dz_buf   []u8 // the current DZ block, inflated
	dz_for   int = -1 // which block dz_buf holds
	eof      bool
	chunk    int = chain_chunk
}

fn new_chain_stream(mut src ByteSource, blocks []ChainBlock) ChainStream {
	return ChainStream{
		src:    src
		blocks: blocks
		total:  chain_len(blocks)
	}
}

// remaining is how many bytes the chain can still yield, buffered ones included: what a
// declared length is checked against BEFORE it sizes a read.
fn (s &ChainStream) remaining() u64 {
	return s.total - s.consumed
}

// avail is how many bytes are buffered and unconsumed.
fn (s &ChainStream) avail() int {
	return s.buf.len - s.pos
}

// ensure makes at least n bytes available at pos; false when the chain ends first (a partial
// trailing record is not a record, and a short read is the end or corruption, never zeros).
fn (mut s ChainStream) ensure(n int) !bool {
	for s.avail() < n {
		if s.eof {
			return false
		}
		s.fill()!
	}
	return true
}

// fill appends the next chunk of the chain to the buffer, compacting first when most of the
// buffer has been consumed.
fn (mut s ChainStream) fill() ! {
	if s.pos > 0 && s.pos >= s.buf.len / 2 {
		tail := s.buf.len - s.pos
		if tail > 0 {
			unsafe { vmemmove(s.buf.data, &s.buf[s.pos], tail) }
		}
		s.buf.trim(tail)
		s.pos = 0
	}
	for s.bi < s.blocks.len {
		b := s.blocks[s.bi]
		if s.bpos >= b.len {
			s.bi++
			s.bpos = 0
			continue
		}
		remaining := b.len - s.bpos
		want := if remaining < u64(s.chunk) { int(remaining) } else { s.chunk }
		if b.dz {
			if s.dz_for != s.bi {
				s.dz_buf = dz_decompress(mut s.src, b.off)!
				s.dz_for = s.bi
			}
			if u64(s.dz_buf.len) < b.len {
				// inflated shorter than declared: dz_decompress refuses that, but the chain
				// walker took the declared length, so guard the slice
				s.eof = true
				return
			}
			s.buf << s.dz_buf[int(s.bpos)..int(s.bpos) + want]
			s.bpos += u64(want)
			if s.bpos >= b.len {
				// served whole: released now, not when the next block replaces it, so a cursor
				// waiting in the merge between blocks holds no inflated block at all
				s.dz_buf = []u8{}
				s.dz_for = -1
			}
			return
		}
		mut chunk := []u8{len: want}
		got := s.src.read_at(b.off + s.bpos, mut chunk) or {
			s.eof = true
			return error('read at ${b.off + s.bpos}: ${err}')
		}
		if got < want {
			// The chain walker clamped every block to the file's size, so bytes the block says
			// it has ARE there unless the file was truncated under the reader or the read
			// failed — and a reader that called that the end returned a shorter recording as a
			// clean one (codex on #342).
			s.eof = true
			return error('short read at ${b.off + s.bpos}: ${got} of ${want} bytes')
		}
		s.buf << chunk
		s.bpos += u64(want)
		return
	}
	s.eof = true
}

// consume drops n bytes at pos.
fn (mut s ChainStream) consume(n int) {
	s.pos += n
	s.consumed += u64(n)
}

// skip passes over n bytes WITHOUT accumulating them: what is buffered is consumed, a plain
// block is stepped over by offset, and a DZ block is inflated and consumed chunk by chunk — never
// held beyond the one block, but never bypassed either, because the loader inflates every block
// and a corrupt one it would fail on must fail the stream too (codex on #342 round 2). For a
// record too large to be anything this reader wants (a VLSD record past max_vlsd_record, a fixed
// record of a group this reader does not decode), which `ensure` would otherwise have
// accumulated whole.
fn (mut s ChainStream) skip(n u64) ! {
	mut left := n
	for left > 0 {
		if s.avail() > 0 {
			take := if u64(s.avail()) < left { s.avail() } else { int(left) }
			s.consume(take)
			left -= u64(take)
			continue
		}
		if s.bi >= s.blocks.len {
			s.eof = true
			return
		}
		b := s.blocks[s.bi]
		if b.dz {
			s.fill()!
			if s.eof && s.avail() == 0 {
				return
			}
			continue
		}
		rem := b.len - s.bpos
		step := if rem < left { rem } else { left }
		// The span is not read — that is what a skip is for — but its LAST byte is: the walker
		// clamped every block to the file at open, so a file truncated under the reader ends
		// inside a span, and the probe fails on it as `fill` would have (codex on #342 round 4).
		// What this does not see is a device that fails a read in the middle of a span whose end
		// it serves; reading and discarding the span would, at the cost of reading every byte
		// of a group this reader does not decode, which is the loader's cost and the one the
		// stream exists not to pay.
		last := b.off + s.bpos + step - 1
		mut probe := []u8{len: 1}
		got := s.src.read_at(last, mut probe) or {
			s.eof = true
			return error('read at ${last}: ${err}')
		}
		if got < 1 {
			s.eof = true
			return error('short read at ${last}: the block ends before its declared end')
		}
		s.bpos += step
		s.consumed += step
		left -= step
		if s.bpos >= b.len {
			s.bi++
			s.bpos = 0
		}
	}
}

// ChainView reads a chain at RANDOM: a VLSD group's records name their payload by logical
// offset into the signal-data chain, so a streaming decoder needs `at(off, n)` over it without
// holding the chain. Plain blocks are read at their file offset; a DZ block is inflated whole
// into a one-block cache, since it can be read no other way — the unit of memory, as the design
// says. A read that leaves the chain, or crosses into a block that is not there, is none.
struct ChainView {
mut:
	src     ByteSource
	blocks  []ChainBlock
	total   u64
	cache   []u8 // one inflated DZ block
	cached  int = -1
	scratch []u8 // the bytes handed out by `at`, valid until the next call
	last    int  // the block the previous read hit: offsets ascend, so it is usually this or the next
	// The first failure a read met — a DZ block that would not inflate, a short read — kept
	// rather than folded into `none`: a payload that is not there because the offset is out of
	// the chain is a fact about the record, one that is not there because the block is broken
	// is a fact about the FILE, and a frame emitted without it would be a frame the recording
	// never stated (codex on #342). The cursor stops on it.
	err string
}

fn new_chain_view(mut src ByteSource, blocks []ChainBlock) ChainView {
	return ChainView{
		src:    src
		blocks: blocks
		total:  chain_len(blocks)
	}
}

// at is n bytes at logical offset off, or none when they are not all inside the chain. The
// slice is the view's own scratch and is valid until the next call: every caller copies.
fn (mut v ChainView) at(off u64, n int) ?[]u8 {
	if n < 0 || off > v.total || u64(n) > v.total - off {
		return none
	}
	// which block holds `off`: the one the previous read hit or its successor (records name
	// ascending offsets), else a binary search over `logical`, which is monotone — a CAN-FD
	// recording's signal-data chain is thousands of DZ blocks, and a scan per payload would put
	// records × blocks comparisons on the decoder's path
	mut bi := -1
	for cand in [v.last, v.last + 1] {
		if cand >= 0 && cand < v.blocks.len {
			b := v.blocks[cand]
			if off >= b.logical && off < b.logical + b.len {
				bi = cand
				break
			}
		}
	}
	if bi < 0 {
		mut lo := 0
		mut hi := v.blocks.len - 1
		for lo <= hi {
			mid := (lo + hi) / 2
			b := v.blocks[mid]
			if off < b.logical {
				hi = mid - 1
			} else if off >= b.logical + b.len {
				lo = mid + 1
			} else {
				bi = mid
				break
			}
		}
	}
	if bi < 0 {
		return none
	}
	v.last = bi
	v.scratch.clear()
	mut want := n
	mut at := off
	for want > 0 {
		if bi >= v.blocks.len {
			return none
		}
		b := v.blocks[bi]
		inner := at - b.logical
		take := if b.len - inner < u64(want) { int(b.len - inner) } else { want }
		if b.dz {
			if v.cached != bi {
				v.cache = dz_decompress(mut v.src, b.off) or {
					v.err = 'signal data: ${err}'
					return none
				}
				v.cached = bi
			}
			if u64(v.cache.len) < inner + u64(take) {
				return none
			}
			v.scratch << v.cache[int(inner)..int(inner) + take]
		} else {
			mut piece := []u8{len: take}
			got := v.src.read_at(b.off + inner, mut piece) or {
				v.err = 'signal data: read at ${b.off + inner}: ${err}'
				return none
			}
			if got < take {
				v.err = 'signal data: short read at ${b.off + inner}: ${got} of ${take} bytes'
				return none
			}
			v.scratch << piece
		}
		want -= take
		at += u64(take)
		bi++
	}
	return v.scratch
}

// VlsdBytes is where a VLSD record's payload is read from: the whole signal-data block in
// memory (the loader: MemVlsd), a signal-data chain read at random (the stream over a sorted
// group: ChainView), or the concatenation of a VLSD group's records as they went past in an
// unsorted stream (the stream over an unsorted group: RingVlsd). decode_row asks `at(off, n)`
// and copies what it gets; none means the payload is not there — out of the chain, or already
// released — and the record keeps its identity with no payload, as it does when the offset is
// out of bounds today.
interface VlsdBytes {
mut:
	at(off u64, n int) ?[]u8
	// The first failure a read met, '' while none: a source that cannot answer because the file
	// is broken says so here, and the cursor reading it stops.
	failure() string
}

fn (v &ChainView) failure() string {
	return v.err
}

fn (m &MemVlsd) failure() string {
	return ''
}

fn (r &RingVlsd) failure() string {
	return ''
}

// MemVlsd is a VLSD source over bytes in memory.
struct MemVlsd {
	buf []u8
}

fn (mut m MemVlsd) at(off u64, n int) ?[]u8 {
	if n < 0 || off > u64(m.buf.len) || u64(n) > u64(m.buf.len) - off {
		return none
	}
	return m.buf[int(off)..int(off) + n]
}

// RingVlsd is the recent tail of a VLSD group's record stream in an unsorted data group, kept
// while the records that point into it go past. CANedge writes the payload record immediately
// before the frame record that names it, so a bounded tail is all a decoder needs; past `cap`
// the front half is released, and a record naming a released offset gets no payload — counted
// in `evicted`, since a payload that is not there is a fact about the reader's memory, not
// about the recording.
struct RingVlsd {
mut:
	base    u64 // the logical offset of buf[0]
	buf     []u8
	cap     int = 8 << 20
	evicted int
}

fn (mut r RingVlsd) append(bytes []u8) {
	r.buf << bytes
	if r.buf.len > r.cap {
		drop := r.buf.len / 2
		tail := r.buf.len - drop
		unsafe { vmemmove(r.buf.data, &r.buf[drop], tail) }
		r.buf.trim(tail)
		r.base += u64(drop)
	}
}

// end is the logical offset just past the last byte appended — what an offset a record names
// is compared against to know whether its payload has gone past yet.
fn (r &RingVlsd) end() u64 {
	return r.base + u64(r.buf.len)
}

// skip advances the logical position over n bytes that were NOT kept (a record too large to be
// a payload): what was buffered is released with them, since the offsets after it must stay
// the writer's and a hole cannot be represented.
fn (mut r RingVlsd) skip(n u64) {
	r.base = r.end() + n
	r.buf.clear()
}

fn (mut r RingVlsd) at(off u64, n int) ?[]u8 {
	if off < r.base {
		r.evicted++
		return none
	}
	rel := off - r.base
	if n < 0 || rel > u64(r.buf.len) || u64(n) > u64(r.buf.len) - rel {
		return none
	}
	return r.buf[int(rel)..int(rel) + n]
}

// dz_decompress inflates a DZBLOCK and, for zip_type 1, reverses the byte-column
// transposition MDF applies before deflate to improve compression of records.
fn dz_decompress(mut src ByteSource, off u64) ![]u8 {
	d := data_off(mut src, off)
	zip_type := u8_at(mut src, d + 2)
	zip_param := int(u32_at(mut src, d + 4))
	org_len64 := u64_at(mut src, d + 8)
	data_len64 := u64_at(mut src, d + 16)
	// A DZ block is inflated WHOLE — it is the unit of memory for both readers — so its
	// declared original length is capped by a real number, not by what an int can count:
	// writers keep blocks to a few MB, and a block claiming more is either not one this reader
	// should trust or one it must not hold (codex on #342).
	if org_len64 > max_dz_block || data_len64 > max_dz_block {
		return error('DZ block of ${org_len64} bytes exceeds the ${max_dz_block / (1 << 20)} MB a block may inflate to')
	}
	// Bounded by the FILE before it sizes anything: a corrupt header claiming 2^31 compressed
	// bytes would otherwise allocate and zero-fill 2 GB before zlib got to refuse it.
	if d + 24 > src.size() || data_len64 > src.size() - (d + 24) {
		return error('DZ block claims ${data_len64} compressed bytes past the end of the file')
	}
	org_len := int(org_len64)
	data_len := int(data_len64)
	comp := bytes_at(mut src, d + 24, data_len)
	raw := zlib.decompress(comp)!
	if raw.len != org_len {
		return error('DZ length mismatch: got ${raw.len}, want ${org_len}')
	}
	if zip_type != 1 {
		return raw
	}
	// zip_type 1: data was stored column-major in `zip_param`-wide rows; undo it.
	cols := zip_param
	if cols <= 0 {
		return raw
	}
	rows := org_len / cols
	mut transposed := []u8{len: org_len}
	for c := 0; c < cols; c++ {
		col := c * rows
		for r := 0; r < rows; r++ {
			transposed[r * cols + c] = raw[col + r]
		}
	}
	// trailing bytes that don't fill a full row are stored as-is at the end.
	for i := rows * cols; i < org_len; i++ {
		transposed[i] = raw[i]
	}
	return transposed
}
