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
pub const id_record = u32(0x7E5) // captured-trace dump (ISO-TP block: target -> host)
pub const id_dump_fc = u32(0x7E6) // ISO-TP flow control the host sends for the Record dump

// Frame flags shared by HandlerStat and Record (a superset; Record adds first_run).
pub const flag_overran = u8(0x01) // the invocation exceeded its period
pub const flag_preempted = u8(0x02) // the handler/thread was preempted (RTOS)
pub const flag_saturated = u8(0x04) // a µs field was clamped to the u16 range (HandlerStat)
pub const flag_first_run = u8(0x08) // Record: first invocation since capture start
// Record ENTITY KIND — the top 2 bits of entity_id (matches emb comm/trace/trace.v). A dumped
// stream mixes kinds in one 8-byte cell; classify with kind() before reading the fields.
pub const kind_isr = u8(0) // id = raw interrupt vector
pub const kind_thread = u8(1) // id = thread id (id 0 = idle / no thread)
pub const kind_fb = u8(2) // id = handler id (the manifest fb.handler id)
pub const kind_control = u8(3) // id = a CONTROL subtype (block header, epoch)

// CONTROL subtypes (id when kind == kind_control).
pub const ctl_block = u16(0) // per-core block header leading one core's block in a multi-core dump
pub const ctl_epoch = u16(1) // timeline origin: re-anchors the u24 start_us base for long captures
pub const ctl_coreoffset = u16(2) // this block's core clock vs the dumping core's (emb REQ-TRACE-011)

// THREAD `info` — why the core LEFT the outgoing thread (the preemption/exit signal).
pub const reason_preempt = u8(0) // still ready, resumes later (a higher-priority thread/ISR woke)
pub const reason_block = u8(1) // voluntarily blocked
pub const reason_yield = u8(2) // voluntarily yielded
pub const reason_exit = u8(3) // completed / terminated

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

// Record is one interval in a captured dump (id 0x7E5, 8-byte form, matches emb comm/trace):
// an entity ran [start_us, start_us + cpu_us). Wire layout:
//   b0-1 entity_id (LE) — kind:2 (bits 15-14) | id:14 (bits 13-0)
//   b2   info          — THREAD: the outgoing reason; FB: per-run flags; CONTROL: a payload byte
//   b3-5 start_us       — u24 LE, µs from the current epoch origin
//   b6-7 cpu_us         — u16 LE, execution time (saturating)
// Classify with kind()/is_block_header()/is_epoch() before reading the kind-specific fields.
pub struct Record {
pub:
	entity_id u16
	info      u8
	start_us  u32 // u24 (µs from the current epoch)
	cpu_us    u16
}

pub fn decode_record(p []u8) Record {
	return Record{
		entity_id: u16(u8_at(p, 0)) | (u16(u8_at(p, 1)) << 8)
		info:      u8_at(p, 2)
		start_us:  u32(u8_at(p, 3)) | (u32(u8_at(p, 4)) << 8) | (u32(u8_at(p, 5)) << 16)
		cpu_us:    u16le(p, 6)
	}
}

// kind / id split entity_id (2 top bits = kind, low 14 = id).
pub fn (r Record) kind() u8 {
	return u8(r.entity_id >> 14)
}

pub fn (r Record) id() u16 {
	return r.entity_id & 0x3fff
}

// flags / reason are both the `info` byte, read under the right kind (FB flags vs THREAD reason).
pub fn (r Record) flags() u8 {
	return r.info
}

pub fn (r Record) reason() u8 {
	return r.info
}

// is_idle reports the idle "thread" (kind THREAD, id 0 = no thread ready).
pub fn (r Record) is_idle() bool {
	return r.kind() == kind_thread && r.id() == 0
}

// is_block_header / header_* — the per-core dump block header (CONTROL / ctl_block): info = core,
// start_us + cpu_us<<24 = the count of records that follow.
pub fn (r Record) is_block_header() bool {
	return r.kind() == kind_control && r.id() == ctl_block
}

pub fn (r Record) header_core() u8 {
	return r.info & 0x7f // bit 7 = header_more
}

// header_more: further blocks for this core follow (a multi-block dump); the end-of-stream
// lives IN the format, so the same block sequence rides any transport.
pub fn (r Record) header_more() bool {
	return r.info & 0x80 != 0
}

pub fn (r Record) header_count() u32 {
	return r.start_us | (u32(r.cpu_us) << 24)
}

// is_epoch / epoch_base — a timeline-origin reset (CONTROL / ctl_epoch): subsequent records'
// start_us are relative to epoch_base (info<<24 | start_us), so long captures stay ordered.
pub fn (r Record) is_epoch() bool {
	return r.kind() == kind_control && r.id() == ctl_epoch
}

pub fn (r Record) epoch_base() u32 {
	return r.start_us | (u32(r.info) << 24)
}

// is_core_offset / core_offset_* — how this block's core clock relates to the DUMPING core's
// (CONTROL / ctl_coreoffset). Each core timestamps from its own free-running origin, so blocks
// are not comparable until this is applied: subtract core_offset_us() from every following
// record's absolute µs to land on the dumping core's timeline.
//
// core_offset_bound_us() is the residual uncertainty of the measurement (half the round trip that
// produced it) — surface it rather than round it away. An ABSENT record means "never measured":
// leave the lanes uncorrelated and say so; do not assume zero skew.
pub fn (r Record) is_core_offset() bool {
	return r.kind() == kind_control && r.id() == ctl_coreoffset
}

pub fn (r Record) core_offset_us() i32 {
	return i32(r.start_us | (u32(r.info) << 24))
}

pub fn (r Record) core_offset_bound_us() u16 {
	return r.cpu_us
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
