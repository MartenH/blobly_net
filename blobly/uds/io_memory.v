// io_memory.v — what a simulated server answers beyond its DID and DTC tables: DID 0xF186 from the
// session it is in, 0x2F InputOutputControlByIdentifier on the IO DIDs it declares, and 0x23 /
// 0x3D memory by address inside the ranges it declares. With nothing declared 0x2F, 0x23 and 0x3D
// stay serviceNotSupported.
module uds

// did_active_session is ISO 14229-1's ActiveDiagnosticSessionDataIdentifier.
pub const did_active_session = u16(0xF186)

// MemRange is one declared memory range: its start address and its contents.
pub struct MemRange {
pub:
	address u64
pub mut:
	data []u8
}

// session_did: DID 0xF186 answered from the session the server is in, where its table holds no
// value of its own for it.
fn (s &Server) session_did(id u16) ?[]u8 {
	if id == did_active_session && id !in s.dids {
		return [s.session]
	}
	return none
}

// declare_io makes `id` an IO DID 0x2F controls, `size` zero bytes at start; it reads back through
// 0x22 (on a described server readable in every session, not writable through 0x2E).
pub fn (mut s Server) declare_io(id u16, size int) {
	start := []u8{len: size}
	s.io_start[id] = start
	if s.described {
		s.put_did(id, start)
	} else {
		s.dids[id] = start.clone()
	}
}

// declare_memory adds a range 0x23 and 0x3D reach, `size` zero bytes at `address`.
pub fn (mut s Server) declare_memory(address u64, size int) {
	s.memory << MemRange{
		address: address
		data:    []u8{len: size}
	}
}

// io_control answers 0x2F: 00 returnControlToECU and 01 resetToDefault put the start value back,
// 02 freezeCurrentState keeps the value, 03 shortTermAdjustment sets it; the answer carries the
// value as it then stands.
fn (mut s Server) io_control(req []u8) []u8 {
	if req.len < 4 {
		return neg(0x2F, 0x13)
	}
	id := u16(req[1]) << 8 | u16(req[2])
	start := s.io_start[id] or { return neg(0x2F, 0x31) }
	iocp := req[3]
	if iocp > 0x03 {
		return neg(0x2F, 0x31)
	}
	want := if iocp == 0x03 { 4 + start.len } else { 4 }
	if req.len != want {
		return neg(0x2F, 0x13)
	}
	match iocp {
		0x00, 0x01 { s.dids[id] = start.clone() }
		0x03 { s.dids[id] = req[4..].clone() }
		else {}
	}
	mut resp := [u8(0x6F), req[1], req[2], iocp]
	resp << s.dids[id] or { start }
	return resp
}

// return_io_control puts every IO DID back to its start value: what entering the default session
// and an ECU reset do to control 0x2F took over.
fn (mut s Server) return_io_control() {
	for id, start in s.io_start {
		s.dids[id] = start.clone()
	}
}

// MemRequest is a 0x23/0x3D request's address and size, and where its record starts.
struct MemRequest {
	address u64
	size    u64
	next    int
}

// mem_request parses addressAndLengthFormatIdentifier (high nibble: the size's bytes, low nibble:
// the address's) and the fields it describes: 0x13 when the request is shorter than they are,
// 0x31 for a nibble of 0 or one wider than 8 bytes.
fn mem_request(req []u8) !MemRequest {
	if req.len < 2 {
		return error_with_code('length', 0x13)
	}
	alen := int(req[1] & 0x0F)
	slen := int(req[1] >> 4)
	if req.len < 2 + alen + slen {
		return error_with_code('length', 0x13)
	}
	if alen == 0 || slen == 0 || alen > 8 || slen > 8 {
		return error_with_code('format', 0x31)
	}
	mut address := u64(0)
	for i in 0 .. alen {
		address = address << 8 | u64(req[2 + i])
	}
	mut size := u64(0)
	for i in 0 .. slen {
		size = size << 8 | u64(req[2 + alen + i])
	}
	return MemRequest{
		address: address
		size:    size
		next:    2 + alen + slen
	}
}

// mem_range is the declared range holding all of [address, address+size), and the offset into it.
fn (s &Server) mem_range(address u64, size u64) ?(int, int) {
	if size == 0 {
		return none
	}
	for i, r in s.memory {
		if address >= r.address && size <= u64(r.data.len) && address - r.address <= u64(r.data.len) - size {
			return i, int(address - r.address)
		}
	}
	return none
}

// read_memory answers 0x23 ReadMemoryByAddress: the bytes of one declared range, 0x31 outside
// every range or past what one answer carries.
fn (mut s Server) read_memory(req []u8) []u8 {
	m := mem_request(req) or { return neg(0x23, u8(err.code())) }
	if req.len != m.next {
		return neg(0x23, 0x13)
	}
	ri, off := s.mem_range(m.address, m.size) or { return neg(0x23, 0x31) }
	if m.size + 1 > u64(s.spec.resp_cap()) {
		return neg(0x23, 0x31)
	}
	mut resp := [u8(0x63)]
	resp << s.memory[ri].data[off..off + int(m.size)]
	return resp
}

// write_memory answers 0x3D WriteMemoryByAddress: the record written into one declared range, the
// answer echoing the format identifier, address and size.
fn (mut s Server) write_memory(req []u8) []u8 {
	m := mem_request(req) or { return neg(0x3D, u8(err.code())) }
	if u64(req.len - m.next) != m.size {
		return neg(0x3D, 0x13)
	}
	ri, off := s.mem_range(m.address, m.size) or { return neg(0x3D, 0x31) }
	for i in 0 .. int(m.size) {
		s.memory[ri].data[off + i] = req[m.next + i]
	}
	mut resp := [u8(0x7D)]
	resp << req[1..m.next]
	return resp
}
