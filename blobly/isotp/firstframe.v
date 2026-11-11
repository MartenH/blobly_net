module isotp

// ff12_max is the longest message a First Frame's 12-bit length states; past it the 12 bits are 0,
// the escape, and the length is the next four bytes, big-endian (ISO 15765-2:2016).
pub const ff12_max = 4095

// first_frame_pci is the PCI of a First Frame for a message of `n` bytes: 1L LL, or past ff12_max
// 10 00 and the 32-bit length.
pub fn first_frame_pci(n int) []u8 {
	if n <= ff12_max {
		return [u8(0x10 | ((n >> 8) & 0x0F)), u8(n & 0xFF)]
	}
	return [u8(0x10), 0x00, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n)]
}

// first_frame_length is the length a First Frame declares and how many PCI bytes come before its
// data (2, or 6 behind the escape). An escaped length that fits 12 bits is refused, since a sender
// gives it in 12 bits (ISO 15765-2:2016 has a receiver ignore such a frame).
pub fn first_frame_length(frame []u8) !(i64, int) {
	if frame.len < 2 {
		return error('ISO-TP: First Frame of ${frame.len} bytes carries no length')
	}
	short := (i64(frame[0] & 0x0F) << 8) | i64(frame[1])
	if short != 0 {
		return short, 2
	}
	if frame.len < 6 {
		return error('ISO-TP: First Frame with the 32-bit length escape in ${frame.len} bytes')
	}
	long := (i64(frame[2]) << 24) | (i64(frame[3]) << 16) | (i64(frame[4]) << 8) | i64(frame[5])
	if long <= ff12_max {
		return error('ISO-TP: First Frame gives ${long} bytes behind the 32-bit escape, a length the 12-bit form states')
	}
	return long, 6
}

// transfer_wait_ms is the waiting allowance of one transfer of `n` bytes: `per_ms` for every
// ff12_max bytes begun, so each Flow Control a longer message asks for is given as long as a
// 4095-byte message gives it (fc_total_wait_ms).
pub fn transfer_wait_ms(per_ms int, n int) int {
	blocks := (n + ff12_max - 1) / ff12_max
	return if blocks > 1 { per_ms * blocks } else { per_ms }
}
