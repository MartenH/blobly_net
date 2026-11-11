module uds

// services.v — RoutineControl (0x31), InputOutputControlByIdentifier (0x2F), ReadMemoryByAddress
// (0x23) and WriteMemoryByAddress (0x3D): each request built by ISO 14229-1's format, an argument
// outside it refused before anything is sent, and the answer read past what it echoes.

pub const sid_read_memory_by_address = u8(0x23)
pub const sid_io_control_by_identifier = u8(0x2F)
pub const sid_routine_control = u8(0x31)
pub const sid_write_memory_by_address = u8(0x3D)

// RoutineControl (0x31) control types.
pub const routine_start = u8(0x01)
pub const routine_stop = u8(0x02)
pub const routine_results = u8(0x03)

// InputOutputControlByIdentifier (0x2F) control parameters.
pub const io_return_control = u8(0x00)
pub const io_reset_to_default = u8(0x01)
pub const io_freeze_current_state = u8(0x02)
pub const io_short_term_adjustment = u8(0x03)

// The widths an addressAndLengthFormatIdentifier may give an address and a size here: one byte
// to the eight a u64 holds.
pub const max_address_bytes = 8
pub const max_size_bytes = 8

// routine_request is `31 <control> <rid> <option>`: control 1 (start), 2 (stop) or 3 (results),
// without the suppress bit, since the helper awaits the routine's answer.
pub fn routine_request(rid u16, option []u8, control u8) ![]u8 {
	if control < routine_start || control > routine_results {
		return error('UDS: routine control 0x${control:02X}: give 1 (start), 2 (stop) or 3 (results)')
	}
	mut req := [sid_routine_control, control, u8(rid >> 8), u8(rid)]
	req << option
	return req
}

// io_control_request is `2F <did> <parameter> <state> <mask>`: parameter 0 (return control to
// the ECU), 1 (reset to default), 2 (freeze current state) or 3 (short-term adjustment).
pub fn io_control_request(did u16, parameter u8, state []u8, mask []u8) ![]u8 {
	if parameter > io_short_term_adjustment {
		return error('UDS: I/O control parameter 0x${parameter:02X}: give 0 (return control), 1 (reset to default), 2 (freeze) or 3 (short-term adjustment)')
	}
	mut req := [sid_io_control_by_identifier, u8(did >> 8), u8(did), parameter]
	req << state
	req << mask
	return req
}

// memory_fields is the addressAndLengthFormatIdentifier, then the address and the size, each
// big-endian in the width it names; a width outside 1..8, a value it cannot hold, or a size of 0
// is refused.
fn memory_fields(address u64, size u64, address_bytes int, size_bytes int) ![]u8 {
	if address_bytes < 1 || address_bytes > max_address_bytes {
		return error('UDS: address_bytes ${address_bytes}: give 1..${max_address_bytes}')
	}
	if size_bytes < 1 || size_bytes > max_size_bytes {
		return error('UDS: size_bytes ${size_bytes}: give 1..${max_size_bytes}')
	}
	if address_bytes < 8 && address >> (8 * address_bytes) != 0 {
		return error('UDS: address 0x${address:X} does not fit in ${address_bytes} bytes')
	}
	if size == 0 {
		return error('UDS: a memory size of 0 bytes')
	}
	if size_bytes < 8 && size >> (8 * size_bytes) != 0 {
		return error('UDS: size ${size} does not fit in ${size_bytes} bytes')
	}
	mut out := [u8(size_bytes << 4 | address_bytes)]
	for i := address_bytes - 1; i >= 0; i-- {
		out << u8(address >> (8 * i))
	}
	for i := size_bytes - 1; i >= 0; i-- {
		out << u8(size >> (8 * i))
	}
	return out
}

// read_memory_request is `23 <format> <address> <size>`.
pub fn read_memory_request(address u64, size u64, address_bytes int, size_bytes int) ![]u8 {
	mut req := [sid_read_memory_by_address]
	req << memory_fields(address, size, address_bytes, size_bytes)!
	return req
}

// write_memory_request is `3D <format> <address> <size> <data>`, the size data's length.
pub fn write_memory_request(address u64, data []u8, address_bytes int, size_bytes int) ![]u8 {
	mut req := [sid_write_memory_by_address]
	req << memory_fields(address, u64(data.len), address_bytes, size_bytes)!
	req << data
	return req
}

// routine (0x31) runs `control` on routine `rid` with its option record and returns the answer
// after the echoed control and identifier: the routine's info and status record.
pub fn (mut c Client) routine(rid u16, option []u8, control u8) ![]u8 {
	resp := c.raw(routine_request(rid, option, control)!)!
	// 71 <control> <rid>: the echo is the exchange's to have checked
	return resp[4..].clone()
}

// io_control (0x2F) asks DID `did`'s input or output to follow `parameter`, with its control
// state and enable mask, and returns the answer after the echoed DID and parameter: the state.
pub fn (mut c Client) io_control(did u16, parameter u8, state []u8, mask []u8) ![]u8 {
	resp := c.raw(io_control_request(did, parameter, state, mask)!)!
	// 6F <did> <parameter> <state>: the DID's echo is the exchange's, the parameter's this one's
	if resp.len < 4 || resp[3] != parameter {
		return UndecodableAnswer{
			why: 'I/O control answer ${resp.hex()} does not echo parameter 0x${parameter:02X}'
		}
	}
	return resp[4..].clone()
}

// read_memory (0x23) reads `size` bytes at `address`, each as wide as its argument names.
pub fn (mut c Client) read_memory(address u64, size u64, address_bytes int, size_bytes int) ![]u8 {
	resp := c.raw(read_memory_request(address, size, address_bytes, size_bytes)!)!
	// 63 <data>: the bytes asked for, no more and no fewer
	if u64(resp.len - 1) != size {
		return UndecodableAnswer{
			why: 'memory read answered ${resp.len - 1} bytes for the ${size} asked'
		}
	}
	return resp[1..].clone()
}

// write_memory (0x3D) writes `data` at `address`, the address and its length as wide as named.
pub fn (mut c Client) write_memory(address u64, data []u8, address_bytes int, size_bytes int) ! {
	// 7D <format> <address> <size>: the echo is the exchange's to have checked
	c.raw(write_memory_request(address, data, address_bytes, size_bytes)!)!
}
