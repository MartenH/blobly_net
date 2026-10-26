module transport

import net
import time

// An address nothing answers on where routing lets a connect wait: a request to it ends within its
// budget whatever the network does with it.
const blackholed_host = '10.255.255.1'

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
	cansub_handshake(mut t, 'silent.local', deadline) or {
		took := (time.now() - t0).milliseconds()
		assert err.msg().contains('timed out'), err.msg()
		assert took < 700, 'took ${took} ms'
		return
	}
	assert false, 'a handshake nothing answered completed'
}

// A REQUEST TO A HOST NOTHING ANSWERS ends within its budget, with a named error.
fn test_a_request_to_a_blackholed_address_ends_within_its_budget() {
	t0 := time.now()
	cansub_request(blackholed_host, 'GET', '/api/info', '', 400 * time.millisecond) or {
		took := (time.now() - t0).milliseconds()
		assert took < 900, 'took ${took} ms: ${err.msg()}'
		if took >= 350 {
			assert err.msg().contains('timed out'), err.msg()
		}
		return
	}
	assert false, 'a request to ${blackholed_host} was answered'
}

// A STOP ENDS A REQUEST WAITING FOR ITS CONNECTION within a stop poll.
fn test_a_stop_ends_a_request_waiting_for_its_connection() {
	asked := chan bool{cap: 1}
	spawn fn [asked] () {
		time.sleep(100 * time.millisecond)
		asked <- true
	}()
	t0 := time.now()
	cansub_request_stoppable(blackholed_host, 'GET', '/api/info', '', 5 * time.second,
		fn [asked] () bool {
		return asked.len > 0
	}) or {
		took := (time.now() - t0).milliseconds()
		assert took < 100 + dial_stop_poll_ms + 300, 'took ${took} ms: ${err.msg()}'
		return
	}
	assert false, 'a request to ${blackholed_host} was answered'
}

// CLOSE() WAITS FOR THE HEALTH THREAD — and promptly, because the thread's requests end within a
// stop poll of the close: when close() returns, the thread has returned too.
fn test_close_waits_for_the_health_thread() {
	iface := 'cansub:AAAA0214/1@500000'
	mut b := &CansubBus{
		iface:       iface
		host:        blackholed_host
		spec:        parse_cansub_iface(iface) or { panic(err) }
		rx:          chan CansubRecord{cap: 1}
		health_done: chan bool{cap: 1}
	}
	b.reader = spawn fn () {}()
	b.health_thr = spawn b.health_loop()
	b.started = true
	time.sleep(150 * time.millisecond) // inside its first readback by now
	t0 := time.now()
	b.close()
	took := (time.now() - t0).milliseconds()
	assert took < 500, 'close took ${took} ms'
	// The thread's exit signal was taken by close(): it waited for it, rather than leaving it.
	b.health_thr.wait()
	assert b.health_done.len == 0, 'close() returned without waiting for the health thread'
}
