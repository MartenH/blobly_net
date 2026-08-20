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
	// CAN-FD. `fd` is the FDF/EDL bit: a flexible-data-rate frame, which may carry up to 64
	// payload bytes and cannot be sent by a classic-only backend. `brs` is Bit Rate Switch —
	// the data phase runs at the faster rate. Both are properties of the FRAME, not the bus:
	// an FD-capable bus carries classic frames too, and a receiver distinguishes them.
	fd  bool
	brs bool
	// ESI — the transmitting node was error-passive when it sent this. A received STATUS, not a
	// choice the sender makes, which is why it is deliberately absent from the echo identity in
	// `wiretap` and from the trace's group key: a message whose transmitter goes error-passive
	// mid-run would otherwise split into two rows, or stop matching its own echo, on a bit that
	// says nothing about which message it is.
	esi bool
	// 0..8 payload bytes for a classic frame; 0..64 for an FD one, and only the lengths a DLC
	// can encode (0..8, 12, 16, 20, 24, 32, 48, 64) — anything else is padded on the way out.
	data []u8
}

// fd_lengths are the only payload sizes a CAN-FD DLC can express. A frame of 9 bytes does not
// exist on the wire: it is sent as 12 with the remainder padded, which is what every controller
// does and what a receiver expects.
pub const fd_lengths = [0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64]

// fd_padded_len rounds a payload length up to the next encodable CAN-FD length, or returns the
// length unchanged when it is already one. Above 64 there is nothing valid to round to.
pub fn fd_padded_len(n int) int {
	for l in fd_lengths {
		if n <= l {
			return l
		}
	}
	return 64
}

