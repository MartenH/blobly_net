module testports

import net

// Ports held EXCLUSIVELY, which is what makes a bind a verification (#416). V's `net.listen_udp`
// sets SO_REUSEADDR with no opt-out, so a UDP bind beside any other holder succeeds and proves
// nothing (the head of testports.v); `net.listen_tcp` sets it too, which on Windows lets a bind
// take a port another socket is listening on. These sockets are bound through C instead: UDP
// without SO_REUSEADDR, TCP with it only off Windows (where it merely tolerates TIME_WAIT, and a
// LISTENING socket is still refused beside any other bind), and on Windows both with
// SO_EXCLUSIVEADDRUSE. So the kernel refuses a hold while anything else, on any address, has the
// port, and refuses everything else while the hold lasts. Bound on the WILDCARD of its family
// (the IPv6 one dual-stack), the widest claim a later bind can conflict with.

#flag windows -lws2_32

$if windows {
	#include <winsock2.h>
	#include <ws2tcpip.h>
} $else {
	#include <sys/socket.h>
	#include <netinet/in.h>
}

fn C.socket(domain i32, typ i32, protocol i32) i32
fn C.bind(sockfd i32, addr voidptr, addrlen u32) i32
fn C.listen(sockfd i32, backlog i32) i32
fn C.setsockopt(sockfd i32, level i32, optname i32, optval voidptr, optlen u32) i32

// PortHold is one exclusively bound socket, held until `close`.
pub struct PortHold {
pub:
	port int
	v6   bool
	udp  bool
mut:
	handle int = -1
}

// hold_udp holds `port` over UDP: refused while any other socket has the UDP port on any address
// of the family (for IPv6, of either family), whatever options that socket set.
pub fn hold_udp(port int, v6 bool) !PortHold {
	return hold_port(port, v6, true)
}

// hold_tcp holds `port` over TCP, as a listener, with the same refusals as hold_udp.
pub fn hold_tcp(port int, v6 bool) !PortHold {
	return hold_port(port, v6, false)
}

fn hold_port(port int, v6 bool, udp bool) !PortHold {
	if port < 1 || port > 65535 {
		return error('port ${port} out of range')
	}
	addr := if v6 { net.new_ip6(u16(port), [16]u8{}) } else { net.new_ip(u16(port), [4]u8{}) }
	typ := if udp { i32(C.SOCK_DGRAM) } else { i32(C.SOCK_STREAM) }
	fd := int(C.socket(i32(addr.family()), typ, 0))
	if fd < 0 {
		return error('socket: ${net.error_code()}')
	}
	mut h := PortHold{
		port:   port
		v6:     v6
		udp:    udp
		handle: fd
	}
	one := i32(1)
	$if windows {
		if C.setsockopt(i32(fd), i32(C.SOL_SOCKET), i32(C.SO_EXCLUSIVEADDRUSE), &one, sizeof(one)) != 0 {
			h.close()
			return error('SO_EXCLUSIVEADDRUSE: ${net.error_code()}')
		}
	} $else {
		if !udp && C.setsockopt(i32(fd), i32(C.SOL_SOCKET), i32(C.SO_REUSEADDR), &one, sizeof(one)) != 0 {
			h.close()
			return error('SO_REUSEADDR: ${net.error_code()}')
		}
	}
	if v6 {
		zero := i32(0)
		if C.setsockopt(i32(fd), i32(C.IPPROTO_IPV6), i32(C.IPV6_V6ONLY), &zero, sizeof(zero)) != 0 {
			h.close()
			return error('IPV6_V6ONLY: ${net.error_code()}')
		}
	}
	if C.bind(i32(fd), voidptr(&addr), addr.len()) != 0
		|| (!udp && C.listen(i32(fd), 1) != 0) {
		code := net.error_code()
		h.close()
		return error('${if udp { 'UDP' } else { 'TCP' }} port ${port} is held (${code})')
	}
	return h
}

// close releases the port. Closing twice is harmless.
pub fn (mut h PortHold) close() {
	if h.handle >= 0 {
		net.close(h.handle) or {}
		h.handle = -1
	}
}

// Holder holds candidate ports for a server that binds TCP AND UDP on one number — a DoIP entity
// — until the server binds them. A candidate held by anything else on either protocol is
// refused, so it is skipped. `hold` is the shape `project.PortProber` asks for.
pub struct Holder {
mut:
	held map[int][]PortHold // port -> its TCP and UDP holds
}

// hold binds `port` on both protocols in the family asked, or neither, and keeps it.
pub fn (mut p Holder) hold(port int, v6 bool) bool {
	if port in p.held {
		return false
	}
	mut t := hold_tcp(port, v6) or { return false }
	u := hold_udp(port, v6) or {
		t.close()
		return false
	}
	p.held[port] = [t, u]
	return true
}

// release lets go of `port` on both protocols, if held, so the server can bind it.
pub fn (mut p Holder) release(port int) {
	if mut hs := p.held[port] {
		for mut h in hs {
			h.close()
		}
		p.held.delete(port)
	}
}

// release_all lets go of every port still held.
pub fn (mut p Holder) release_all() {
	for port in p.held.keys() {
		p.release(port)
	}
}

// ports lists the ports held, ascending.
pub fn (p Holder) ports() []int {
	mut out := p.held.keys()
	out.sort()
	return out
}
