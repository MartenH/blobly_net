module transport

import net
import time

// blackholed_listener is a local listener whose accept queue is full, so a further connect to it
// is never answered (Linux drops the SYN), and the connections that filled it. none where the
// platform answers such a connect some other way.
fn blackholed_listener() ?(&net.TcpListener, string, []&net.TcpConn) {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0', backlog: 0) or { return none }
	port := (l.addr() or { return none }).port() or { return none }
	addr := '127.0.0.1:${port}'
	mut held := []&net.TcpConn{}
	for _ in 0 .. 16 {
		c := dial_tcp_within(addr, time.now().add(200 * time.millisecond), unsafe { nil }) or {
			if err is DialTimedOut {
				return l, addr, held
			}
			break
		}
		held << c
	}
	release_listener(mut l, mut held)
	return none
}

fn release_listener(mut l net.TcpListener, mut held []&net.TcpConn) {
	for mut c in held {
		c.close() or {}
	}
	l.close() or {}
}

fn test_a_connect_nothing_answers_ends_at_its_deadline() {
	mut l, addr, mut held := blackholed_listener() or {
		eprintln('skipped: this platform answers a connect to a full accept queue')
		return
	}
	defer {
		release_listener(mut l, mut held)
	}
	t0 := time.now()
	dial_tcp_within(addr, t0.add(300 * time.millisecond), unsafe { nil }) or {
		took := (time.now() - t0).milliseconds()
		assert err is DialTimedOut, err.msg()
		assert err.msg().contains('timed out'), err.msg()
		assert took >= 290 && took < 600, 'took ${took} ms'
		return
	}
	assert false, 'a connect nothing answers completed'
}

fn test_a_stop_during_a_connect_ends_it_within_a_poll() {
	mut l, addr, mut held := blackholed_listener() or {
		eprintln('skipped: this platform answers a connect to a full accept queue')
		return
	}
	defer {
		release_listener(mut l, mut held)
	}
	asked := chan bool{cap: 1}
	stop := fn [asked] () bool {
		return asked.len > 0
	}
	spawn fn [asked] () {
		time.sleep(100 * time.millisecond)
		asked <- true
	}()
	t0 := time.now()
	dial_tcp_within(addr, t0.add(5 * time.second), stop) or {
		took := (time.now() - t0).milliseconds()
		assert err is DialStopped, err.msg()
		assert took < 100 + dial_stop_poll_ms + 150, 'took ${took} ms'
		return
	}
	assert false, 'a stopped connect completed'
}

fn test_a_connect_that_is_answered_is_an_ordinary_connection() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer {
		l.close() or {}
	}
	port := (l.addr() or { panic(err) }).port() or { panic(err) }
	mut c := dial_tcp_within('127.0.0.1:${port}', time.now().add(time.second), unsafe { nil }) or {
		panic(err)
	}
	defer {
		c.close() or {}
	}
	mut s := l.accept() or { panic(err) }
	defer {
		s.close() or {}
	}
	c.write_string('ping') or { panic(err) }
	mut buf := []u8{len: 4}
	s.set_read_timeout(time.second)
	n := s.read(mut buf) or { panic(err) }
	assert buf[..n].bytestr() == 'ping'
}

fn test_a_refused_connect_is_an_error_not_a_wait() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := (l.addr() or { panic(err) }).port() or { panic(err) }
	l.close() or {}
	t0 := time.now()
	dial_tcp_within('127.0.0.1:${port}', t0.add(2 * time.second), unsafe { nil }) or {
		assert err !is DialTimedOut, err.msg()
		assert (time.now() - t0).milliseconds() < 1000
		return
	}
	assert false, 'a connect to a closed port completed'
}

fn test_a_literal_host_is_resolved_in_place() {
	assert is_literal_host('127.0.0.1:13400')
	assert is_literal_host('[::1]:13400')
	assert is_literal_host('[fe80::1%eth0]:13400')
	assert is_literal_host(':13400')
	assert !is_literal_host('localhost:13400')
	assert !is_literal_host('ecu-1.local:13400')
	assert !is_literal_host('127.0.0.1.:13400')
	assert !is_literal_host('127.1:13400')
	assert !is_literal_host('300.0.0.1:13400')
	assert !is_literal_host('[ecu]:13400')
}

// a stop asked before a name's lookup ends the dial without waiting for it
fn test_a_stop_ends_a_dial_by_name_before_its_lookup() {
	t0 := time.now()
	dial_tcp_within('localhost:1', t0.add(5 * time.second), fn () bool {
		return true
	}) or {
		assert err is DialStopped, err.msg()
		assert (time.now() - t0).milliseconds() < 200
		return
	}
	assert false, 'a stopped dial connected'
}
