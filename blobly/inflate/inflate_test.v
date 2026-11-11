module inflate

import compress.deflate
import compress.zlib as czlib

// Bits writes a DEFLATE bit stream, least significant bit first.
struct Bits {
mut:
	out  []u8
	acc  u32
	nacc int
}

fn (mut b Bits) put(v u32, n int) {
	b.acc |= v << u32(b.nacc)
	b.nacc += n
	for b.nacc >= 8 {
		b.out << u8(b.acc)
		b.acc >>= 8
		b.nacc -= 8
	}
}

// code writes a Huffman code, which DEFLATE packs most significant bit first.
fn (mut b Bits) code(v u32, n int) {
	for i := n - 1; i >= 0; i-- {
		b.put((v >> u32(i)) & 1, 1)
	}
}

fn (mut b Bits) done() []u8 {
	if b.nacc > 0 {
		b.out << u8(b.acc)
	}
	return b.out
}

// bomb is one fixed-Huffman block: a zero byte, then `copies` copies of 258 bytes at distance 1,
// so 13 bits of stream for every 258 zero bytes inflated (1 + 258 * copies in all).
fn bomb(copies int) []u8 {
	mut b := Bits{}
	b.put(1, 1) // final
	b.put(1, 2) // fixed Huffman
	b.code(0x30, 8) // literal 0
	for _ in 0 .. copies {
		b.code(0xC5, 8) // length 258
		b.code(0, 5) // distance 1
	}
	b.code(0, 7) // end of block
	return b.done()
}

fn test_a_stream_within_its_bound_is_inflated() {
	plain := 'a PDX is a ZIP of ODX documents '.repeat(100).bytes()
	r := deflate.compress_raw(plain)!
	assert raw(r, plain.len)! == plain
	z := czlib.compress(plain)!
	assert zlib(z, plain.len)! == plain
	assert raw(bomb(4), 1 + 258 * 4)! == []u8{len: 1 + 258 * 4}
	assert raw(deflate.compress_raw([]u8{})!, 0)!.len == 0
}

fn test_a_stream_past_its_bound_is_refused() {
	plain := []u8{len: 100_000, init: u8(index)}
	raw(deflate.compress_raw(plain)!, plain.len - 1) or {
		assert err.msg().contains('past the 99999 bytes')
		zlib(czlib.compress(plain)!, 10) or {
			assert err.msg().contains('past the 10 bytes')
			return
		}
		assert false, 'zlib: inflated past its bound'
	}
	assert false, 'raw: inflated past its bound'
}

fn test_a_bomb_is_refused_without_inflating_it() {
	// 3.4 MB of stream that inflates to 512 MB
	b := bomb(2_080_000)
	before := gc_heap_usage().heap_size
	raw(b, 1 << 20) or {
		assert err.msg().contains('past the 1048576 bytes')
		assert gc_heap_usage().heap_size - before < 64 << 20
		return
	}
	assert false, 'a bomb was inflated'
}

fn test_a_first_byte_is_read_as_deflate_never_as_a_header() {
	// a stored, non-final block whose padding sets bit 3 (a zlib CM of 8), then a final one
	mut d := [u8(0x08)]
	ab := 'AB'.repeat(14) + 'A'
	d << [u8(29), 0, 0xE2, 0xFF] // LEN 29, so 0x08 0x1D also passes a zlib header check
	d << ab.bytes()
	d << [u8(1), 1, 0, 0xFE, 0xFF, 0x43] // final stored block, "C"
	assert raw(d, 30)! == (ab + 'C').bytes()
	raw([u8(0x1F), 0x8B, 0, 0], 10) or {
		assert err.msg().contains('reserved block type')
		return
	}
	assert false, 'a reserved block type was read as gzip'
}
