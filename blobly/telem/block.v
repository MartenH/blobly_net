module telem

// Dump-block decoding — the protocol-level step that turns one ISO-TP block into records placed
// on a single timeline. This lives in the engine, not in a front end: the GUI Trace Chart and
// `cmd/trace_dump` must agree on what a dump MEANS, or the "non-GUI twin" shows a different
// picture than the chart. It is also the only way this logic gets unit tests.
//
// Two corrections are applied here, and both are easy to get wrong by hand:
//
//  1. `ctl_epoch` — a record's `start_us` is only 24 bits (~16.8 s), so a long capture re-anchors
//     and every following record is relative to the new base.
//  2. `ctl_coreoffset` — each core timestamps from ITS OWN free-running origin, so a satellite
//     core's records are not comparable to the dumping core's until its measured offset is
//     subtracted (blobly_emb REQ-TRACE-011).

// BlockRecord is one timeline record, already placed on the DUMPING core's timeline: the epoch
// base added and the core-clock offset removed.
pub struct BlockRecord {
pub:
	abs_us u64 // µs on the dumping core's timeline
	rec    Record
}

// Block is one decoded dump block: which core it came from, whether more blocks follow for that
// core, the cross-core correlation it carried, and its timeline records (framing removed).
pub struct Block {
pub:
	core          int  // from the leading block header
	more          bool // further blocks follow for this core
	skew_us       i32  // this core's clock minus the dumping core's (0 when unknown)
	skew_known    bool // a ctl_coreoffset record was present — never assume 0 means "in sync"
	skew_bound_us u16  // measurement uncertainty (half the round trip that produced it)
	records       []BlockRecord
}

// decode_block decodes one dump block. Records are returned in wire order with CONTROL framing
// (header / epoch / core-offset) consumed rather than emitted — those describe the timeline, they
// are not events on it.
//
// The target re-states the epoch and the core offset at the head of EVERY block, so a block is
// decodable on its own; callers must not need block 1 in hand to read block 3.
pub fn decode_block(raw []u8) Block {
	mut core := 0
	mut more := false
	mut base := u32(0)
	mut skew := i32(0)
	mut skew_known := false
	mut bound := u16(0)
	mut out := []BlockRecord{}
	for off := 0; off + 8 <= raw.len; off += 8 {
		r := decode_record(raw[off..off + 8])
		if r.is_block_header() {
			core = int(r.header_core())
			more = r.header_more()
			continue
		}
		if r.is_epoch() {
			base = r.epoch_base()
			continue
		}
		if r.is_core_offset() {
			skew = r.core_offset_us()
			bound = r.core_offset_bound_us()
			skew_known = true
			continue
		}
		// Signed intermediate: a satellite released later reads LESS than the dumping core, so
		// the offset is negative and this grows. Clamp anyway — a positive offset on an early
		// record must not wrap the u64.
		t := i64(base) + i64(r.start_us) - i64(skew)
		out << BlockRecord{
			abs_us: if t > 0 { u64(t) } else { u64(0) }
			rec:    r
		}
	}
	return Block{
		core:          core
		more:          more
		skew_us:       skew
		skew_known:    skew_known
		skew_bound_us: bound
		records:       out
	}
}
