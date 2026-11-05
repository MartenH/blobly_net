module transport

import net
import time

#flag windows -lws2_32

$if windows {
	#include <winsock2.h>
	#include <ws2tcpip.h>
	#include <mstcpip.h>
} $else {
	#include <sys/socket.h>
	#include <netinet/in.h>
	#include <netinet/tcp.h>
}

struct C.tcp_keepalive {
	onoff             u32
	keepalivetime     u32
	keepaliveinterval u32
}

fn C.WSAIoctl(s usize, code u32, in_buf voidptr, in_len u32, out_buf voidptr, out_len u32, returned &u32, overlapped voidptr, routine voidptr) i32

// A bridge's peer that vanishes without closing (its host asleep, its cable pulled) leaves a
// connection nothing writes to, and a read on it would wait for ever. TCP keepalive probes it:
// after `bridge_keepalive_idle_s` of silence, one probe every `bridge_keepalive_interval_s`,
// and the connection fails after `bridge_keepalive_probes` unanswered — about 11 s, after
// which the read loop's error ends the session as a close does. Windows fixes the count at 10,
// so about 25 s there.
const bridge_keepalive_idle_s = 5
const bridge_keepalive_interval_s = 2
const bridge_keepalive_probes = 3

// bridge_keepalive turns keepalive on for a bridge connection, at the timers above. A failure
// leaves the connection as it was, without keepalive.
fn bridge_keepalive(mut c net.TcpConn) {
	fd := c.sock.handle
	$if windows {
		ka := C.tcp_keepalive{
			onoff:             1
			keepalivetime:     u32(bridge_keepalive_idle_s * 1000)
			keepaliveinterval: u32(bridge_keepalive_interval_s * 1000)
		}
		mut got := u32(0)
		C.WSAIoctl(usize(fd), u32(C.SIO_KEEPALIVE_VALS), &ka, sizeof(ka), unsafe { nil }, 0,
			&got, unsafe { nil }, unsafe { nil })
	} $else {
		one := i32(1)
		idle := i32(bridge_keepalive_idle_s)
		interval := i32(bridge_keepalive_interval_s)
		probes := i32(bridge_keepalive_probes)
		if C.setsockopt(i32(fd), i32(C.SOL_SOCKET), i32(C.SO_KEEPALIVE), &one, sizeof(one)) != 0 {
			return
		}
		$if macos {
			C.setsockopt(i32(fd), i32(C.IPPROTO_TCP), i32(C.TCP_KEEPALIVE), &idle, sizeof(idle))
		} $else {
			C.setsockopt(i32(fd), i32(C.IPPROTO_TCP), i32(C.TCP_KEEPIDLE), &idle, sizeof(idle))
		}
		C.setsockopt(i32(fd), i32(C.IPPROTO_TCP), i32(C.TCP_KEEPINTVL), &interval, sizeof(interval))
		C.setsockopt(i32(fd), i32(C.IPPROTO_TCP), i32(C.TCP_KEEPCNT), &probes, sizeof(probes))
	}
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
