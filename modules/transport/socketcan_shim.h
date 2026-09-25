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
#include <time.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <linux/can.h>
#include <linux/can/raw.h>
#include <linux/can/error.h>

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
	/* Subscribe to the kernel's error frames (bus-off, error-passive, controller warnings):
	 * without CAN_RAW_ERR_FILTER the kernel never delivers them, so bus health was
	 * UNOBSERVABLE from this socket — a bench at bus-off looked like a healthy silent bus.
	 * Also not fatal on refusal: health degrades to unknown, traffic still flows. The V
	 * side recognizes these frames by CAN_ERR_FLAG in the id and never shows them as data. */
	/* only the classes the decoder consumes: the full CAN_ERR_MASK delivered every class to
	 * EVERY socket (taps included), and with berr-reporting on that is one frame per bus
	 * error — tens of thousands a second flooding queues nothing drains (self-review) */
	/* CRTL/BUSOFF/RESTARTED feed the health ladder; PROT and ACK are the controller errors
	 * diagnostics() counts (#213) -- unsubscribed, the kernel never delivers them. */
	can_err_mask_t errs = CAN_ERR_CRTL | CAN_ERR_BUSOFF | CAN_ERR_RESTARTED | CAN_ERR_PROT | CAN_ERR_ACK;
	setsockopt(s, SOL_CAN_RAW, CAN_RAW_ERR_FILTER, &errs, sizeof(errs));
	/* The kernel's software receive stamp on every frame (#149): taken at device receive, so it is
	 * free of this reader's own scheduling delay — though not of a USB adapter's batching, which
	 * only the adapter's hardware stamp (SOF_TIMESTAMPING_RAW_HARDWARE, not requested) would be.
	 * One limit: the kernel turns stamping on asynchronously, so frames right after the FIRST
	 * timestamping socket on a host opens may be stamped at read time instead — today's accuracy,
	 * for a moment. Not fatal on refusal — a frame without a stamp says so. */
	setsockopt(s, SOL_SOCKET, SO_TIMESTAMPNS, &on, sizeof(on));
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
/* The wall clock's offset from the monotonic one, sampled so a preemption cannot hide in it (#149).
 * Two adjacent clock_gettime calls are not atomic: a reader descheduled between them folds the whole
 * suspension into the offset, and every stamp converted with it comes out late by exactly the
 * scheduling delay the stamp exists to remove (codex round 2 on #352). So the wall-clock read is
 * BRACKETED between two monotonic ones and a wide bracket is retried. Its instant is taken as the
 * bracket's OPENING read, not the midpoint: then a converted stamp is never EARLY, only late by at most
 * the bracket (~2 us when tight). The midpoint halves the worst case but splits it both ways, and an
 * early stamp can precede its own send — the live test's lower bound, under the wide brackets of a
 * loaded machine. `*after` is the closing read: an honest stamp converts to at most the bracket past
 * its true instant, which is before the opening read, so strictly before the closing one — what the
 * impossible-stamp check below compares against. */
static inline int64_t ct_rt_minus_mono(int64_t *after) {
	int64_t best = 0, best_w = INT64_MAX;
	for (int i = 0; i < 4; i++) {
		struct timespec m1, r, m2;
		clock_gettime(CLOCK_MONOTONIC, &m1);
		clock_gettime(CLOCK_REALTIME, &r);
		clock_gettime(CLOCK_MONOTONIC, &m2);
		int64_t a = (int64_t)m1.tv_sec * 1000000000LL + m1.tv_nsec;
		int64_t b = (int64_t)m2.tv_sec * 1000000000LL + m2.tv_nsec;
		int64_t w = b - a;
		if (w < best_w) {
			best_w = w;
			best = ((int64_t)r.tv_sec * 1000000000LL + r.tv_nsec) - a;
			*after = b;
		}
		if (w < 2000) break; /* 2 us: tight enough — a stamp is late by at most that */
	}
	return best;
}

static inline int ct_can_recv(int fd, uint32_t *can_id, uint8_t *data, int timeout_ms,
                              uint8_t *frame_flags, int64_t *stamp_ns) {
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
		/* recvmsg rather than read, for the SO_TIMESTAMPNS stamp that rides as ancillary data. A
		 * union, not a bare char array, so the buffer is aligned for struct cmsghdr — a misaligned
		 * read faults on strict-alignment targets such as ARMv7 CAN HATs. */
		union {
			char buf[CMSG_SPACE(sizeof(struct timespec))];
			struct cmsghdr align;
		} ctrl;
		struct iovec iov = { .iov_base = &f, .iov_len = sizeof(f) };
		struct msghdr msg;
		memset(&msg, 0, sizeof(msg));
		msg.msg_iov = &iov;
		msg.msg_iovlen = 1;
		msg.msg_control = ctrl.buf;
		msg.msg_controllen = sizeof(ctrl.buf);
		ssize_t n = recvmsg(fd, &msg, 0);
		*stamp_ns = 0;
		/* Only on success: a failed recvmsg leaves msg_controllen as we set it, and walking the
		 * buffer then reads uninitialised stack — and EINTR is routine here. */
		for (struct cmsghdr *c = n >= 0 ? CMSG_FIRSTHDR(&msg) : NULL; c != NULL; c = CMSG_NXTHDR(&msg, c)) {
			if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_TIMESTAMPNS) {
				struct timespec ts;
				memcpy(&ts, CMSG_DATA(c), sizeof(ts));
				/* ON THE MONOTONIC CLOCK, converted here. The kernel stamps with CLOCK_REALTIME,
				 * which steps — NTP, or WSL resyncing after the host sleeps — and a stepped domain
				 * breaks every delta taken across the step. Converted at read, only a frame in flight
				 * at the step's very instant is affected; and the stamp then sits on the same clock
				 * as the host receipt time beside it (V's sys_mono_now is CLOCK_MONOTONIC). */
				int64_t mono_ns = 0;
				int64_t off = ct_rt_minus_mono(&mono_ns);
				*stamp_ns = ((int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec) - off;
				/* A STAMP AFTER ITS OWN READ IS IMPOSSIBLE, and is what a wall clock stepped BACK
				 * between stamp and read produces (WSL resyncing after the host sleeps). Dropped: as a
				 * negative gap it would become the domain's minimum and shift every frame by the step
				 * for a whole timebase window. Exact — an honest stamp converts to strictly before the
				 * bracket's closing read (see ct_rt_minus_mono). A step FORWARD makes one stamp too
				 * early instead; its gap is large, so it never moves the estimate. */
				if (*stamp_ns > mono_ns) *stamp_ns = 0;
			}
		}
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
