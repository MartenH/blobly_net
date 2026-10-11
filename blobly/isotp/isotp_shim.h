// Thin C helpers over Linux kernel ISO-TP (ISO 15765-2) sockets. The kernel does
// all segmentation/reassembly + flow control, so V just reads/writes whole PDUs.
// Keeping sockaddr_can/ioctl in C (as in the raw SocketCAN shim) avoids modelling
// kernel structs in V.
#ifndef BLOBLY_ISOTP_SHIM_H
#define BLOBLY_ISOTP_SHIM_H

#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/can.h>
#include <linux/can/isotp.h>

// Open an ISO-TP socket on `ifname`, talking to the peer via tx_id (our sends)
// and rx_id (our receives). The ids already carry CAN_EFF_FLAG if extended.
// Returns fd >= 0, or -errno on failure.
static inline int ct_isotp_open(const char *ifname, uint32_t rx_id, uint32_t tx_id) {
	int s = socket(PF_CAN, SOCK_DGRAM, CAN_ISOTP);
	if (s < 0) return -errno;
	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	if (ioctl(s, SIOCGIFINDEX, &ifr) < 0) { int e = errno; close(s); return -e; }
	struct sockaddr_can addr;
	memset(&addr, 0, sizeof(addr));
	addr.can_family = AF_CAN;
	addr.can_ifindex = ifr.ifr_ifindex;
	addr.can_addr.tp.rx_id = rx_id;
	addr.can_addr.tp.tx_id = tx_id;
	if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) { int e = errno; close(s); return -e; }
	return s;
}

// Send one ISO-TP PDU (the kernel splits it into SF/FF+CF frames). Returns the
// number of bytes accepted, or -errno.
static inline int ct_isotp_send(int fd, const uint8_t *data, int len) {
	ssize_t n = write(fd, data, len);
	if (n < 0) return -errno;
	return (int)n;
}

// Receive one reassembled ISO-TP PDU into buf (up to cap bytes). timeout_ms < 0
// blocks; >= 0 waits at most that long. Returns byte count (>=0), -1 on timeout,
// -2 on error.
static inline int ct_isotp_recv(int fd, uint8_t *buf, int cap, int timeout_ms) {
	if (timeout_ms >= 0) {
		struct pollfd p;
		p.fd = fd;
		p.events = POLLIN;
		int r = poll(&p, 1, timeout_ms);
		if (r == 0) return -1;
		if (r < 0) return -2;
	}
	ssize_t n = read(fd, buf, cap);
	if (n < 0) return -2;
	return (int)n;
}

static inline void ct_isotp_close(int fd) { if (fd >= 0) close(fd); }

#endif // BLOBLY_ISOTP_SHIM_H
