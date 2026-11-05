module lin

// The serial addresses and the rules every platform shares: `tty:<path>[@baud]` is a UART behind
// a LIN transceiver, `pty:<path>[@baud]` a pseudo-terminal. The backend is serial_linux.c.v.

pub enum SerialKind {
	tty
	pty
}

pub struct SerialAddr {
pub:
	address string
	kind    SerialKind
	path    string
	// baud is the rate the address states, 0 for none.
	baud int
}

// is_serial is whether an address names a serial port.
pub fn is_serial(address string) bool {
	return address.starts_with('tty:') || address.starts_with('pty:')
}

// parse_serial reads a `tty:` or `pty:` address.
pub fn parse_serial(address string) !SerialAddr {
	kind := if address.starts_with('tty:') {
		SerialKind.tty
	} else if address.starts_with('pty:') {
		SerialKind.pty
	} else {
		return error('lin: `${address}` is not a serial address (tty:<path> or pty:<path>)')
	}
	mut path := address[4..]
	mut baud := 0
	if at := path.last_index('@') {
		rate := path[at + 1..]
		path = path[..at]
		if rate == '' || !rate.bytes().all(it.is_digit()) || rate.len > 6 {
			return error('lin: `${address}`: the rate after @ must be a number of baud, not `${rate}`')
		}
		baud = rate.int()
		if baud < 1000 || baud > 20000 {
			return error("lin: `${address}`: ${baud} baud is outside LIN's 1000..20000")
		}
	}
	if path == '' {
		return error('lin: `${address}` names no device — write ${address[..4]}<path>[@baud]')
	}
	return SerialAddr{
		address: address
		kind:    kind
		path:    path
		baud:    baud
	}
}

// address_baud is the rate a serial address states, none when it states none or is not one.
pub fn address_baud(address string) ?int {
	if !is_serial(address) {
		return none
	}
	a := parse_serial(address) or { return none }
	return if a.baud == 0 { none } else { a.baud }
}

// serial_baud is the rate a serial handle runs at: the address's, else the configuration's. An
// address rate that a stated configuration rate contradicts is refused.
fn serial_baud(a SerialAddr, cfg Config) !int {
	if a.baud == 0 {
		return cfg.rate()
	}
	if cfg.baud != 0 && cfg.baud != a.baud {
		return error('lin: `${a.address}` states ${a.baud} baud, but ${cfg.baud} was asked for')
	}
	return a.baud
}

// serial_unsupported is the refusal of a serial address where this build has no serial backend.
pub fn serial_unsupported(address string) string {
	return 'lin: cannot open `${address}`: serial LIN is Linux-only in this build'
}

// pty_bytes is what goes into a pseudo-terminal for a break (optional) and data bytes: the
// PARMRK form a tty's reader would have seen, since a pty drops a break — FF 00 00 for the
// break, FF FF for a data 0xFF.
fn pty_bytes(brk bool, data []u8) []u8 {
	mut out := []u8{cap: data.len + 3}
	if brk {
		out << [u8(0xFF), 0x00, 0x00]
	}
	for d in data {
		out << d
		if d == 0xFF {
			out << 0xFF
		}
	}
	return out
}

// serial_idle_ns is how long the line must be quiet before an open frame is ended: the longest
// response a frame may take (TFrame_Maximum of 8 data bytes) and a margin for the host — a USB
// adapter delivers in packets, a pty's other end answers from a thread.
fn serial_idle_ns(kind SerialKind, baud int) i64 {
	margin := if kind == .tty { i64(20_000_000) } else { i64(50_000_000) }
	return i64(frame_bits_max(max_data)) * 1_000_000_000 / i64(baud) + margin
}

// break_ns is the break a master sends: 13 bit times, LIN's minimum; delimiter_ns the recessive
// gap after it, two bit times.
fn break_ns(baud int) i64 {
	return (i64(13) * 1_000_000_000 + i64(baud) - 1) / i64(baud)
}

fn delimiter_ns(baud int) i64 {
	return (i64(2) * 1_000_000_000 + i64(baud) - 1) / i64(baud)
}

// frame_ns_max is TFrame_Maximum for n data bytes at a baud rate: the slot a header opens.
fn frame_ns_max(n int, baud int) i64 {
	return i64(frame_bits_max(n)) * 1_000_000_000 / i64(baud)
}

// wake_byte is the byte a wakeup is sent as: a dominant run from its start bit (0xFF << k, LSB
// first) as long as fits in 4 ms, which keeps it within LIN's 250 us .. 5 ms at every rate from
// 1000 to 20000 baud (0xF8, 4 ms, at 1000; 0x00, nine bits, from 2250).
fn wake_byte(baud int) u8 {
	mut k := 8
	for k > 0 && i64(1 + k) * 1_000_000_000 > i64(4_000_000) * i64(baud) {
		k--
	}
	return u8((u32(0xFF) << k) & 0xFF)
}

// rate_refusal is why a port that took `got` baud when asked for `asked` cannot carry the bus:
// off by more than LIN's clock tolerance, 0.5 % for a master, 1.5 % for a node that does not
// synchronise on the sync field.
pub fn rate_refusal(address string, role Role, asked int, got int) ?string {
	permille := if role == .master { 5 } else { 15 }
	diff := if got > asked { got - asked } else { asked - got }
	if i64(diff) * 1000 <= i64(asked) * permille {
		return none
	}
	return 'lin: `${address}` runs at ${got} baud, not ${asked}: the adapter cannot produce this rate within the ${f64(permille) / 10:.1f} % a ${role} may be off'
}

// wrap_delta is how far a 32-bit kernel counter moved from `last` to `now`, across a wrap.
fn wrap_delta(now u64, last u64) u64 {
	return u64(u32(now) - u32(last))
}

// request_valid is whether a MasterReq response as written (8 data bytes and the checksum) is a
// whole, correct one.
fn request_valid(resp []u8) bool {
	return resp.len == max_data + 1
		&& checksum(.classic, pid(master_req), resp[..max_data]) == resp[max_data]
}
