// The macOS half of listen_udp_shared (udpshared.v): a socket bound with SO_REUSEPORT, inside a
// net.UdpConn so every caller keeps vlib's API. vlib's socket constructor is private and binds
// before anyone can set an option, so the connection is made on an ephemeral port of the same
// family and the socket bound here is put in its descriptor's place (dup2). Everything vlib asks
// of the connection afterwards — the family (for the multicast join), reads, writes, timeouts,
// close — reads that descriptor or the family, both still right.
module transport

import net

#include "udp_reuseport_shim.h"

fn C.ct_udp_bind_reuseport(addr voidptr, len i32, v6 i32) i32
fn C.ct_udp_take_place(fd i32, target i32) i32
fn C.strerror(i32) &char

fn udp_cerr(errno i32) string {
	return unsafe { cstring_to_vstring(C.strerror(errno)) }
}

fn listen_udp_reuseport(laddr string) !&net.UdpConn {
	addrs := net.resolve_addrs_fuzzy(laddr, .udp)!
	if addrs.len == 0 {
		return error('udp: ${laddr} resolves to no address')
	}
	addr := addrs[0] // net.listen_udp binds the first too
	v6 := addr.family() == .ip6
	mut c := net.listen_udp(if v6 { '[::]:0' } else { '0.0.0.0:0' })!
	fd := C.ct_udp_bind_reuseport(voidptr(&addr), i32(addr.len()), i32(if v6 { 1 } else { 0 }))
	if fd < 0 {
		c.close() or {}
		return error('udp: listen ${laddr}: ${udp_cerr(-fd)}')
	}
	r := C.ct_udp_take_place(fd, i32(c.sock.handle))
	if r < 0 {
		c.close() or {}
		return error('udp: listen ${laddr}: ${udp_cerr(-r)}')
	}
	return c
}
