// udpbus — a cross-platform virtual CAN bus over localhost UDP multicast.
//
// SocketCAN's `vcan0` is Linux-only; Windows has no kernel virtual CAN. This
// backend is the portable stand-in: every participant joins a multicast group,
// so each one sees every frame (CAN broadcast semantics) with NO kernel device
// and NO drivers. Pure V (vlib `net`), so it builds + runs on Windows, Linux and
// macOS — develop/verify on Linux, ship to Windows unchanged. It implements the
// same `Bus` interface as the SocketCAN backend, so it's a drop-in.
//
// packet: [src u32][id u32][flags u8: 0x01 ext, 0x02 rtr, 0x04 fd, 0x08 brs, 0x10 esi][len u8][data 0..64]
// `src` is a per-instance id so we drop our own echoed frames — multicast
// loopback must be ON for same-host peers to receive each other, which also
// echoes our own sends back to us.
module transport

import net
import rand
import sync.stdatomic
import time

pub const udp_default_group = '239.63.42.1'
pub const udp_default_port = 20000

// UdpTarget is a parsed `udp[:group[:port]]` software-bus interface spec.
pub struct UdpTarget {
	group string
	port  int
}

// parse_udp_iface recognises software-bus interfaces of the form `udp`,
// `udp:GROUP`, or `udp:GROUP:PORT` (defaults fill any missing part). Returns
// none for anything else (e.g. `vcan0`, `can0`). Used by open() to dispatch.
fn parse_udp_iface(iface string) ?UdpTarget {
	if iface != 'udp' && !iface.starts_with('udp:') {
		return none
	}
	mut group := udp_default_group
	mut port := udp_default_port
	if iface.starts_with('udp:') {
		parts := iface[4..].split(':')
		if parts.len >= 1 && parts[0].len > 0 {
			group = parts[0]
		}
		if parts.len >= 2 && parts[1].len > 0 {
			port = parts[1].int()
		}
	}
	return UdpTarget{group, port}
}

// zero_poll_filtered_datagrams bounds how many filtered datagrams one zero-timeout poll crosses.
const zero_poll_filtered_datagrams = 4096

pub struct UdpBus {
mut:
	tx  &net.UdpConn = unsafe { nil } // dialed to group:port — sends
	rx  &net.UdpConn = unsafe { nil } // bound to port + joined group — receives
	src u32 // our source id; frames with this src are our own echoes
	// closed is set by close(): a recv(-1) blocked in another thread must stop retrying once the
	// socket is gone, instead of spinning on the read error forever (codex round 7 on #225).
	closed_flag i64
	closed      bool // unused: see closed_flag; read/written through stdatomic: close() runs on another thread than recv(-1)
}

// open_udp joins the localhost multicast bus `group:port`.
pub fn open_udp(group string, port int) !&UdpBus {
	mut tx := net.dial_udp('${group}:${port}')!
	tx.set_multicast_loop(true)! // same-host peers (and we) receive; we filter own
	mut rx := net.listen_udp('0.0.0.0:${port}')!
	rx.join_multicast_group(group, '0.0.0.0')!
	return &UdpBus{
		tx:  tx
		rx:  rx
		src: rand.u32()
	}
}

pub fn (mut b UdpBus) send(frame CanFrame) ! {
	// Same rule as the in-process bus, and for the same reason: this is a software wire, so the
	// only thing keeping impossible frames off it is this check. Lengths are left to the padding
	// tier — see frame_rules.v.
	if why := frame_send_refusal(frame) {
		return error('udp: ${why}')
	}
	// Same padding as the hardware path: a software bus that carries a 9-byte FD payload
	// verbatim does not reproduce the wire, and a test against it would pass where hardware
	// would not.
	payload := if frame.fd { fd_pad(frame.data) } else { frame.data }
	mut pkt := []u8{cap: 10 + payload.len}
	put_u32_le(mut pkt, b.src)
	put_u32_le(mut pkt, frame.id)
	mut flags := u8(0)
	if frame.extended {
		flags |= 0x01
	}
	if frame.fd {
		flags |= 0x04
	}
	if frame.brs {
		flags |= 0x08
	}
	if frame.esi {
		flags |= 0x10
	}
	pkt << flags
	pkt << u8(payload.len)
	pkt << payload
	b.tx.write(pkt)!
}

