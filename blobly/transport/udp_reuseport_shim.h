// C helpers for listen_udp_shared on macOS (udpshared_macos.v). Kept in C for the reason
// socketcan_shim.h is: sockaddr and setsockopt plumbing is easier to get right in plain C than in
// V's representation of these POSIX structs. V calls only the flat functions below.
#ifndef BLOBLY_UDP_REUSEPORT_SHIM_H
#define BLOBLY_UDP_REUSEPORT_SHIM_H

#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>

// A UDP socket bound to `addr` (a sockaddr of `len` bytes, as vlib's net.Addr is) with BOTH
// SO_REUSEADDR and SO_REUSEPORT set before the bind. BSD/macOS refuses an exact duplicate bind
// unless every binder sets SO_REUSEPORT; Linux and Windows accept SO_REUSEADDR alone, which is
// all vlib's net sets. An IPv6 socket is dual-stack, as vlib's are. Returns fd >= 0, or -errno.
static inline int ct_udp_bind_reuseport(const void *addr, int len, int v6) {
	int s = socket(v6 ? AF_INET6 : AF_INET, SOCK_DGRAM, 0);
	if (s < 0) return -errno;
	int on = 1;
	int off = 0;
	if (setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) < 0
		|| setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on)) < 0
		|| (v6 && setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof(off)) < 0)
		|| bind(s, (const struct sockaddr *)addr, (socklen_t)len) < 0) {
		int e = errno;
		close(s);
		return -e;
	}
	return s;
}

// Puts socket `fd` in the place of descriptor `target` (dup2) and closes `fd`, so a net.UdpConn
// that owns `target` now reads and writes the socket bound above. Returns 0, or -errno; `fd` is
// closed either way, `target` is left as it was on failure.
static inline int ct_udp_take_place(int fd, int target) {
	int r = dup2(fd, target);
	int e = errno;
	close(fd);
	return r < 0 ? -e : 0;
}

#endif
