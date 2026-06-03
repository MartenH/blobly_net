// transport — CAN bus abstraction. The SocketCanBus backend (socketcan.v) talks
// to a Linux SocketCAN interface (vcan0 now, can0 later). Keeping a `Bus`
// interface means future backends (LIN, Ethernet) — or a mock — drop in without
// touching callers. GUI-free and independently testable.
module transport

// CanFrame is one classic CAN 2.0 frame (CAN-FD comes later).
pub struct CanFrame {
pub mut:
	id       u32  // 11-bit (SFF) or 29-bit (EFF) identifier, without flag bits
	extended bool // 29-bit extended identifier
	rtr      bool // remote transmission request
	data     []u8 // 0..8 payload bytes
}

// Bus is the transport contract. recv(timeout_ms) returns error('timeout') when
// no frame arrives in time; timeout_ms < 0 blocks indefinitely.
pub interface Bus {
mut:
	send(frame CanFrame) !
	recv(timeout_ms int) !CanFrame
	close()
}

// str renders a frame like `0x123 [3] DE AD BF` for logs/trace.
pub fn (f CanFrame) str() string {
	mut s := if f.extended { '0x${f.id:08X}' } else { '0x${f.id:03X}' }
	s += ' [${f.data.len}]'
	for b in f.data {
		s += ' ${b:02X}'
	}
	if f.rtr {
		s += ' RTR'
	}
	return s
}
