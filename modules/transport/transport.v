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

// echoes_own_sends reports whether frames written to this interface come back to another bus
// instance on the same host. The virtual backends and SocketCAN do (SocketCAN loops transmitted
// frames back to every other socket by default); the vendor drivers do NOT hand our own
// transmissions back, so on those a caller waiting for its own frame waits forever — and must
// not read that silence as the bus having dropped it.
// vendor_iface reports the Windows vendor backends, whose address may carry an `@<bitrate>`
// suffix. Nothing else uses `@` as syntax — `inproc:bench@A` is a perfectly good bus NAME, and
// treating the suffix as universal sent the emitters to a different hub than the monitor.
pub fn vendor_iface(iface string) bool {
	i := iface.to_lower()
	return i.starts_with('pcan:') || i.starts_with('kvaser:')
}

pub fn echoes_own_sends(iface string) bool {
	// The vendor backends do not hand our own transmissions back. Matched by DISPATCHER prefix,
	// separator included: on Linux anything without one is opened as SocketCAN, which does echo,
	// so a plain interface a user happened to name `pcan0` must not be mistaken for one.
	return !vendor_iface(iface)
}

// wire_frame is the frame this interface will ACTUALLY put on the bus. Classic CAN carries at
// most 8 bytes and the backends truncate silently (ct_can_send clamps len), so a caller that
// records what it asked for records something that never existed — and, for the echo matching,
// can never match what comes back.
pub fn wire_frame(iface string, f CanFrame) CanFrame {
	// The ID too, and to its DECLARED width: SocketCAN masks a standard id with can_sff_mask, so
	// `extended: false` with 0x800 goes out as 0x000 while the caller recorded 0x800 — a record
	// that can never match its own echo, hence a false BUS row and an unconfirmed one of ours.
	id := if f.extended { f.id & 0x1FFF_FFFF } else { f.id & 0x7FF }
	if id == f.id && f.data.len <= 8 {
		return f
	}
	return CanFrame{
		...f
		id:   id
		data: if f.data.len > 8 { f.data[..8].clone() } else { f.data }
	}
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
