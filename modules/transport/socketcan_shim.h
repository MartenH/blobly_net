// Thin C helpers over Linux SocketCAN (raw CAN). Keeping the fiddly bits
// (sockaddr_can, SIOCGIFINDEX ioctl, struct can_frame) in C avoids fighting V's
// representation of these kernel structs. V calls only these flat functions.
#ifndef BLOBLY_SOCKETCAN_SHIM_H
#define BLOBLY_SOCKETCAN_SHIM_H

#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/can.h>
#include <linux/can/raw.h>

// Open a raw CAN socket bound to `ifname` (e.g. "vcan0"). Returns fd >= 0, or
// -errno on failure.
static inline int ct_can_open(const char *ifname) {
	int s = socket(PF_CAN, SOCK_RAW, CAN_RAW);
	if (s < 0) return -errno;
	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	if (ioctl(s, SIOCGIFINDEX, &ifr) < 0) { int e = errno; close(s); return -e; }
	struct sockaddr_can addr;
	memset(&addr, 0, sizeof(addr));
	addr.can_family = AF_CAN;
	addr.can_ifindex = ifr.ifr_ifindex;
	if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) { int e = errno; close(s); return -e; }
	return s;
}

// Send one classic CAN frame. `can_id` already carries EFF/RTR flags. Returns 0
// on success, -errno on failure.
static inline int ct_can_send(int fd, uint32_t can_id, const uint8_t *data, uint8_t len) {
	struct can_frame f;
	memset(&f, 0, sizeof(f));
	f.can_id = can_id;
	if (len > 8) len = 8;
	f.can_dlc = len;
	if (len > 0) memcpy(f.data, data, len);
	ssize_t n = write(fd, &f, sizeof(f));
	if (n != (ssize_t)sizeof(f)) return -errno;
	return 0;
}

// Receive one classic CAN frame. timeout_ms < 0 blocks; >= 0 waits up to that
// long. Returns dlc (0..8) and fills *can_id + 8 data bytes; -1 on timeout;
// -2 on error.
/* Returns the DLC, -1 on timeout, or -(1000+errno) on a real error — EINTR (a signal landing
 * mid-syscall, routine in a GUI process) is RETRIED, not surfaced: it used to abort a whole
 * ISO-TP transfer as an opaque "recv failed". */
static inline int ct_can_recv(int fd, uint32_t *can_id, uint8_t *data, int timeout_ms) {
	if (timeout_ms >= 0) {
		for (;;) {
			struct pollfd p;
			p.fd = fd;
			p.events = POLLIN;
			int r = poll(&p, 1, timeout_ms);
			if (r == 0) return -1;
			if (r > 0) break;
			if (errno != EINTR) return -(1000 + errno);
			/* EINTR: retry. (The remaining budget shrinks by the interrupted wait — the caller's
			 * deadline loop already re-computes its budget per call, so this stays bounded.) */
		}
	}
	for (;;) {
		struct can_frame f;
		ssize_t n = read(fd, &f, sizeof(f));
		if (n == (ssize_t)sizeof(f)) {
			*can_id = f.can_id;
			memcpy(data, f.data, 8);
			return f.can_dlc;
		}
		if (n < 0 && errno == EINTR) continue;
		return n < 0 ? -(1000 + errno) : -(1000 + EIO);
	}
}

static inline void ct_can_close(int fd) { if (fd >= 0) close(fd); }

// CAN id flag/mask accessors (so V doesn't need the kernel #defines).
static inline uint32_t ct_eff_flag(void) { return CAN_EFF_FLAG; }
static inline uint32_t ct_rtr_flag(void) { return CAN_RTR_FLAG; }
static inline uint32_t ct_sff_mask(void) { return CAN_SFF_MASK; }
static inline uint32_t ct_eff_mask(void) { return CAN_EFF_MASK; }

#endif // BLOBLY_SOCKETCAN_SHIM_H
