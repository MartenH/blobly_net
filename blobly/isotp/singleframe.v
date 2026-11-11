module isotp

// sf_max is the longest message a Single Frame carries in a frame of `dl` bytes: 7 behind the 4-bit
// length of a classic frame, dl - 2 behind the escape of a longer CAN-FD one (ISO 15765-2:2016).
pub fn sf_max(dl int) int {
	return if dl <= 8 { 7 } else { dl - 2 }
}

// single_frame decodes an ISO-TP Single Frame — its payload, or why the frame is not one. In a frame
// of up to 8 bytes the length is the first byte's low nibble; in a longer (CAN-FD) one the first
// byte is 0x00, the escape, and the length the second byte. The software channel's receive path and
// a raw listener for functional requests (which ISO 15765-2 confines to one Single Frame) both ask
// it, so the two cannot disagree about a frame.
pub fn single_frame(data []u8) ![]u8 {
	if data.len == 0 || data[0] & 0xF0 != 0x00 {
		return error('ISO-TP: not a Single Frame')
	}
	if data.len > 8 {
		if data[0] != 0x00 {
			return error('ISO-TP: Single Frame length ${data[0] & 0x0F} in a ${data.len}-byte frame: a frame longer than 8 bytes gives its length behind the escape (first byte 0x00)')
		}
		len := int(data[1])
		if len == 0 {
			return error('ISO-TP: empty Single Frame')
		}
		if 2 + len > data.len {
			return error('ISO-TP SF length ${len} exceeds frame')
		}
		return data[2..2 + len].clone()
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
