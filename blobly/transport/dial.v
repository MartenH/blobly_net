module transport

import net
import os
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

// dial_tcp_within connects to `dest` (`host:port`) and gives up at `deadline`, or within
// dial_stop_poll_ms of `stop` answering true (nil: never asked). The connect is non-blocking and
// waited for with poll / WSAPoll, so nothing is left running when it gives up; the connection it
// returns is an ordinary blocking one. `dest` is what net.dial_tcp takes — an IPv4 or bracketed
// IPv6 literal, or a name — and a wildcard dials the local host on Windows too, as there. A name
// is resolved by the OS on a thread of its own (resolve_within), so the deadline and the stop
// bound the lookup as well; a literal is resolved in place. The deadline is read once, and the
// time left on it is then measured on the monotonic clock, so a wall-clock step does not move it.
// Each address resolved is tried in turn, given an even share of the time still left, so one
// that drops the attempt does not spend the next one's; the last one's error is returned.
pub fn dial_tcp_within(dest string, deadline time.Time, stop fn () bool) !&net.TcpConn {
	started := time.sys_mono_now()
	budget := deadline - time.now()
	end := started + u64(if budget > 0 { i64(budget) } else { 0 })
	addr := dial_target(dest)
	addrs := resolve_within(addr, started, end, stop)!
	mut last := IError(error('no address for ${addr}'))
	for i, a in addrs {
		now := time.sys_mono_now()
		left := if end > now { end - now } else { u64(0) }
		c := dial_one(a, addr, started, now + left / u64(addrs.len - i), stop) or {
			if err is DialStopped {
				return err
			}
			last = err
			continue
		}
		return c
	}
	return last
}

// Resolved is a name lookup's outcome, carried back from the thread that made it.
struct Resolved {
	addrs []net.Addr
	err   string
}

// resolve_within resolves `addr` for a TCP connect, a literal in place and a name on its own
// thread waited for until `end` (monotonic ns) or a stop: getaddrinfo has no deadline and asks
// no stop, and a lookup that is given up on finishes on its thread and is dropped.
fn resolve_within(addr string, started u64, end u64, stop fn () bool) ![]net.Addr {
	if is_literal_host(addr) {
		return net.resolve_addrs_fuzzy(addr, .tcp) or {
			return error('${err.msg()}; could not resolve ${addr}')
		}
	}
	done := chan Resolved{cap: 1}
	spawn fn [addr, done] () {
		addrs := net.resolve_addrs_fuzzy(addr, .tcp) or {
			done <- Resolved{
				err: '${err.msg()}; could not resolve ${addr}'
			}
			return
		}
		done <- Resolved{
			addrs: addrs
		}
	}()
	for {
		if stop_asked(stop) {
			return DialStopped{
				addr: addr
			}
		}
		now := time.sys_mono_now()
		if now >= end {
			return DialTimedOut{
				addr: addr
				ms:   i64(now - started) / 1_000_000
			}
		}
		left := time.Duration(i64(end - now))
		slice := if left < dial_stop_poll_ms * time.millisecond {
			left
		} else {
			dial_stop_poll_ms * time.millisecond
		}
		select {
			r := <-done {
				if r.err != '' {
					return error(r.err)
				}
				return r.addrs
			}
			slice {}
		}
	}
	return error('unreachable')
}

// is_literal_host is whether the host of `addr` (`host:port`) is an address rather than a name:
// a bracketed IPv6 literal, a dotted IPv4 one, or none at all.
fn is_literal_host(addr string) bool {
	if addr.starts_with('[') {
		return true
	}
	host := if addr.contains(':') { addr.all_before_last(':') } else { addr }
	if host.contains(':') {
		return true // an unbracketed IPv6 literal
	}
	for c in host {
		if !(c.is_digit() || c == `.`) {
			return false
		}
	}
	return true
}

// dial_target is the address a dial resolves: net.dial_tcp's, which on Windows reads a wildcard
// host as the local one, since connecting to it works on Linux and macOS but not there.
fn dial_target(addr string) string {
	$if windows {
		if addr.starts_with(':::') {
			return addr.replace_once(':::', 'localhost:')
		}
		if addr.starts_with('0.0.0.0:') {
			return addr.replace_once('0.0.0.0:', 'localhost:')
		}
	}
	return addr
}

// dial_one is one non-blocking connect to one resolved address.
fn dial_one(a net.Addr, name string, started u64, end u64, stop fn () bool) !&net.TcpConn {
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
			return connect_failed(name, code)
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
			now := time.sys_mono_now()
			left := if end > now { i64(end - now) } else { i64(0) }
			mut ms := int((left + 999_999) / 1_000_000)
			if ms > dial_stop_poll_ms {
				ms = dial_stop_poll_ms
			}
			if writable_within(handle, ms) {
				break
			}
			after := time.sys_mono_now()
			if after >= end {
				dial_close(handle)
				return DialTimedOut{
					addr: name
					ms:   i64(after - started) / 1_000_000
				}
			}
		}
		so_err := i32(0)
		len := u32(sizeof(so_err))
		if C.getsockopt(i32(handle), C.SOL_SOCKET, C.SO_ERROR, &so_err, &len) != 0 {
			code2 := net.error_code()
			dial_close(handle)
			return connect_failed(name, code2)
		}
		if so_err != 0 {
			dial_close(handle)
			return connect_failed(name, int(so_err))
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

// connect_failed is a connect the peer or the OS refused, in the OS's words and code.
fn connect_failed(name string, code int) IError {
	why := os.get_error_msg(code).trim_space()
	if why == '' {
		return error_with_code('connect to ${name} failed (${code})', code)
	}
	return error_with_code('connect to ${name} failed: ${why} (${code})', code)
}

fn dial_close(handle int) {
	net.shutdown(handle)
	net.close(handle) or {}
}