// recv returns the next frame from another participant within timeout_ms, or
// error('timeout'). Our own echoed frames (multicast loopback) are skipped.
pub fn (mut b UdpBus) recv(timeout_ms int) !CanFrame {
	deadline := time.ticks() + i64(timeout_ms)
	// 10-byte header + up to 64 payload bytes. The old 64-byte buffer silently truncated a
	// CAN-FD frame at read(), losing bytes before any of the decoding below could see them.
	mut buf := []u8{len: 10 + 64}
	// A zero-timeout poll looks past filtered datagrams (our own echo, malformed) but not
	// forever: a socket fed a continuous stream of them would never let it return (codex round
	// 17 on #225).
	mut filtered := 0
	for {
		if timeout_ms == 0 && filtered >= zero_poll_filtered_datagrams {
			return error('timeout')
		}
		// NEGATIVE IS FOREVER, as every other bus has it: computed as a deadline it was a deadline
		// in the past, and recv(-1) returned timeout without reading (codex round 6 on #225, via
		// the software ISO-TP channel that now runs on this bus off Linux). Waited in one-second
		// slices so a close can still be noticed by the read failing.
		mut remaining := i64(1000)
		if timeout_ms >= 0 {
			remaining = deadline - time.ticks()
			// ZERO IS ONE LOOK: a datagram already queued is returned by a non-blocking poll
			// (codex round 8 on #225). The socket read below gets the shortest timeout it takes.
			// A zero timeout keeps LOOKING past datagrams the filters below drop — our own echo
			// most commonly — until the socket is empty, which the read reports as a timeout of
			// its own (codex round 9 on #225). A positive timeout expires by the clock.
			if remaining <= 0 && timeout_ms > 0 {
				return error('timeout')
			}
			if remaining <= 0 {
				remaining = 1
			}
		}
		b.rx.set_read_timeout(time.Duration(remaining * 1_000_000)) // ms → ns
		n, _ := b.rx.read(mut buf) or {
			if stdatomic.load_i64(&b.closed_flag) != 0 {
				return error('bus is closed')
			}
			if timeout_ms < 0 && err.code() == net.err_timed_out_code {
				continue // a slice ended without a frame; forever means forever
			}
			if timeout_ms < 0 {
				return err // not a timeout: the socket is gone
			}
			return error('timeout')
		}
		if n < 10 {
			filtered++
			continue
		}
		if get_u32_le(buf, 0) == b.src {
			filtered++
			continue // our own frame echoed back — ignore
		}
		dlc := int(buf[9])
		if 10 + dlc > n {
			filtered++ // truncated: counted against the poll budget like the others (codex round 18)
			continue
		}
		flags := buf[8]
		return CanFrame{
			id:       get_u32_le(buf, 4)
			extended: flags & 0x01 != 0
			rtr:      flags & 0x02 != 0
			fd:       flags & 0x04 != 0
			brs:      flags & 0x08 != 0
			esi:      flags & 0x10 != 0
			data:     buf[10..10 + dlc].clone()
		}
	}
	return error('timeout')
}

// health: a UDP datagram bus has no CAN controller — nothing to report, honestly.
pub fn (mut b UdpBus) health() BusHealth {
	return .unknown
}

// diagnostics: nothing this backend counts beyond frames and the health ladder (#213).
pub fn (mut b UdpBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

// reconcile_silence — nothing to reconcile: this bus has no controller, so it generates no
// acknowledgement and `SilentBus` refusing its sends is the whole of listen-only here.
pub fn (mut b UdpBus) reconcile_silence(want bool) ! {
	{}
}

pub fn (mut b UdpBus) close() {
	stdatomic.store_i64(&b.closed_flag, 1)
	b.tx.close() or {}
	b.rx.close() or {}
}

fn put_u32_le(mut b []u8, v u32) {
	b << u8(v)
	b << u8(v >> 8)
	b << u8(v >> 16)
	b << u8(v >> 24)
}

fn get_u32_le(b []u8, off int) u32 {
	return u32(b[off]) | (u32(b[off + 1]) << 8) | (u32(b[off + 2]) << 16) | (u32(b[off + 3]) << 24)
}
