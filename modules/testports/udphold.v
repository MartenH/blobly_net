module testports

import net

// A UDP port held EXCLUSIVELY, which is what makes a UDP bind a verification (#416). V's
// `net.listen_udp` sets SO_REUSEADDR with no opt-out, so a bind beside any other holder succeeds
// and proves nothing (the head of testports.v). This socket is bound through C WITHOUT it — and on
// Windows with SO_EXCLUSIVEADDRUSE, where a plain bind may still be overtaken — so the kernel
// refuses it while anything else, on any address, has the port, and refuses everything else
// while it holds it. It is bound on the WILDCARD of its family (the IPv6 one dual-stack), the
// widest claim a later bind can conflict with.

#flag windows -lws2_32

#include <errno.h>

$if windows {
	#include <winsock2.h>
	#include <ws2tcpip.h>
} $else {
	#include <sys/socket.h>
	#include <netinet/in.h>
}

fn C.socket(domain i32, typ i32, protocol i32) i32
fn C.bind(sockfd i32, addr voidptr, addrlen u32) i32
fn C.setsockopt(sockfd i32, level i32, optname i32, optval voidptr, optlen u32) i32

// UdpHold is one exclusively bound UDP socket, held until `close`.
pub struct UdpHold {
pub:
	port int
	v6   bool
mut:
	handle int = -1
}

// hold_udp binds the wildcard of the family asked on `port` without address reuse, and keeps it.
// It fails while any other socket holds the port on any address of that family (or, for IPv6,
// either family), whatever options that socket set.
pub fn hold_udp(port int, v6 bool) !UdpHold {
	if port < 1 || port > 65535 {
		return error('port ${port} out of range')
	}
	addr := if v6 { net.new_ip6(u16(port), [16]u8{}) } else { net.new_ip(u16(port), [4]u8{}) }
	fd := int(C.socket(i32(addr.family()), i32(C.SOCK_DGRAM), 0))
	if fd < 0 {
		return error('UDP socket: ${net.error_code()}')
	}
	mut h := UdpHold{
		port:   port
		v6:     v6
		handle: fd
	}
	$if windows {
		one := i32(1)
		if C.setsockopt(i32(fd), i32(C.SOL_SOCKET), i32(C.SO_EXCLUSIVEADDRUSE), &one, sizeof(one)) != 0 {
			h.close()
			return error('SO_EXCLUSIVEADDRUSE: ${net.error_code()}')
		}
	}
	if v6 {
		zero := i32(0)
		if C.setsockopt(i32(fd), i32(C.IPPROTO_IPV6), i32(C.IPV6_V6ONLY), &zero, sizeof(zero)) != 0 {
			h.close()
			return error('IPV6_V6ONLY: ${net.error_code()}')
		}
	}
	if C.bind(i32(fd), voidptr(&addr), addr.len()) != 0 {
		code := net.error_code()
		h.close()
		return error('UDP port ${port} is held (${code})')
	}
	return h
}

// close releases the port. Closing twice is harmless.
pub fn (mut h UdpHold) close() {
	if h.handle >= 0 {
		net.close(h.handle) or {}
		h.handle = -1
	}
}

// Holder holds candidate ports for a server that binds TCP AND UDP on one number — a DoIP entity
// — until the server binds them: a TCP listener on the family's wildcard (refused while any
// address listens on the port) and an exclusive UDP socket beside it (refused while anything has
// the UDP port, a reuse-address listener included). A candidate held on either protocol is
// refused, so it is skipped. `hold` is the shape `project.PortProber` asks for.
pub struct Holder {
mut:
	tcp map[int]&net.TcpListener
	udp map[int]UdpHold
}

// hold binds `port` on both protocols in the family asked, or neither, and keeps it.
pub fn (mut p Holder) hold(port int, v6 bool) bool {
	if port in p.tcp {
		return false
	}
	mut l := if v6 {
		net.listen_tcp(.ip6, '[::]:${port}') or { return false }
	} else {
		net.listen_tcp(.ip, '0.0.0.0:${port}') or { return false }
	}
	u := hold_udp(port, v6) or {
		l.close() or {}
		return false
	}
	p.tcp[port] = l
	p.udp[port] = u
	return true
}

// release lets go of `port` on both protocols, if held, so the server can bind it.
pub fn (mut p Holder) release(port int) {
	if mut l := p.tcp[port] {
		l.close() or {}
		p.tcp.delete(port)
	}
	if mut u := p.udp[port] {
		u.close()
		p.udp.delete(port)
	}
}

// release_all lets go of every port still held.
pub fn (mut p Holder) release_all() {
	for port in p.tcp.keys() {
		p.release(port)
	}
}

// held lists the ports held, ascending.
pub fn (p Holder) held() []int {
	mut out := p.tcp.keys()
	out.sort()
	return out
}
