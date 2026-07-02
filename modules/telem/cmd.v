// telem/cmd — the capture control protocol (blobly_emb/docs/telemetry.md "Control & read-out").
//
// Config-declared cmd/rsp (NOT UDS): the host sends a TraceCmd on cmd_id (0x7E2) to
// arm/stop/reset/dump; the target acks with a TraceRsp on rsp_id (0x7E3) and, on dump,
// streams its buffer out as Record frames (0x7E5). blobly_net builds the cmd here.
module telem

// TraceCmd opcodes (b0). Match blobly_emb/comm/trace/control.v.
pub const op_arm = u8(1) // (re)arm capture from empty
pub const op_start = u8(2) // begin capturing (alias of arm)
pub const op_stop = u8(3) // stop now (freeze/full at the current fill)
pub const op_reset = u8(4) // clear + re-arm
pub const op_set_push = u8(5) // configure the unsolicited push
pub const op_dump = u8(6) // stream the buffer out (as Record frames)
pub const op_status = u8(7) // just report state

pub const filter_all = u16(0xFFFF) // handler_filter sentinel: all handlers

// TraceRsp state (b2).
pub const state_idle = u8(0)
pub const state_capturing = u8(1)
pub const state_full = u8(2)
pub const state_frozen = u8(3)

// encode_trace_cmd builds the 8-byte TraceCmd payload:
// b0 opcode | b1 arg0 | b2-3 period_ms | b4-5 handler_filter | b6-7 reserved (all LE).
pub fn encode_trace_cmd(opcode u8, handler_filter u16) []u8 {
	return [
		opcode,
		u8(0), // arg0
		u8(0), // period_ms lo
		u8(0), // period_ms hi
		u8(handler_filter), // filter lo
		u8(handler_filter >> 8), // filter hi
		u8(0),
		u8(0),
	]
}

// TraceRsp is the decoded target ack (id 0x7E3):
// b0 opcode_echo | b1 result | b2 state | b3-4 records_used | b5-6 capacity | b7 core.
pub struct TraceRsp {
pub:
	opcode_echo  u8
	result       u8 // 0 = ok
	state        u8
	records_used u16
	capacity     u16
	core         u8
}

pub fn decode_trace_rsp(p []u8) TraceRsp {
	return TraceRsp{
		opcode_echo:  u8_at(p, 0)
		result:       u8_at(p, 1)
		state:        u8_at(p, 2)
		records_used: u16le(p, 3)
		capacity:     u16le(p, 5)
		core:         u8_at(p, 7)
	}
}
