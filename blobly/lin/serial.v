module lin

import os

// The serial addresses and the rules every platform shares: `tty:<path>[@baud]` is a UART behind
// a LIN transceiver, `pty:<path>[@baud][,plain]` a pseudo-terminal. The backend is
// serial_linux.c.v.

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
	// plain: a pty carrying the bytes a UART would put on the wire and nothing else, as a
	// program that writes LIN to a serial port puts them into a pty — no break mark and no
	// escaped 0xFF (`,plain`).
	plain bool
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
	mut plain := false
	if path.ends_with(',plain') {
		if kind != .pty {
			return error('lin: `${address}`: `,plain` is for a pty; a tty carries real breaks')
		}
		plain = true
		path = path[..path.len - ',plain'.len]
	}
	if path.contains(',plain') {
		return error('lin: `${address}`: write `,plain` last, after the rate')
	}
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
		plain:   plain
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

// plain_quiet_ns is how long a plain pty is quiet before a frame whose header came from the other
// end is over: 20 bit times, at least 2 ms. On a pty that end is the master, which writes its
// response right behind its header, so a frame arrives in one burst; the next header comes a
// schedule slot later.
fn plain_quiet_ns(baud int) i64 {
	bits := i64(20) * 1_000_000_000 / i64(baud)
	return if bits > 2_000_000 { bits } else { i64(2_000_000) }
}

// most_path_file is the largest file device_path reads a device's path from.
const most_path_file = 4096

// device_path is the device a pty address's path names: the path, or, when the path is a
// regular file, the device path written on its first line — how a program that makes its own pty
// may say where it is (`/tmp/lin_slave_0` holding `/dev/pts/7`), so the address holds across its
// runs. A file written before its device was made names a pty that has since gone, whose number
// may now be somebody's terminal: refused.
pub fn device_path(a SerialAddr) !string {
	path := a.path
	if a.kind != .pty || !os.exists(path) || os.inode(path).typ != .regular {
		return path
	}
	if os.file_size(path) > most_path_file {
		return error('lin: `${path}` is a file of more than ${most_path_file} bytes, not one naming a device')
	}
	text := os.read_file(path) or { return error('lin: cannot read `${path}`: ${err}') }
	dev := text.split_into_lines()[0] or { '' }.trim_space()
	if dev == '' {
		return error('lin: `${path}` is a file but names no device on its first line')
	}
	if !os.exists(dev) {
		return error('lin: `${path}` names `${dev}`, which does not exist: is the program that made it running?')
	}
	if os.inode(dev).typ == .regular {
		return error('lin: `${path}` names `${dev}`, which is a file, not a device')
	}
	if os.stat(dev)!.ctime > os.stat(path)!.mtime {
		return error('lin: `${path}` was written before `${dev}` was made: it names a pty that has gone, and the number has been given to another')
	}
	return dev
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
	return i64(frame_bits_max(max_data)) * 1_000_000_000 / i64(baud) + serial_rx_margin_ns(kind)
}

// serial_rx_margin_ns is how long bytes already on the wire may take to reach this process.
fn serial_rx_margin_ns(kind SerialKind) i64 {
	return if kind == .tty { i64(20_000_000) } else { i64(50_000_000) }
}

// response_end is when a begun response is ended by its slot: a response that reached its
// length at once; one of no stated length on a tty only after the receive margin, since its
// last bytes may still be in an adapter's packet (a pty's decoder is current).
fn response_end(kind SerialKind, length_reached bool, slot_end_ns i64) i64 {
	if length_reached || kind == .pty {
		return slot_end_ns
	}
	return slot_end_ns + serial_rx_margin_ns(kind)
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
