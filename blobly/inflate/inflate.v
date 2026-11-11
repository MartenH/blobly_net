module inflate

import compress.deflate

// inflate.v — DEFLATE (RFC 1951) and zlib (RFC 1950) inflated to a stated size and no further.
// vlib's whole-buffer inflate grows its output until the stream ends, so a few KB that expand to
// GB are allocated before any size check can refuse them; this reads through vlib's chunked
// inflate and stops at the first chunk past the bound. Memory held is about twice the bound
// (vlib's own output and the copy returned), plus one 32 KB chunk.

// Sink collects inflated chunks up to `limit` bytes; `over` is set once a chunk would pass it.
struct Sink {
mut:
	out   []u8
	limit int
	over  bool
}

// take is the chunk callback: a chunk that fits is kept, one past the limit stops the inflate.
fn take(chunk []u8, userdata voidptr) int {
	mut s := unsafe { &Sink(userdata) }
	if chunk.len > s.limit - s.out.len {
		s.over = true
		return 0
	}
	s.out << chunk
	return chunk.len
}

// raw inflates the raw DEFLATE stream `data` to at most `limit` bytes; a stream that inflates
// further is refused once the bound is passed. Bytes after the final block are ignored.
pub fn raw(data []u8, limit int) ![]u8 {
	if data.len > 0 {
		// the first block's type, which vlib reads before guessing a zlib or gzip header
		if (data[0] >> 1) & 3 == 3 {
			return error('inflate: reserved block type')
		}
		// a stored, non-final first block: its padding bits are ignored (RFC 1951 3.2.4), and
		// cleared so the byte cannot pass for a zlib header
		if data[0] & 7 == 0 && data[0] != 0 {
			mut d := data.clone()
			d[0] = 0
			return run(d, limit)
		}
	}
	return run(data, limit)
}

// zlib inflates the zlib stream `data` to at most `limit` bytes, its Adler-32 checked; a stream
// that inflates further is refused once the bound is passed.
pub fn zlib(data []u8, limit int) ![]u8 {
	deflate.validate_zlib_header(data)!
	return run(data, limit)
}

fn run(data []u8, limit int) ![]u8 {
	if limit < 0 {
		return error('inflate: a negative bound')
	}
	mut s := &Sink{
		limit: limit
	}
	deflate.decompress_with_callback(data, take, s)!
	if s.over {
		return error('inflates past the ${limit} bytes allowed')
	}
	return s.out
}
