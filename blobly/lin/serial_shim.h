// Thin C helpers over a Linux serial port for LIN: raw 8N1 at any rate (termios2 / BOTHER), the
// break, polled reads and writes, the port's error counters, and the pseudo-terminal pairs a
// pty link is made of. V calls only these flat functions.
#ifndef BLOBLY_LIN_SERIAL_SHIM_H
#define BLOBLY_LIN_SERIAL_SHIM_H

#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <time.h>
#include <termios.h>
#include <sys/ioctl.h>

// The kernel's struct termios2 (asm-generic layout, x86 and arm), declared under our own name so
// it cannot clash with glibc's struct termios; BOTHER asks for the rate in c_ispeed / c_ospeed.
struct bl_termios2 {
	unsigned int c_iflag, c_oflag, c_cflag, c_lflag;
	unsigned char c_line;
	unsigned char c_cc[19];
	unsigned int c_ispeed, c_ospeed;
};
#define BL_TCGETS2 _IOR('T', 0x2A, struct bl_termios2)
#define BL_TCSETS2 _IOW('T', 0x2B, struct bl_termios2)
#define BL_CBAUD 0010017
#define BL_CIBAUD 002003600000
#define BL_BOTHER 0010000

// The kernel's struct serial_icounter_struct, for TIOCGICOUNT.
struct bl_icount {
	int cts, dsr, rng, dcd, rx, tx, frame, overrun, parity, brk, buf_overrun;
	int reserved[9];
};

// bl_ser_raw puts a port in raw 8N1 at `baud` and writes the rate the driver took into *got (a
// driver that cannot produce a rate picks another and says so in the termios it hands back).
// With `parmrk`, breaks and framing errors are marked in-band (PARMRK, INPCK; a break is
// FF 00 00, a data FF is FF FF); without, input is passed through untouched. Returns 0 or -errno.
static inline int bl_ser_raw(int fd, int baud, int parmrk, unsigned int *got) {
	struct bl_termios2 t;
	if (ioctl(fd, BL_TCGETS2, &t) < 0) return -errno;
	t.c_iflag &= ~(IGNBRK | BRKINT | IGNPAR | PARMRK | INPCK | ISTRIP | INLCR | IGNCR | ICRNL |
		IXON | IXOFF | IXANY | IMAXBEL);
	if (parmrk) t.c_iflag |= PARMRK | INPCK;
	t.c_oflag &= ~OPOST;
	t.c_lflag &= ~(ECHO | ECHONL | ECHOE | ECHOK | ICANON | ISIG | IEXTEN);
	t.c_cflag &= ~(CSIZE | PARENB | CSTOPB | CRTSCTS | BL_CBAUD | BL_CIBAUD);
	t.c_cflag |= CS8 | CREAD | CLOCAL | BL_BOTHER;
	t.c_ispeed = (unsigned int)baud;
	t.c_ospeed = (unsigned int)baud;
	t.c_cc[VMIN] = 1;
	t.c_cc[VTIME] = 0;
	if (ioctl(fd, BL_TCSETS2, &t) < 0) return -errno;
	if (ioctl(fd, BL_TCGETS2, &t) < 0) return -errno;
	*got = t.c_ospeed;
	return 0;
}

// bl_ser_open opens a port non-blocking and puts it in raw mode; *got is the rate it took.
// Returns the fd or -errno.
static inline int bl_ser_open(const char *path, int baud, int parmrk, unsigned int *got) {
	int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) return -errno;
	int r = bl_ser_raw(fd, baud, parmrk, got);
	if (r < 0) { close(fd); return r; }
	tcflush(fd, TCIOFLUSH);
	return fd;
}

// bl_ser_wait waits up to timeout_ms for the port to have something to read, or an error or a
// hangup for the read to report. Returns 1, 0 when nothing came, or -errno.
static inline int bl_ser_wait(int fd, int timeout_ms) {
	struct pollfd p = { fd, POLLIN, 0 };
	int r = poll(&p, 1, timeout_ms);
	if (r < 0) return errno == EINTR ? 0 : -errno;
	if (r == 0) return 0;
	if (p.revents & POLLNVAL) return -EBADF;
	return 1;
}

// bl_ser_read waits up to timeout_ms for input and reads what is there. Returns the byte count,
// 0 when nothing came, or -errno (a hangup is -EIO).
static inline int bl_ser_read(int fd, uint8_t *buf, int cap, int timeout_ms) {
	struct pollfd p = { fd, POLLIN, 0 };
	int r = poll(&p, 1, timeout_ms);
	if (r < 0) return errno == EINTR ? 0 : -errno;
	if (r == 0) return 0;
	if (p.revents & POLLNVAL) return -EBADF;
	ssize_t n = read(fd, buf, (size_t)cap);
	if (n < 0) return (errno == EAGAIN || errno == EINTR) ? 0 : -errno;
	if (n == 0) return -EIO;
	return (int)n;
}

