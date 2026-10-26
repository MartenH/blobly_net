module transport

import net
import time

// full_listener is a local listener whose accept queue is full, so a further connect to it is
// never answered (Linux drops the SYN), with the connections that filled it. none where the
// platform answers such a connect some other way.
fn full_listener() ?(&net.TcpListener, int, []&net.TcpConn) {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0', backlog: 0) or { return none }
	port := (l.addr() or { return none }).port() or { return none }
	mut held := []&net.TcpConn{}
	for _ in 0 .. 16 {
		c := dial_tcp_within('127.0.0.1:${port}', time.now().add(200 * time.millisecond),
			unsafe { nil }) or {
			if err is DialTimedOut {
				return l, int(port), held
			}
			break
		}
		held << c
	}
	let_go(mut l, mut held)
	return none
}

fn let_go(mut l net.TcpListener, mut held []&net.TcpConn) {
	for mut c in held {
		c.close() or {}
	}
	l.close() or {}
}

// A DEVICE THAT ACCEPTS THE CONNECTION AND NEVER ANSWERS THE TLS HANDSHAKE costs the handshake's
// budget, not the TLS layer's own timeout. The listener never accepts; the kernel completes the TCP
// handshake into its queue, so the ClientHello is taken and nothing comes back.
fn test_a_tls_handshake_nothing_answers_ends_at_its_deadline() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer {
		l.close() or {}
	}
	port := (l.addr() or { panic(err) }).port() or { panic(err) }
	t0 := time.now()
	deadline := t0.add(300 * time.millisecond)
	mut t := dial_tcp_within('127.0.0.1:${port}', deadline, unsafe { nil }) or { panic(err) }
	cansub_handshake(mut t, 'silent.local', deadline, unsafe { nil }) or {
		took := (time.now() - t0).milliseconds()
		assert err.msg().contains('timed out'), err.msg()
		assert took < 450, 'took ${took} ms'
		return
	}
	assert false, 'a handshake nothing answered completed'
}

// A PEER THAT TRICKLES ITS ANSWER a byte at a time, each inside the per-read timeout, still ends
// the handshake at its deadline.
fn test_a_trickled_tls_handshake_ends_at_its_deadline() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer {
		l.close() or {}
	}
	port := (l.addr() or { panic(err) }).port() or { panic(err) }
	spawn fn [mut l] () {
		mut s := l.accept() or { return }
		// A TLS alert record's header, then its body, one byte per 50 ms.
		for b in [u8(0x15), 0x03, 0x03, 0x00, 0x40] {
			s.write([b]) or { break }
			time.sleep(50 * time.millisecond)
		}
		for _ in 0 .. 40 {
			s.write([u8(0)]) or { break }
			time.sleep(50 * time.millisecond)
		}
		s.close() or {}
	}()
	t0 := time.now()
	deadline := t0.add(300 * time.millisecond)
	mut t := dial_tcp_within('127.0.0.1:${port}', deadline, unsafe { nil }) or { panic(err) }
	cansub_handshake(mut t, 'trickle.local', deadline, unsafe { nil }) or {
		took := (time.now() - t0).milliseconds()
		assert took < 450, 'took ${took} ms: ${err.msg()}'
		return
	}
	assert false, 'a trickled handshake completed'
}

// A STOP ENDS A HANDSHAKE in progress within a stop poll.
fn test_a_stop_ends_a_tls_handshake() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer {
		l.close() or {}
	}
	port := (l.addr() or { panic(err) }).port() or { panic(err) }
	asked := chan bool{cap: 1}
	spawn fn [asked] () {
		time.sleep(100 * time.millisecond)
		asked <- true
	}()
	t0 := time.now()
	deadline := t0.add(5 * time.second)
	mut t := dial_tcp_within('127.0.0.1:${port}', deadline, unsafe { nil }) or { panic(err) }
	cansub_handshake(mut t, 'silent.local', deadline, fn [asked] () bool {
		return asked.len > 0
	}) or {
		took := (time.now() - t0).milliseconds()
		assert err.msg().contains('stop requested'), err.msg()
		assert took < 100 + dial_stop_poll_ms + 150, 'took ${took} ms'
		return
	}
	assert false, 'a stopped handshake completed'
}

