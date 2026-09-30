module isotp

// single_frame decodes a classic ISO-TP Single Frame — its payload, or why the frame is not one.
// The software channel's receive path and a raw listener for functional requests (which ISO
// 15765-2 confines to one Single Frame) both ask it, so the two cannot disagree about a frame.
pub fn single_frame(data []u8) ![]u8 {
	if data.len == 0 || data[0] & 0xF0 != 0x00 {
		return error('ISO-TP: not a Single Frame')
	}
	len := int(data[0] & 0x0F)
	if len > 7 {
		// Classic ISO-TP: a Single Frame carries at most seven bytes; anything above is not one
		// (codex round 14 on #225).
		return error('ISO-TP: Single Frame length ${len} exceeds 7')
	}
	if len == 0 {
		// SF_DL 0 is invalid on the wire; the send side refuses to produce one, and the receive
		// side must not present it as an empty reply (codex round 9 on #225).
		return error('ISO-TP: empty Single Frame')
	}
	if 1 + len > data.len {
		return error('ISO-TP SF length ${len} exceeds frame')
	}
	return data[1..1 + len].clone()
}
