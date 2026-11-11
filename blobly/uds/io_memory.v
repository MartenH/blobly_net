// io_memory.v — what a simulated server answers beyond its DID and DTC tables: DID 0xF186 from the
// session it is in, 0x2F InputOutputControlByIdentifier on the IO DIDs it declares, and 0x23 /
// 0x3D memory by address inside the ranges it declares. With nothing declared 0x2F, 0x23 and 0x3D
// stay serviceNotSupported.
module uds

// did_active_session is ISO 14229-1's ActiveDiagnosticSessionDataIdentifier.
pub const did_active_session = u16(0xF186)

// The bytes a positive answer puts before a value: 0x62 and the identifier for 0x22, 0x6F, the
// identifier and the control parameter for 0x2F, 0x63 for 0x23. What a declared value may hold is
// the carrier's longest answer less its service's header, the one rule a server's builder and its
// validation both ask (did_value_max, io_value_max, memory_read_max).
pub const did_answer_header = 3
pub const io_answer_header = 4
pub const memory_answer_header = 1

// did_value_max is the longest DID value a 0x22 answer of at most `cap` bytes carries.
pub fn did_value_max(cap int) int {
	return cap - did_answer_header
}

// io_value_max is the longest IO DID value a 0x2F answer of at most `cap` bytes carries.
pub fn io_value_max(cap int) int {
	return cap - io_answer_header
}

// memory_read_max is the most bytes one 0x23 answer of at most `cap` bytes carries.
pub fn memory_read_max(cap int) int {
	return cap - memory_answer_header
}

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

// io_sized: whether a 0x2E record of `n` bytes may be written to DID `id` — an IO DID takes
// exactly its declared size, so a 0x2F answer carrying its value stays within what one answer
// carries; any other DID takes what the server's own rules take.
fn (s &Server) io_sized(id u16, n int) bool {
	start := s.io_start[id] or { return true }
	return n == start.len
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
// value as it then stands — 0x14 responseTooLong, the value unchanged, where that answer would be
// longer than the carrier takes. 01..03 leave the DID held by the tester (io_held), so a live DID
// reads the held value until 00 returns it to its signal.
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
	if iocp == 0x02 {
		s.refresh_io_live(id) // a freeze keeps what the signal reads now
	}
	value := match iocp {
		0x00, 0x01 { start }
		0x03 { req[4..] }
		else { s.dids[id] or { start } }
	}
	// never an answer the carrier refuses: the value stays as it was and the tester is told
	if value.len > io_value_max(s.spec.resp_cap()) {
		return neg(0x2F, 0x14)
	}
	s.dids[id] = value.clone()
	if iocp == 0x00 {
		s.io_held.delete(id)
	} else {
		s.io_held[id] = true
	}
	mut resp := [u8(0x6F), req[1], req[2], iocp]
	resp << value
	return resp
}

// return_io_control puts every IO DID back to its start value: what entering the default session
// and an ECU reset do to control 0x2F took over.
fn (mut s Server) return_io_control() {
	for id, start in s.io_start {
		s.dids[id] = start.clone()
	}
	s.io_held = map[u16]bool{}
}

// refresh_io_live puts a live IO DID's signal value into the table where no tester holds it.
fn (mut s Server) refresh_io_live(id u16) {
	if !s.described || id in s.io_held {
		return
	}
	d := s.did_spec(id) or { return }
	if d.source == .live {
		s.refresh_live(d)
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
	if m.size > u64(memory_read_max(s.spec.resp_cap())) {
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