// bl_ser_write writes every byte, waiting at most timeout_ms for room at a time. Returns 0 or
// -errno (-ETIMEDOUT when the port took nothing in that time).
static inline int bl_ser_write(int fd, const uint8_t *b, int n, int timeout_ms) {
	int off = 0;
	while (off < n) {
		ssize_t w = write(fd, b + off, (size_t)(n - off));
		if (w > 0) { off += (int)w; continue; }
		if (w < 0 && errno == EINTR) continue;
		if (w < 0 && errno != EAGAIN) return -errno;
		struct pollfd p = { fd, POLLOUT, 0 };
		int r = poll(&p, 1, timeout_ms);
		if (r < 0 && errno != EINTR) return -errno;
		if (r == 0) return -ETIMEDOUT;
	}
	return 0;
}

static inline void bl_sleep_ns(long long ns) {
	struct timespec ts = { (time_t)(ns / 1000000000LL), (long)(ns % 1000000000LL) };
	while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {}
}

// bl_ser_break holds the line dominant for brk_ns, then recessive for delim_ns (the break
// delimiter) before the caller writes on. TIOCSBRK first waits until the output already queued
// has gone out, so the break follows it.
static inline int bl_ser_break(int fd, long long brk_ns, long long delim_ns) {
	// A signal while TIOCSBRK waits for the output to drain returns EINTR before the line is
	// set dominant (tty_ioctl), and SA_RESTART does not restart it: ask again.
	while (ioctl(fd, TIOCSBRK) < 0) {
		if (errno != EINTR) return -errno;
	}
	bl_sleep_ns(brk_ns);
	if (ioctl(fd, TIOCCBRK) < 0) return -errno;
	bl_sleep_ns(delim_ns);
	return 0;
}

static inline void bl_ser_close(int fd) {
	close(fd);
}

// bl_ser_icount reads the port's error counters: framing, parity, overrun (the UART's and the
// tty buffer's). Returns 0, or -errno where the port keeps none (a pty).
static inline int bl_ser_icount(int fd, uint64_t *frame, uint64_t *parity, uint64_t *overrun) {
#ifdef TIOCGICOUNT
	struct bl_icount c;
	memset(&c, 0, sizeof c);
	if (ioctl(fd, TIOCGICOUNT, &c) < 0) return -errno;
	*frame = (uint64_t)(unsigned)c.frame;
	*parity = (uint64_t)(unsigned)c.parity;
	*overrun = (uint64_t)(unsigned)c.overrun + (uint64_t)(unsigned)c.buf_overrun;
	return 0;
#else
	return -ENOTTY;
#endif
}

// bl_pty_new opens a new pseudo-terminal pair's master end, unlocked, and writes its slave
// end's path into `name`. Returns the master fd or -errno.
static inline int bl_pty_new(char *name, int cap) {
	int m = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
	if (m < 0) return -errno;
	int unlock = 0, n = 0;
	if (ioctl(m, TIOCSPTLCK, &unlock) < 0 || ioctl(m, TIOCGPTN, &n) < 0) {
		int e = errno;
		close(m);
		return -e;
	}
	snprintf(name, (size_t)cap, "/dev/pts/%d", n);
	return m;
}

// bl_pty_relay copies what either master end has to read into the other, waiting up to
// timeout_ms. Bytes the other end has no room for are dropped and counted. Returns 0 or -errno.
static inline int bl_pty_relay(int a, int b, int timeout_ms, uint64_t *dropped) {
	struct pollfd p[2] = { { a, POLLIN, 0 }, { b, POLLIN, 0 } };
	int r = poll(p, 2, timeout_ms);
	if (r < 0) return errno == EINTR ? 0 : -errno;
	uint8_t buf[4096];
	for (int i = 0; i < 2 && r > 0; i++) {
		if (p[i].revents & (POLLERR | POLLNVAL)) return -EIO;
		if (!(p[i].revents & POLLIN)) continue;
		ssize_t n = read(p[i].fd, buf, sizeof buf);
		if (n <= 0) continue;
		int to = i == 0 ? b : a;
		ssize_t off = 0;
		while (off < n) {
			ssize_t w = write(to, buf + off, (size_t)(n - off));
			if (w < 0 && errno == EINTR) continue;
			if (w <= 0) { *dropped += (uint64_t)(n - off); break; }
			off += w;
		}
	}
	return 0;
}

#endif
