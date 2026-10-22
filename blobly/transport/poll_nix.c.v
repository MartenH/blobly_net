module transport

#include <poll.h>

pub struct C.pollfd {
mut:
	fd      int
	events  i16
	revents i16
}

fn C.poll(fds &C.pollfd, nfds u64, timeout int) int

// readable_now: the socket has something to read (or has closed, or is no socket at all —
// POLLNVAL — which a read then reports)
// without waiting at all — what a zero-timeout recv asks before it reads (the recv(0) contract,
// transport.v). One home for the socket backends here and for doip's framed reads.
pub fn readable_now(fd int) bool {
	mut p := C.pollfd{
		fd:     fd
		events: i16(C.POLLIN)
	}
	if C.poll(&p, 1, 0) <= 0 {
		return false
	}
	return p.revents & i16(C.POLLIN | C.POLLHUP | C.POLLERR | C.POLLNVAL) != 0
}

// writable_within: the socket can take data without its send blocking (or has failed, which the
// send then reports), waiting up to `ms` for it — a bounded write's step on a blocking socket,
// whose own timeout a blocked send does not consult.
pub fn writable_within(fd int, ms int) bool {
	mut p := C.pollfd{
		fd:     fd
		events: i16(C.POLLOUT)
	}
	if C.poll(&p, 1, ms) <= 0 {
		return false
	}
	return p.revents & i16(C.POLLOUT | C.POLLHUP | C.POLLERR | C.POLLNVAL) != 0
}

// readable_within: as readable_now, waiting up to `ms` for it.
pub fn readable_within(fd int, ms int) bool {
	mut p := C.pollfd{
		fd:     fd
		events: i16(C.POLLIN)
	}
	if C.poll(&p, 1, ms) <= 0 {
		return false
	}
	return p.revents & i16(C.POLLIN | C.POLLHUP | C.POLLERR | C.POLLNVAL) != 0
}
