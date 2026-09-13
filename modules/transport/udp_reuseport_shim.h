// Thin C helpers for the macOS half of udpbus.v's receive path. Kept in C for the same reason
// socketcan_shim.h is: fiddly sockaddr/setsockopt plumbing is easier to get right in plain C
// than in V's representation of these POSIX structs. V calls only the flat functions below.
#ifndef BLOBLY_UDP_REUSEPORT_SHIM_H
#define BLOBLY_UDP_REUSEPORT_SHIM_H

#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>

// Bind a UDP socket to 0.0.0.0:port with BOTH SO_REUSEADDR and SO_REUSEPORT set before bind, so
// several sockets -- in this process, or in several processes, exactly the vcan0-multi-opener
// shape udpbus.v exists to replace -- can all bind the identical multicast port. SO_REUSEADDR
// alone is what Linux (and, unchanged, Windows) gets away with for this; BSD/macOS refuses an
// exact duplicate bind without SO_REUSEPORT too. Returns fd >= 0, or -errno on failure.
static inline int ct_udp_listen_reuseport(int port) {
	int s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0) return -errno;
	int on = 1;
	if (setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) < 0) { int e = errno; close(s); return -e; }
	if (setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on)) < 0) { int e = errno; close(s); return -e; }
	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = htonl(INADDR_ANY);
	addr.sin_port = htons((unsigned short)port);
	if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) { int e = errno; close(s); return -e; }
	return s;
}

// Joins an IPv4 multicast group (dotted-quad, e.g. "239.63.42.1") on `iface_dotted` -- an empty
// string means the default interface (INADDR_ANY, kernel's choice). udpbus.v passes "127.0.0.1"
// here, matching the loopback interface it pins the SEND side to, so this socket's membership is
// on the interface sends actually leave through rather than whichever one INADDR_ANY resolves to
// on a multi-homed machine. Returns 0, or -errno on failure.
static inline int ct_udp_join_multicast(int fd, const char *group_dotted, const char *iface_dotted) {
	struct ip_mreq mreq;
	memset(&mreq, 0, sizeof(mreq));
	if (inet_pton(AF_INET, group_dotted, &mreq.imr_multiaddr) != 1) return -EINVAL;
	if (iface_dotted != NULL && iface_dotted[0] != '\0') {
		if (inet_pton(AF_INET, iface_dotted, &mreq.imr_interface) != 1) return -EINVAL;
	} else {
		mreq.imr_interface.s_addr = htonl(INADDR_ANY);
	}
	if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) < 0) return -errno;
	return 0;
}

// Sets SO_RCVTIMEO. Called every recv() iteration (mirroring net.UdpConn.set_read_timeout, which
// the non-macOS path calls the same way) rather than once at open, since udpbus.v recomputes the
// remaining time on every pass of its retry loop.
static inline int ct_udp_set_recv_timeout_ms(int fd, int ms) {
	if (ms < 0) ms = 0;
	struct timeval tv;
	tv.tv_sec = ms / 1000;
	tv.tv_usec = (ms % 1000) * 1000;
	if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) return -errno;
	return 0;
}

// Reads one datagram. Returns the byte count (>= 0), or -errno on failure -- -EAGAIN/-EWOULDBLOCK
// is an ordinary SO_RCVTIMEO expiry, which the V side (udpbus_macos.v) reads as a timeout, same
// as net.UdpConn's read() does on the non-macOS path.
static inline int ct_udp_recv(int fd, void *buf, int len) {
	int n = (int)recv(fd, buf, (size_t)len, 0);
	if (n < 0) return -errno;
	return n;
}

static inline void ct_udp_close(int fd) {
	if (fd >= 0) close(fd);
}

#endif
