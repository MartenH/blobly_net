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

// clamps_to_classic reports whether this backend rewrites a frame on the way out. The kernel and
// vendor drivers take a classic CAN frame — 11/29-bit id, at most 8 bytes — and silently clamp
// both (ct_can_send). The SOFTWARE buses carry whatever they are handed, which is what makes
// in-process CAN-FD payloads work (docs/simulation.md), so normalising there would not describe
// the wire, it would damage it.
pub fn clamps_to_classic(iface string) bool {
	return !software_iface(iface)
}

// software_iface recognises the in-process and UDP buses the SAME way the dispatcher does:
// the bare word or the word plus ':'. A loose prefix test would claim a perfectly ordinary
// SocketCAN interface named `udp0` or `inproc0`, which on Linux opens as SocketCAN — and then
// the frame we recorded would differ from the one the kernel actually clamped and sent.
pub fn software_iface(iface string) bool {
	// CASE-SENSITIVE, like the dispatcher's own parsers: `UDP` and `INPROC` are not the software
	// buses, they are ordinary interface names that open as SocketCAN on Linux — and treating
	// them as software buses leaves their frames un-normalised while the kernel clamps what it
	// actually transmits.
	return iface == 'inproc' || iface.starts_with('inproc:') || iface == 'udp'
		|| iface.starts_with('udp:')
}

// canonical_iface collapses the spellings of one bus to a single identity. `inproc` and
// `inproc:CAN` open the same hub, as do `udp` and `udp:239.63.42.1:20000` — the parsers fill the
// defaults. As STRINGS they differ, so a monitor opened one way and a generator override written
// the other way would key their pending records, watcher lists and send locks separately: the
// frame reaches the monitor, cannot claim its own record, and lands in the trace as the device
// under test's. Physical opens still take the caller's spelling; this is for identity only.
pub fn canonical_iface(iface string) string {
	i := iface.trim_space() // case as given: the dispatcher's parsers are case-sensitive
	if i == 'inproc' || i == 'inproc:' {
		return 'inproc:CAN' // parse_inproc_iface's default name, for both empty spellings
	}
	if i == 'udp' || i.starts_with('udp:') {
		if t := parse_udp_iface(i) {
			return 'udp:${t.group}:${t.port}'
		}
	}
	return i
}

// wire_frame is the frame this interface will ACTUALLY put on the bus. Where the backend clamps,
// that means a classic id masked to its declared width and at most 8 bytes: a caller that records
// what it ASKED for records something that never existed — and, for echo matching, something that
// can never come back. Where the backend does not clamp, the frame is already what goes out.
//
// SEND this, do not merely record it, or the record and the echo disagree the other way round.
pub fn wire_frame(iface string, f CanFrame) CanFrame {
	if !clamps_to_classic(iface) {
		return f
	}
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
