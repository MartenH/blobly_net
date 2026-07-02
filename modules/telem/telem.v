// telem — decode blobly_emb's runtime-observability frames (blobly_emb/docs/telemetry.md).
//
// The ECU ships its own per-core load + per-handler runtime timing over CAN, so a
// running target can be watched live in blobly_net with no probe. This module is the
// host-side inverse of blobly_emb/comm/{telem,trace}: fixed 8-byte little-endian frames,
// decoded here byte-for-byte (cross-validated against emb's own encode vectors — see
// telem_test.v). GUI-free + protocol-free, so it stays independently testable.
module telem

// Default CAN ids (the trace_demo wire; overridable per target). CpuLoad 0x7E0 is
// decoded via the DBC already; these are the observability-specific frames.
pub const id_loaddetail = u32(0x7E1) // one core's load over 100ms/1s/10s + overrun count
pub const id_trace_cmd = u32(0x7E2) // host -> target: capture control (not UDS)
pub const id_trace_rsp = u32(0x7E3) // target -> host: ack + status
pub const id_handlerstat = u32(0x7E4) // unsolicited per-handler live stats
pub const id_record = u32(0x7E5) // one captured handler-invocation record

// Frame flags shared by HandlerStat and Record (a superset; Record adds first_run).
pub const flag_overran = u8(0x01) // the invocation exceeded its period
pub const flag_preempted = u8(0x02) // the handler/thread was preempted (RTOS)
pub const flag_saturated = u8(0x04) // a µs field was clamped to the u16 range (HandlerStat)
pub const flag_first_run = u8(0x08) // Record: first invocation since capture start

// HandlerStat is the decoded per-handler live-stats push (id 0x7E4):
// b0 handler_id | b1 flags | b2-3 last_us | b4-5 max_us | b6-7 count_delta (all u16 LE).
// last/max are RESPONSE time (= CPU time on a no-IRQ polled core), µs, saturating.
pub struct HandlerStat {
pub:
	handler_id  u8
	flags       u8
	last_us     u16 // response time of the last invocation
	max_us      u16 // peak since the previous frame
	count_delta u16 // invocations since the previous frame
}

// decode_handlerstat decodes an 8-byte HandlerStat payload. Short payloads read 0 in the
// missing fields (a truncated frame still yields the id rather than erroring).
pub fn decode_handlerstat(p []u8) HandlerStat {
	return HandlerStat{
		handler_id:  u8_at(p, 0)
		flags:       u8_at(p, 1)
		last_us:     u16le(p, 2)
		max_us:      u16le(p, 4)
		count_delta: u16le(p, 6)
	}
}

// Record is one captured handler invocation (id 0x7E5, 8-byte bare-metal form):
// b0 handler_id | b1 flags | b2-5 start_us (u32 LE, µs from capture start) | b6-7 cpu_us
// (u16 LE, = response time on a no-IRQ core). A preemptive target widens this to carry
// response_us too; the base record stays 8 bytes.
pub struct Record {
pub:
	handler_id u8
	flags      u8
	start_us   u32 // µs relative to capture start
	cpu_us     u16 // execution time (saturating)
}

// decode_record decodes an 8-byte Record payload.
pub fn decode_record(p []u8) Record {
	return Record{
		handler_id: u8_at(p, 0)
		flags:      u8_at(p, 1)
		start_us:   u32le(p, 2)
		cpu_us:     u16le(p, 6)
	}
}

// LoadDetail is one core's load over three windows + overrun count (id 0x7E1):
// b0 load_100ms% | b1 load_1s% | b2 load_10s% | b3 overruns (saturating at 255).
pub struct LoadDetail {
pub:
	load_100ms u8
	load_1s    u8
	load_10s   u8
	overruns   u8
}

pub fn decode_loaddetail(p []u8) LoadDetail {
	return LoadDetail{
		load_100ms: u8_at(p, 0)
		load_1s:    u8_at(p, 1)
		load_10s:   u8_at(p, 2)
		overruns:   u8_at(p, 3)
	}
}

// --- little-endian readers, bounds-safe (a short frame reads 0 past its end) ---

fn u8_at(p []u8, i int) u8 {
	return if i < p.len { p[i] } else { u8(0) }
}

fn u16le(p []u8, i int) u16 {
	return u16(u8_at(p, i)) | (u16(u8_at(p, i + 1)) << 8)
}

fn u32le(p []u8, i int) u32 {
	return u32(u8_at(p, i)) | (u32(u8_at(p, i + 1)) << 8) | (u32(u8_at(p, i + 2)) << 16) | (u32(u8_at(p,
		i + 3)) << 24)
}
