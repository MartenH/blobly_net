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
	/* Ask for CAN-FD frames. NOT fatal when it fails: a classic-only interface refuses the
	 * option, and that socket must keep working for the classic traffic it can carry. What it
	 * costs is that an FD send later fails at write() with EINVAL, which is the honest place
	 * for it — the frame is what cannot be represented, not the socket. */
	int on = 1;
	setsockopt(s, SOL_CAN_RAW, CAN_RAW_FD_FRAMES, &on, sizeof(on));
	return s;
}



/* Send one frame. `can_id` already carries EFF/RTR flags. is_fd selects the CAN-FD layout
 * (struct canfd_frame, up to 64 bytes); brs additionally switches the data-phase bitrate.
 * The KERNEL distinguishes the two by write size, so an FD-enabled socket still sends classic
 * frames byte-for-byte as before. Returns 0 on success, -errno on failure. */
static inline int ct_can_send(int fd, uint32_t can_id, const uint8_t *data, uint8_t len,
                              int is_fd, int brs, int esi) {
	if (!is_fd) {
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
	struct canfd_frame f;
	memset(&f, 0, sizeof(f));
	f.can_id = can_id;
	if (len > 64) len = 64;
	/* The caller (transport.fd_pad) has already rounded this to an encodable length; the kernel
	 * rejects anything else, so a wrong length surfaces as EINVAL rather than being papered over
	 * by a second copy of the table here. */
	f.len = len;
	f.flags = (brs ? CANFD_BRS : 0) | (esi ? CANFD_ESI : 0);
	if (len > 0) memcpy(f.data, data, len);
	ssize_t n = write(fd, &f, sizeof(f));
	if (n != (ssize_t)sizeof(f)) return -errno;
	return 0;
}

// Receive one frame, classic or CAN-FD. timeout_ms < 0 blocks; >= 0 waits up to that long.
// Returns the payload LENGTH (0..8 classic, up to 64 for FD) and fills *can_id, up to 64 data
// bytes — the caller's buffer must be 64 bytes — and *frame_flags (bit0 = FD, bit1 = BRS,
// bit2 = ESI).
// -1 on timeout.
/* Returns the DLC, -1 on timeout, or -(1000+errno) on a real error — EINTR (a signal landing
 * mid-syscall, routine in a GUI process) is RETRIED, not surfaced: it used to abort a whole
 * ISO-TP transfer as an opaque "recv failed". */
static inline int ct_can_recv(int fd, uint32_t *can_id, uint8_t *data, int timeout_ms,
                              uint8_t *frame_flags) {
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
		/* Read into the LARGER layout and let the byte count say which arrived: with
		 * CAN_RAW_FD_FRAMES on, the same socket delivers both, and a classic frame is a short
		 * read rather than an error. */
		struct canfd_frame f;
		ssize_t n = read(fd, &f, sizeof(f));
		if (n == (ssize_t)sizeof(struct can_frame)) {
			struct can_frame *c = (struct can_frame *)&f;
			*can_id = c->can_id;
			*frame_flags = 0;
			memcpy(data, c->data, 8);
			return c->can_dlc;
		}
		if (n == (ssize_t)sizeof(struct canfd_frame)) {
			*can_id = f.can_id;
			*frame_flags = 0x01 | ((f.flags & CANFD_BRS) ? 0x02 : 0)
			                    | ((f.flags & CANFD_ESI) ? 0x04 : 0);
			uint8_t len = f.len > 64 ? 64 : f.len;
			memcpy(data, f.data, len);
			return len;
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
