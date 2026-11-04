module transport

import net
import time

#flag windows -lws2_32

$if windows {
	#include <winsock2.h>
	#include <ws2tcpip.h>
} $else {
	#include <sys/socket.h>
	#include <netinet/in.h>
}

// bridge_bind listens on host:port. Not through net.listen_tcp, which sets SO_REUSEADDR: on
// Windows that lets a second process bind a port another is listening on and take its
// connections, and a port BLOBLY_BRIDGE_LISTEN fixes is the same in every process started with
// the setting. Here the second one is refused (SO_EXCLUSIVEADDRUSE). Elsewhere SO_REUSEADDR
// already refuses a port another socket listens on; it only lets a restarted app bind past its
// own connections in TIME_WAIT. `[::]` takes every address of both families, as net.listen_tcp's
// does.
fn bridge_bind(host string, port int) !&net.TcpListener {
	at := bridge_host_port(host, port)
	family := if host.contains(':') { net.AddrFamily.ip6 } else { net.AddrFamily.ip }
	addrs := net.resolve_addrs(at, family, .tcp)!
	if addrs.len == 0 {
		return error('cannot listen on ${at}: no such address')
	}
	addr := addrs[0]
	fd := int(C.socket(i32(addr.family()), i32(C.SOCK_STREAM), 0))
	if fd < 0 {
		return error('cannot listen on ${at}: socket failed (${net.error_code()})')
	}
	one := i32(1)
	zero := i32(0)
	mut ok := false
	$if windows {
		ok = C.setsockopt(i32(fd), i32(C.SOL_SOCKET), i32(C.SO_EXCLUSIVEADDRUSE), &one, sizeof(one)) == 0
	} $else {
		ok = C.setsockopt(i32(fd), i32(C.SOL_SOCKET), i32(C.SO_REUSEADDR), &one, sizeof(one)) == 0
	}
	if ok && family == .ip6 {
		ok = C.setsockopt(i32(fd), i32(C.IPPROTO_IPV6), i32(C.IPV6_V6ONLY), &zero, sizeof(zero)) == 0
	}
	if !ok || C.bind(i32(fd), voidptr(&addr), addr.len()) != 0 || C.listen(i32(fd), 128) != 0 {
		code := net.error_code()
		net.close(fd) or {}
		return error('cannot listen on ${at} (socket error ${code})')
	}
	return &net.TcpListener{
		sock:            net.tcp_socket_from_handle_raw(fd)
		accept_deadline: time.unix(0)
		accept_timeout:  net.infinite_timeout
	}
}
