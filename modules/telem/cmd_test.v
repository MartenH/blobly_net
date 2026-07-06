module telem

// A dump command for all handlers across cores 0+1: opcode 6, filter 0xFFFF, mask 0x0003.
fn test_encode_trace_cmd_dump() {
	c := encode_trace_cmd(op_dump, filter_all, 0x0003)
	assert c.len == 8
	assert c[0] == op_dump
	assert c[4] == 0xFF && c[5] == 0xFF // handler_filter = all
	assert c[6] == 0x03 && c[7] == 0x00 // core_mask = 0x0003 LE (cores 0 + 1)
}

fn test_encode_trace_cmd_filtered() {
	c := encode_trace_cmd(op_arm, 0x0102, 0)
	assert c[0] == op_arm
	assert c[4] == 0x02 && c[5] == 0x01 // 0x0102 LE
	assert c[6] == 0x00 && c[7] == 0x00 // mask 0 = the receiving core
}

// emb: a TraceRsp echoing op_status, ok, state=full, used=64, cap=64, core=0.
fn test_decode_trace_rsp() {
	// b0 echo | b1 result | b2 state | b3-4 used | b5-6 cap | b7 core
	r := decode_trace_rsp([op_status, 0, state_full, 64, 0, 64, 0, 0])
	assert r.opcode_echo == op_status
	assert r.result == 0
	assert r.state == state_full
	assert r.records_used == 64
	assert r.capacity == 64
	assert r.core == 0
}
