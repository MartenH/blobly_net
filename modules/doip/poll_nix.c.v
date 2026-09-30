module doip

#include <poll.h>

pub struct C.pollfd {
mut:
	fd      int
	events  i16
	revents i16
}

fn C.poll(fds &C.pollfd, nfds u64, timeout int) int

// readable_now: the socket has something to read (or has closed, which a read then reports)
// without waiting at all — what a zero-timeout recv asks before it reads a framed message.
fn readable_now(fd int) bool {
	mut p := C.pollfd{
		fd:     fd
		events: i16(C.POLLIN)
	}
	if C.poll(&p, 1, 0) <= 0 {
		return false
	}
	return p.revents & i16(C.POLLIN | C.POLLHUP | C.POLLERR) != 0
}