// A REQUEST TO A DEVICE NOTHING ANSWERS ends within its budget, with a named error.
fn test_a_request_nothing_answers_ends_within_its_budget() {
	mut l, port, mut held := full_listener() or {
		eprintln('skipped: this platform answers a connect to a full accept queue')
		return
	}
	defer {
		let_go(mut l, mut held)
		cansub_port_for_test = 0
	}
	cansub_port_for_test = port
	t0 := time.now()
	cansub_request('127.0.0.1', 'GET', '/api/info', '', 400 * time.millisecond) or {
		took := (time.now() - t0).milliseconds()
		assert err is DialTimedOut, err.msg()
		assert took >= 390 && took < 700, 'took ${took} ms'
		return
	}
	assert false, 'a request nothing answered completed'
}

// A STOP ENDS A REQUEST WAITING FOR ITS CONNECTION within a stop poll.
fn test_a_stop_ends_a_request_waiting_for_its_connection() {
	mut l, port, mut held := full_listener() or {
		eprintln('skipped: this platform answers a connect to a full accept queue')
		return
	}
	defer {
		let_go(mut l, mut held)
		cansub_port_for_test = 0
	}
	cansub_port_for_test = port
	asked := chan bool{cap: 1}
	spawn fn [asked] () {
		time.sleep(100 * time.millisecond)
		asked <- true
	}()
	t0 := time.now()
	cansub_request_stoppable('127.0.0.1', 'GET', '/api/info', '', 5 * time.second, fn [asked] () bool {
		return asked.len > 0
	}) or {
		took := (time.now() - t0).milliseconds()
		assert err is DialStopped, err.msg()
		assert took < 100 + dial_stop_poll_ms + 150, 'took ${took} ms'
		return
	}
	assert false, 'a stopped request completed'
}

// CLOSE() WAITS FOR THE HEALTH THREAD — and promptly, because the thread's requests end within a
// stop poll of the close: when close() returns, the thread has returned too.
fn test_close_waits_for_the_health_thread() {
	mut l, port, mut held := full_listener() or {
		eprintln('skipped: this platform answers a connect to a full accept queue')
		return
	}
	defer {
		let_go(mut l, mut held)
		cansub_port_for_test = 0
	}
	cansub_port_for_test = port
	iface := 'cansub:AAAA0214/1@500000'
	mut b := &CansubBus{
		iface:       iface
		host:        '127.0.0.1'
		spec:        parse_cansub_iface(iface) or { panic(err) }
		rx:          chan CansubRecord{cap: 1}
		health_done: chan bool{cap: 1}
	}
	b.reader = spawn fn () {}()
	b.health_thr = spawn b.health_loop()
	b.started = true
	time.sleep(150 * time.millisecond) // inside its first readback's connect by now
	t0 := time.now()
	b.close()
	took := (time.now() - t0).milliseconds()
	assert took < 300, 'close took ${took} ms'
	// The thread's exit signal was taken by close(): it waited for it, rather than leaving it.
	b.health_thr.wait()
	assert b.health_done.len == 0, 'close() returned without waiting for the health thread'
}

// A READ IS NEVER GIVEN "NO TIMEOUT": what is left of a budget, under a millisecond or spent, is a
// millisecond, since the TLS layer reads a timeout of 0 ms as none.
fn test_a_spent_budget_is_still_a_bounded_read() {
	assert cansub_read_wait(-time.second) == time.millisecond
	assert cansub_read_wait(0) == time.millisecond
	assert cansub_read_wait(400 * time.microsecond) == time.millisecond
	assert cansub_read_wait(1500 * time.microsecond) == 2 * time.millisecond
	assert cansub_read_wait(700 * time.millisecond) == 700 * time.millisecond
}
