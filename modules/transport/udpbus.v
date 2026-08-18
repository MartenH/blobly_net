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

pub struct UdpBus {
mut:
	tx  &net.UdpConn = unsafe { nil } // dialed to group:port — sends
	rx  &net.UdpConn = unsafe { nil } // bound to port + joined group — receives
	src u32 // our source id; frames with this src are our own echoes
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
	if frame.rtr {
		flags |= 0x02
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
	for {
		remaining := deadline - time.ticks()
		if remaining <= 0 {
			return error('timeout')
		}
		b.rx.set_read_timeout(time.Duration(remaining * 1_000_000)) // ms → ns
		n, _ := b.rx.read(mut buf) or { return error('timeout') }
		if n < 10 {
			continue
		}
		if get_u32_le(buf, 0) == b.src {
			continue // our own frame echoed back — ignore
		}
		dlc := int(buf[9])
		if 10 + dlc > n {
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

pub fn (mut b UdpBus) close() {
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
