module transport

import net
import time

// dial_stop_poll_ms is how often a bounded dial asks its stop: the bound on how long it outlives
// one.
pub const dial_stop_poll_ms = 20

// DialTimedOut is a TCP connect that did not complete by its deadline: nothing answered — an
// address that blackholes connections, or a listener that never accepts.
pub struct DialTimedOut {
	Error
pub:
	addr string
	ms   i64
}

pub fn (e DialTimedOut) msg() string {
	return 'connect to ${e.addr} timed out after ${e.ms} ms'
}

// DialStopped is a TCP connect abandoned because its stop was asked.
pub struct DialStopped {
	Error
pub:
	addr string
}

pub fn (e DialStopped) msg() string {
	return 'connect to ${e.addr} abandoned: stop requested'
}

// dial_tcp_within connects to `addr` (`host:port`) and gives up at `deadline`, or within
// dial_stop_poll_ms of `stop` answering true (nil: never asked). The connect is non-blocking and
// waited for with poll / WSAPoll, so nothing is left running when it gives up; the connection it
// returns is an ordinary blocking one. A name in `addr` is resolved by the OS first, which this
// does not bound — callers here pass an address. Each address the name resolves to is tried in
// turn within the one deadline, the last one's error returned.
pub fn dial_tcp_within(addr string, deadline time.Time, stop fn () bool) !&net.TcpConn {
	started := time.now()
	addrs := net.resolve_addrs_fuzzy(addr, .tcp) or {
		return error('${err.msg()}; could not resolve ${addr}')
	}
	mut last := IError(error('no address for ${addr}'))
	for a in addrs {
		c := dial_one(a, addr, started, deadline, stop) or {
			if err is DialTimedOut || err is DialStopped {
				return err
			}
			last = err
			continue
		}
		return c
	}
	return last
}

// dial_one is one non-blocking connect to one resolved address.
fn dial_one(a net.Addr, name string, started time.Time, deadline time.Time, stop fn () bool) !&net.TcpConn {
	s := net.new_tcp_socket(a.family())!
	handle := s.handle
	net.set_blocking(handle, false) or {
		dial_close(handle)
		return err
	}
	res := C.connect(i32(handle), voidptr(&a), a.len())
	if res != 0 {
		code := net.error_code()
		in_progress := $if windows {
			code == int(net.error_ewouldblock)
		} $else {
			code in [int(net.error_einprogress), int(net.error_eagain), C.EINTR]
		}
		if !in_progress {
			dial_close(handle)
			return error_with_code('connect to ${name} failed (${code})', code)
		}
		// Wait for the socket to become writable: the connect completed, or failed. Polled once
		// before the deadline is judged, so a connect that has already completed is not reported
		// as timed out.
		for {
			if stop_asked(stop) {
				dial_close(handle)
				return DialStopped{
					addr: name
				}
			}
			left := deadline - time.now()
			mut ms := if left <= 0 { 0 } else { int((left + time.millisecond - 1) / time.millisecond) }
			if ms > dial_stop_poll_ms {
				ms = dial_stop_poll_ms
			}
			if writable_within(handle, ms) {
				break
			}
			if deadline - time.now() <= 0 {
				dial_close(handle)
				return DialTimedOut{
					addr: name
					ms:   (time.now() - started).milliseconds()
				}
			}
		}
		so_err := i32(0)
		len := u32(sizeof(so_err))
		if C.getsockopt(i32(handle), C.SOL_SOCKET, C.SO_ERROR, &so_err, &len) != 0 {
			code2 := net.error_code()
			dial_close(handle)
			return error_with_code('connect to ${name} failed (${code2})', code2)
		}
		if so_err != 0 {
			dial_close(handle)
			return error_with_code('connect to ${name} failed (${so_err})', int(so_err))
		}
	}
	net.set_blocking(handle, true) or {
		dial_close(handle)
		return err
	}
	mut conn := &net.TcpConn{
		sock:          s
		read_timeout:  net.tcp_default_read_timeout
		write_timeout: net.tcp_default_write_timeout
	}
	conn.set_read_timeout(net.tcp_default_read_timeout)
	return conn
}

// stop_asked is whether a stop has been asked: nil means never asked.
pub fn stop_asked(stop fn () bool) bool {
	return stop != unsafe { nil } && stop()
}

fn dial_close(handle int) {
	net.shutdown(handle)
	net.close(handle) or {}
}
