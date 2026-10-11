module doip

#include <winsock2.h>

@[typedef]
pub struct C.WSAPOLLFD {
mut:
	fd      u64
	events  i16
	revents i16
}

fn C.WSAPoll(fds &C.WSAPOLLFD, nfds u32, timeout int) int

// readable_now: the socket has something to read (or has closed, which a read then reports)
// without waiting at all — what a zero-timeout recv asks before it reads a framed message.
fn readable_now(fd int) bool {
	mut p := C.WSAPOLLFD{
		fd:     u64(fd)
		events: i16(C.POLLRDNORM)
	}
	if C.WSAPoll(&p, 1, 0) <= 0 {
		return false
	}
	return p.revents & i16(C.POLLRDNORM | C.POLLHUP | C.POLLERR) != 0
}

// readable_within: as readable_now, waiting up to `ms` for it.
fn readable_within(fd int, ms int) bool {
	mut p := C.WSAPOLLFD{
		fd:     u64(fd)
		events: i16(C.POLLRDNORM)
	}
	if C.WSAPoll(&p, 1, ms) <= 0 {
		return false
	}
	return p.revents & i16(C.POLLRDNORM | C.POLLHUP | C.POLLERR) != 0
}