// fd_pad returns the payload a CAN-FD controller would actually transmit: the caller's bytes,
// zero-filled up to the next encodable length. ONE implementation, used by every backend — the
// software buses previously sent unpadded payloads while SocketCAN padded, so an in-process test
// did not reproduce the wire and a 9-byte frame behaved differently in each.
pub fn fd_pad(data []u8) []u8 {
	want := fd_padded_len(data.len)
	if want == data.len {
		return data
	}
	mut out := []u8{len: want}
	for i, b in data {
		if i < want {
			out[i] = b
		}
	}
	return out
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
	// PLATFORM-DEPENDENT, because the dispatchers are: only open_windows.v routes `pcan:`,
	// `kvaser:` and `vector:` to a vendor driver. On Linux open_linux.v sends everything that is not a
	// software bus to SocketCAN — which echoes — so a channel someone configured as
	// `pcan:bench` there is an ordinary SocketCAN name, and treating it as a vendor backend
	// would leave its frames untracked and its echoes filed as the device under test's.
	$if windows {
		i := iface.to_lower()
		return i.starts_with('pcan:') || i.starts_with('kvaser:') || i.starts_with('vector:')
	} $else {
		return false
	}
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
	// SocketCAN only. The software buses carry what they are given, and the VENDOR drivers
	// REJECT an out-of-range id or length rather than truncating it — CAN_Write and canWrite
	// return an error, which PcanBus.send/KvaserBus.send surface. Masking before handing them
	// the frame would turn that rejection into a valid-but-different transmission (0x800 sent as
	// 0x000), which is the opposite of what a bench needs from a malformed frame.
	return !software_iface(iface) && !vendor_iface(iface)
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
	// NO trim: the dispatcher does not trim either, so `inproc:bench` and `inproc:bench ` are two
	// different hubs. Collapsing them here would give two physically separate buses one identity,
	// and a generator on the second would try to claim the first one's echoes.
	i := iface // case as given, too: the dispatcher's parsers are case-sensitive
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

// same_destination reports whether two interface strings would open the SAME bus. Stricter than
// canonical_iface, which normalises the software buses only: the Windows vendor backends accept
// SEVERAL spellings of one channel (`PCAN_USBBUS1`, `usb1`, `1`, `0x51` all resolve to one
// handle) and treat an omitted bitrate as the default, so two mappings can address one physical
// channel while looking different. A conflict check that compares strings misses exactly that,
// and the cost is two recorded buses emitted onto one wire.
pub fn same_destination(a string, b string) bool {
	return destination_key(a) == destination_key(b)
}

// destination_key is the identity used for that comparison: the canonical software-bus form,
// or for a vendor interface the backend, the RESOLVED channel handle and the bitrate.
//
// Resolved by the backend's own function, not by a second implementation of its rules. A
// parallel one drifts: stripping the `usb` prefix gave `pcan:usb1` the key `1` while `pcan:0x51`
// — the same channel, since PCAN_USBBUS1 IS 0x51 — keyed as `81`, so two mappings onto one
// physical bus still looked different. Whatever the backend will open is the identity.
pub fn destination_key(iface string) string {
	i := iface.trim_space()
	if !vendor_iface(i) {
		return canonical_iface(i)
	}
	return vendor_destination_key(i)
}

// vendor_destination_key is the vendor half of destination_key, WITHOUT the platform guard.
// Callers that are opening a bus want destination_key; callers reading a project written
// elsewhere want this.
pub fn vendor_destination_key(iface string) string {
	i := iface.trim_space()
	body := i.all_before('@')
	kind := body.all_before(':').to_lower()
	ch := body.all_after(':').trim_space()
	// NUMERICALLY, where the backend parses numerically. open_kvaser takes `.int()` of the
	// channel and both vendor opens take `.int()` of the bitrate, so `kvaser:0` and `kvaser:00`,
	// or `@500000` and `@0500000`, open the same channel at the same rate while differing as
	// strings. Comparing the strings let two mappings share one physical bus undetected.
	raw_rate := if i.contains('@') { i.all_after('@').trim_space() } else { '500000' }
	rate := raw_rate.int().str()
	mut resolved := ch.to_lower()
	$if windows {
		if kind == 'pcan' {
			if h := pcan_handle(ch) {
				resolved = '0x${h:X}'
			}
			// An unresolvable channel keeps its spelling: two identical bad strings still
			// collide, and a wrong guess here would merge buses that never open at all.
		} else if kind == 'kvaser' {
			resolved = ch.int().str() // exactly what open_kvaser does with it
		} else if kind == 'vector' {
			// Through the SAME resolver open_vector uses, so `vector:1`, `vector:ch1` and
			// `vector:app01` are one destination. The mode suffix is already gone: it sits
			// after the bitrate, which this function reduces to a number.
			resolved = vector_key(ch)
		}
	}
	return '${kind}:${resolved}@${rate}'
}

// destination_key_for is destination_key for code that is READING a project rather than opening
// it. The platform guard in vendor_iface is right for opening — on Linux a channel somebody
// named `pcan:bench` really is a SocketCAN interface — but wrong for analysis: opening a
// recording on Linux against a project authored for a Windows bench must still see `vector:1`
// and `vector:ch1` as one wire, because on the machine that made the recording they were.
//
// The project's own `adapter` field is what settles it, and only these paths have it.
pub fn destination_key_for(adapter string, iface string) string {
	if adapter in ['pcan', 'kvaser', 'vector'] {
		return vendor_destination_key(iface)
	}
	return destination_key(iface)
}

// wire_frame is the frame this interface will ACTUALLY put on the bus. Where the backend clamps,
// that means a classic id masked to its declared width and at most 8 bytes: a caller that records
// what it ASKED for records something that never existed — and, for echo matching, something that
// can never come back. Where the backend does not clamp, the frame is already what goes out.
//
// SEND this, do not merely record it, or the record and the echo disagree the other way round.
pub fn wire_frame(iface string, f CanFrame) CanFrame {
	if !clamps_to_classic(iface) {
		// The software buses carry ids and lengths verbatim, but an FD payload is still padded
		// to an encodable length on its way out — so it is padded HERE too. Otherwise the record
		// holds 9 bytes while 12 go on the wire, the echo never matches its own record, and the
		// frame shows up as somebody else's traffic plus one of ours that never came back.
		if f.fd && fd_padded_len(f.data.len) != f.data.len {
			return CanFrame{
				...f
				data: fd_pad(f.data)
			}
		}
		return f
	}
	// The ID too, and to its DECLARED width: SocketCAN masks a standard id with can_sff_mask, so
	// `extended: false` with 0x800 goes out as 0x000 while the caller recorded 0x800 — a record
	// that can never match its own echo, hence a false BUS row and an unconfirmed one of ours.
	id := if f.extended { f.id & 0x1FFF_FFFF } else { f.id & 0x7FF }
	// An FD frame is NOT clamped to 8. SocketCAN carries it whole now, and the vendor backends
	// refuse it outright rather than sending a short version — so truncating here would record a
	// frame that never goes out either way, which is the mistake this function exists to avoid.
	// It is still padded to a length a DLC can express, because that is what reaches the wire.
	max := if f.fd { 64 } else { 8 }
	if id == f.id && f.data.len <= max && (!f.fd || fd_padded_len(f.data.len) == f.data.len) {
		return f
	}
	mut data := f.data.clone()
	if data.len > max {
		data = data[..max].clone()
	}
	if f.fd {
		data = fd_pad(data)
	}
	return CanFrame{
		...f
		id:   id
		data: data
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
