module telem

// Block decoding is where a multi-core dump becomes ONE timeline, so the corrections are pinned
// here rather than in a front end. Byte layouts match blobly_emb comm/trace/trace.v.

fn hdr(core u8, count u32, more bool) []u8 {
	info := if more { core | 0x80 } else { core }
	return [u8(0x00), 0xC0, info, u8(count), u8(count >> 8), u8(count >> 16), u8(count >> 24),
		0]
}

fn epoch(base u32) []u8 {
	return [u8(0x01), 0xC0, u8(base >> 24), u8(base), u8(base >> 8), u8(base >> 16), 0, 0]
}

fn coreoff(off i32, bound u16) []u8 {
	u := u32(off)
	return [u8(0x02), 0xC0, u8(u >> 24), u8(u), u8(u >> 8), u8(u >> 16), u8(bound), u8(bound >> 8)]
}

fn fb(id u16, start u32, cpu u16) []u8 {
	eid := (u16(kind_fb) << 14) | id
	return [u8(eid), u8(eid >> 8), 0, u8(start), u8(start >> 8), u8(start >> 16), u8(cpu),
		u8(cpu >> 8)]
}

// The dumping core: no offset record, so its records land at face value and skew stays UNKNOWN.
// "Unknown" must not be reported as 0 skew — that would claim a correlation nobody measured.
fn test_block_without_offset_is_not_claimed_correlated() {
	mut raw := []u8{}
	raw << hdr(0, 2, false)
	raw << epoch(0)
	raw << fb(7, 1000, 50)
	b := decode_block(raw)
	assert b.core == 0 && !b.more
	assert !b.skew_known
	assert b.skew_us == 0
	assert b.records.len == 1 // framing consumed, not emitted as a timeline event
	assert b.records[0].abs_us == 1000
	assert b.records[0].rec.id() == 7
}

// A satellite released AFTER the dumping core reads LESS at the same instant, so its offset is
// negative and correcting it moves records LATER. Getting the sign backwards still produces a
// plausible-looking chart, which is exactly why this is pinned.
fn test_negative_offset_shifts_records_later() {
	mut raw := []u8{}
	raw << hdr(1, 2, false)
	raw << epoch(0)
	raw << coreoff(-1_250_000, 42)
	raw << fb(3, 2000, 10)
	b := decode_block(raw)
	assert b.core == 1
	assert b.skew_known && b.skew_us == -1_250_000 && b.skew_bound_us == 42
	assert b.records.len == 1
	assert b.records[0].abs_us == 2000 + 1_250_000 // 2000 - (-1_250_000)
}

// The other direction: a core whose clock runs ahead is pulled BACK onto the dumping core's
// timeline, and a record earlier than the offset clamps at 0 instead of wrapping the u64.
fn test_positive_offset_shifts_back_and_clamps() {
	mut raw := []u8{}
	raw << hdr(1, 3, false)
	raw << epoch(0)
	raw << coreoff(5000, 7)
	raw << fb(1, 9000, 5) // well past the offset
	raw << fb(2, 100, 5)  // BEFORE it — would go negative
	b := decode_block(raw)
	assert b.records.len == 2
	assert b.records[0].abs_us == 4000 // 9000 - 5000
	assert b.records[1].abs_us == 0 // clamped, not wrapped to ~1.8e19
}

// Epoch and offset compose: the base is added, then the skew subtracted.
fn test_epoch_and_offset_compose() {
	mut raw := []u8{}
	raw << hdr(1, 3, false)
	raw << epoch(0x0100_0000) // 16_777_216 µs, past the u24 range
	raw << coreoff(-1000, 3)
	raw << fb(9, 500, 5)
	b := decode_block(raw)
	assert b.records[0].abs_us == u64(0x0100_0000) + 500 + 1000
}

// Every block re-states its epoch and offset, so a LATER block decodes standalone — a host must
// not need the first block to read the third.
fn test_continuation_block_decodes_standalone() {
	mut raw := []u8{}
	raw << hdr(1, 3, true) // more = true
	raw << epoch(0)
	raw << coreoff(-1_250_000, 42)
	raw << fb(4, 3000, 5)
	b := decode_block(raw)
	assert b.more
	assert b.skew_known && b.skew_us == -1_250_000
	assert b.records[0].abs_us == 3000 + 1_250_000
}
