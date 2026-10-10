module doip

import net
import testports
import time
import uds

// A uds-free networking test: a DoIP server with a trivial echo+1 handler, driven
// by DoipClient over real localhost TCP, plus UDP discovery. Keeps `v test
// modules/doip/` free of the uds→isotp→transport globals dependency.

// PER PROCESS, not a constant. A fixed port collides two ways — with another test in the same
// suite, and with another suite run (or anything else on the machine) that happens to hold it —
// and both show up as one intermittent failure nobody can reproduce afterwards (#112).
//
// Derived from the pid so two concurrent runs cannot meet, with a slot to keep tests in one run
// apart, since a file's tests share a process. Above 20000 to stay clear of 13400, which is
// DoIP's registered port and may genuinely be in use here by a real entity.
//
// Where a test owns its listener outright it uses port 0 instead and reads back what the OS
// assigned — see free_listener below, which cannot collide at all. This helper is for the cases
// that cannot: DoipServer.listen binds TCP and UDP to the SAME number, and port 0 would hand
// those two different ones — so the number has to be known before the bind, and the only honest
// way to know it is to have bound it.
//
// listen_somewhere walks this file's band (see `testports`) and returns the first port the server
// actually took. A pid-derived guess is where it STARTS, not what it trusts: any formula over a
// finite band aliases, and two live processes that alias would otherwise both be told the same
// free port. Binding settles it, and settles two sites in one process too — the first holds its
// socket, so the second's bind fails there and it moves on.
//
// 0 means every candidate refused, which is an environment fact (no IPv6 loopback on this runner)
// rather than one unlucky number. Callers that skip on that can now mean it.
//
// What this settles and what it does not. listen() takes TCP AND UDP on the number, and only the
// TCP bind can fail — `net.listen_udp` sets SO_REUSEADDR on every platform tested, so a second
// socket takes a held UDP endpoint without complaint, and on Linux the LATER binder then receives
// the unicast sent to it.
//
// The case that matters is still covered: another run of THIS file holds the pair, TCP included,
// so its TCP bind refuses us and we move on. What is not covered is an unrelated process holding
// only the UDP side of a port in our band — then the TCP bind succeeds and the server shares its
// discovery datagrams with whoever else is there.
//
// That gap is left open deliberately. Closing it needs an exclusive UDP reservation, and this V's
// net API offers no way to ask for one; a probe that binds the port and checks whether the token
// comes back was tried and DOES NOT WORK, because the prober is the later binder and therefore
// wins delivery from the very squatter it is looking for — CI proved it on Linux. Raw C sockets in
// a test helper would buy the last few percent for two platforms' worth of #ifdef.
fn listen_somewhere(mut srv DoipServer, host string) int {
	for p in testports.doip.candidates() {
		srv.listen(host, p) or { continue }
		return p
	}
	return 0
}

// A TCP listener on an OS-assigned port, with the port it actually got. Nothing can collide with
// this: the socket is bound before the number is known, so there is no window in which another
// process could take it. Preferred wherever the test only needs *a* port.
fn free_listener() !(&net.TcpListener, int) {
	mut ln := net.listen_tcp(.ip, '127.0.0.1:0')!
	a := ln.addr() or {
		ln.close() or {}
		return error('no addr: ${err}')
	}
	return ln, int(a.port() or {
		ln.close() or {}
		return error('no port')
	})
}

fn echo_handler(req []u8) []u8 {
	return req.map(it + 1) // distinct from the request so we know it round-tripped
}

// A DoipClient must ignore a diagnostic-message response addressed to/from other
// logical addresses (gateway noise / spoofing) and only accept the one for its own
// source/target pair.
fn test_client_ignores_foreign_response() {
	// This test owns its listener and needs no particular number, so it takes an OS-assigned
	// one — which cannot collide with anything, unlike a derived port that merely collides
	// rarely.
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	spawn fn (mut ln net.TcpListener) {
		mut c := ln.accept() or { return }
		// routing activation handshake
		_ := read_message(mut c, 2000) or { return }
		c.write(routing_activation_response(0x0E80, 0x1000, ra_success)) or { return }
		// consume the diagnostic request, then reply: a FOREIGN-addressed 0x8001
		// first, then the correctly-addressed one.
		_ := read_message(mut c, 2000) or { return }
		c.write(diagnostic_message(0x2222, 0x0E80, [u8(0x59), 0x99])) or { return } // wrong source
		c.write(diagnostic_message(0x1000, 0x9999, [u8(0x58), 0x88])) or { return } // wrong target
		c.write(diagnostic_message(0x1000, 0x0E80, [u8(0x62), 0xAA])) or { return } // ours
		time.sleep(200 * time.millisecond)
		c.close() or {}
	}(mut ln)
	time.sleep(150 * time.millisecond)

	mut ch := open_doip('127.0.0.1', lport, 0x0E80, 0x1000) or {
		assert false, 'open_doip: ${err}'
		return
	}
	ch.send([u8(0x22), 0xF1, 0x90]) or { assert false, 'send: ${err}' }
	resp := ch.recv(2000) or {
		assert false, 'recv: ${err}'
		return
	}
	assert resp == [u8(0x62), 0xAA] // skipped both foreign responses, took ours
	ch.close()
	ln.close() or {}
}

fn test_client_server_roundtrip() {
	mut srv := new_server(ServerCfg{ logical_address: 0x1000, vin: 'TESTVIN0000000001' },
		echo_handler)
	// TCP and UDP must share the number, so this cannot be an OS-assigned one — it is bound,
	// then reused, rather than predicted.
	test_port := listen_somewhere(mut srv, '127.0.0.1')
	if test_port == 0 {
		assert false, 'no bindable port in the band'
		return
	}
	spawn fn (mut s DoipServer) {
		for {
			s.accept_and_serve(300) or {
				if s.stopping {
					break
				}
				continue
			}
		}
	}(mut srv)
	spawn fn (mut s DoipServer) {
		for {
			s.serve_udp_once(300) or {
				if s.stopping {
					break
				}
				continue
			}
		}
	}(mut srv)
	time.sleep(150 * time.millisecond)

	// TCP: routing activation (in open_doip) + a diagnostic message round-trip.
	mut ch := open_doip('127.0.0.1', test_port, 0x0E80, 0x1000) or {
		assert false, 'open_doip failed: ${err}'
		return
	}
	assert ch.tx_id == 0x0E80
	assert ch.rx_id == 0x1000
	ch.send([u8(0x10), 0x20, 0x30]) or { assert false, 'send: ${err}' }
	resp := ch.recv(2000) or {
		assert false, 'recv: ${err}'
		return
	}
	assert resp == [u8(0x11), 0x21, 0x31] // echo_handler added 1 to each byte
	ch.close()

	// UDP: vehicle identification request → announcement with our VIN.
	mut u := net.dial_udp('127.0.0.1:${test_port}') or {
		assert false, 'dial_udp: ${err}'
		return
	}
	u.write(vehicle_id_request()) or { assert false, 'udp write: ${err}' }
	u.set_read_timeout(2 * time.second)
	mut buf := []u8{len: 128}
	n, _ := u.read(mut buf) or {
		assert false, 'udp read: ${err}'
		return
	}
	ann := parse(buf[..n]) or {
		assert false, 'parse announcement: ${err}'
		return
	}
	assert ann.payload_type == pt_vehicle_announcement
	assert ann.payload[..17].bytestr() == 'TESTVIN0000000001'

	// Regression: a hostile UDP datagram advertising a 0xFFFFFFFF payload length
	// must NOT crash the discovery thread (parse() rejects it before slicing).
	hostile := [protocol_version, u8(~protocol_version), u8(0x00), 0x01, 0xFF, 0xFF, 0xFF, 0xFF]
	u.write(hostile) or { assert false, 'udp write hostile: ${err}' }
	time.sleep(100 * time.millisecond)
	// The thread should still answer a subsequent valid request.
	u.write(vehicle_id_request()) or { assert false, 'udp write 2: ${err}' }
	u.set_read_timeout(2 * time.second)
	mut buf2 := []u8{len: 128}
	n2, _ := u.read(mut buf2) or {
		assert false, 'discovery thread died after hostile datagram: ${err}'
		return
	}
	ann2 := parse(buf2[..n2]) or {
		assert false, 'parse after hostile: ${err}'
		return
	}
	assert ann2.payload_type == pt_vehicle_announcement
	u.close() or {}

	// Regression: a diagnostic message addressed to a DIFFERENT target must be
	// NACKed (0x8003), not ACKed+dispatched. DoipClient.recv surfaces the NACK as
	// an error.
	mut wrong := open_doip('127.0.0.1', test_port, 0x0E80, 0x9999) or {
		assert false, 'open_doip (wrong target): ${err}'
		return
	}
	wrong.send([u8(0x10), 0x20, 0x30]) or { assert false, 'send (wrong target): ${err}' }
	if _ := wrong.recv(2000) {
		assert false, 'server dispatched a diagnostic message for a foreign target'
	}
	wrong.close()

	// Regression: after activation, a diagnostic message whose source differs from
	// the activated source must be NACKed (invalid source 0x02), not dispatched.
	mut spoof := net.dial_tcp('127.0.0.1:${test_port}') or {
		assert false, 'dial (spoof): ${err}'
		return
	}
	spoof.write(routing_activation_request(0x0E80)) or { assert false, 'activate: ${err}' }
	ra_resp := read_message(mut spoof, 2000) or {
		assert false, 'activation resp: ${err}'
		return
	}
	assert ra_resp.payload_type == pt_routing_activation_response
	assert ra_resp.payload[4] == ra_success
	// A second activation with a DIFFERENT source must be denied (0x02) and must
	// NOT overwrite the activated source — otherwise the spoofed-source guard below
	// could be bypassed by re-activating.
	spoof.write(routing_activation_request(0x0E81)) or { assert false, 'reactivate: ${err}' }
	ra2 := read_message(mut spoof, 2000) or {
		assert false, 'reactivation resp: ${err}'
		return
	}
	assert ra2.payload_type == pt_routing_activation_response
	assert ra2.payload[4] == ra_denied_source_mismatch
	spoof.write(diagnostic_message(0x0E81, 0x1000, [u8(0x10), 0x20, 0x30])) or {
		assert false, 'spoof send: ${err}'
	}
	nack := read_message(mut spoof, 2000) or {
		assert false, 'expected NACK for spoofed source: ${err}'
		return
	}
	assert nack.payload_type == pt_diagnostic_message_nack
	ndm := parse_diagnostic_message(nack.payload) or {
		assert false, 'parse nack: ${err}'
		return
	}
	assert ndm.data.len >= 1 && ndm.data[0] == diag_nack_invalid_source
	spoof.close() or {}

	// Regression: a diagnostic message before routing activation must NOT be
	// dispatched (the server drops it; the peer gets no response).
	mut raw := net.dial_tcp('127.0.0.1:${test_port}') or {
		assert false, 'dial: ${err}'
		return
	}
	raw.write(diagnostic_message(0x0E80, 0x1000, [u8(0x10), 0x20, 0x30])) or {
		assert false, 'write: ${err}'
	}
	raw.set_read_timeout(500 * time.millisecond)
	mut rbuf := []u8{len: 32}
	got := raw.read(mut rbuf) or { -1 } // timeout → error → -1
	assert got <= 0, 'server replied to diagnostics without routing activation'
	raw.close() or {}

	// Regression: an oversized advertised payload length must be rejected before
	// allocating a buffer (the server returns an error → closes the connection,
	// rather than allocating gigabytes or hanging on a body that never arrives).
	mut big := net.dial_tcp('127.0.0.1:${test_port}') or {
		assert false, 'dial: ${err}'
		return
	}
	// generic header only: payload_type 0x8001, payload_length 0x7FFFFFFF, no body.
	header := [protocol_version, u8(~protocol_version), u8(0x80), 0x01, 0x7F, 0xFF, 0xFF, 0xFF]
	big.write(header) or { assert false, 'write: ${err}' }
	big.set_read_timeout(1 * time.second)
	mut bbuf := []u8{len: 16}
	bgot := big.read(mut bbuf) or { -1 } // connection closed (EOF) or timeout
	assert bgot <= 0, 'server did not reject oversized payload length'
	big.close() or {}

	srv.close()
}

// close() must tear down the in-progress accepted connection from another thread
// (a GUI Stop), interrupting serve_connection's per-connection read PROMPTLY
// rather than waiting out its 60s timeout.
fn test_close_interrupts_active_connection() {
	mut srv := new_server(ServerCfg{ logical_address: 0x1000 }, echo_handler)
	lport := listen_somewhere(mut srv, '127.0.0.1')
	if lport == 0 {
		assert false, 'no bindable port in the band'
		return
	}
	spawn fn (mut srv DoipServer) {
		for {
			srv.accept_and_serve(200) or {
				if srv.stopping {
					break
				}
				continue
			}
		}
	}(mut srv)
	time.sleep(150 * time.millisecond)
	// Connect + activate routing, then idle so the server is parked in the
	// per-connection read (s.active set).
	mut c := net.dial_tcp('127.0.0.1:${lport}') or {
		assert false, 'dial: ${err}'
		return
	}
	c.write(routing_activation_request(0x0E80)) or { assert false, 'write: ${err}' }
	// Generous activation timeout: under heavy parallel test load the server thread
	// can be slow to schedule. This is only setup — it confirms the server is parked
	// in serve_connection's next read; the interrupt bound below is what's asserted.
	_ := read_message(mut c, 8000) or {
		assert false, 'activation resp: ${err}'
		return
	}
	time.sleep(150 * time.millisecond)
	// Stop from this (different) thread.
	t0 := time.ticks()
	srv.close()
	// Use a client read timeout (10s) FAR above the interrupt bound we assert (4s):
	// if close() failed to interrupt the server's read, the server would hold the
	// connection and this client read would block until its own 10s timeout —
	// blowing the 4s bound. So a pass genuinely proves the server closed the
	// connection (vs the 60s per-connection read it'd otherwise wait out), not that
	// the client merely timed out. 4s tolerates scheduler jitter under parallel load.
	c.set_read_timeout(10 * time.second)
	mut buf := []u8{len: 16}
	mut timed_out := false
	n := c.read(mut buf) or {
		// distinguish a real close (EOF/reset, arrives promptly) from a read timeout
		timed_out = err.code() == net.err_timed_out_code
		-1
	}
	elapsed := time.ticks() - t0
	assert !timed_out, 'client read timed out — server did not close the connection'
	assert n <= 0, 'expected the server to close the active connection, read ${n} bytes'
	assert elapsed < 4000, 'close() did not interrupt the active read promptly (${elapsed} ms)'
	c.close() or {}
}

// IPv6 end-to-end: the entity binds an IPv6 literal (bracketed + ip6 family) and
// DoipClient dials it. Guarded — skips cleanly where IPv6 loopback is unavailable
// (some CI runners) rather than failing.
fn test_ipv6_roundtrip() {
	mut srv := new_server(ServerCfg{ logical_address: 0x1000, vin: 'TESTVIN0000000001' },
		echo_handler)
	v6_port := listen_somewhere(mut srv, '::1')
	if v6_port == 0 {
		// EVERY candidate refused, so this is the environment and not a busy port. That
		// distinction is the point: a single fixed port made a collision indistinguishable from
		// "no IPv6 here", and this skip then dropped the coverage without saying so.
		eprintln('skipping IPv6 roundtrip (no IPv6 loopback here)')
		return
	}
	spawn fn (mut s DoipServer) {
		for {
			s.accept_and_serve(300) or {
				if s.stopping {
					break
				}
				continue
			}
		}
	}(mut srv)
	time.sleep(150 * time.millisecond)
	mut ch := open_doip('::1', v6_port, 0x0E80, 0x1000) or {
		srv.close()
		assert false, 'IPv6 open_doip: ${err}'
		return
	}
	ch.send([u8(0x10), 0x03]) or { assert false, 'send: ${err}' }
	resp := ch.recv(2000) or {
		ch.close()
		srv.close()
		assert false, 'recv: ${err}'
		return
	}
	assert resp == [u8(0x11), 0x04] // echo+1 of the request
	ch.close()
	srv.close()
}

// discover() sends a UDP vehicle-id request and parses the announcement.
fn test_discover() {
	mut srv := new_server(ServerCfg{ logical_address: 0x1234, vin: 'TESTVIN0000000099' },
		echo_handler)
	dport := listen_somewhere(mut srv, '127.0.0.1')
	if dport == 0 {
		assert false, 'no bindable port in the band'
		return
	}
	spawn fn (mut s DoipServer) {
		for {
			s.serve_udp_once(300) or {
				if s.stopping {
					break
				}
				continue
			}
		}
	}(mut srv)
	time.sleep(150 * time.millisecond)
	info := discover('127.0.0.1', dport, 1000) or {
		srv.close()
		assert false, 'discover: ${err}'
		return
	}
	assert info.vin == 'TESTVIN0000000099'
	assert info.logical_address == 0x1234
	srv.close()
}

// identify() returns every answer to one request, each with the address a tester dials, and
// waits out its window rather than stopping at the first answer.
fn test_identify_lists_the_answering_entity_with_its_dial_address() {
	mut srv := new_server(ServerCfg{ logical_address: 0x07A0, vin: 'TESTVIN0000000042' },
		echo_handler)
	dport := listen_somewhere(mut srv, '127.0.0.1')
	if dport == 0 {
		assert false, 'no bindable port in the band'
		return
	}
	spawn fn (mut s DoipServer) {
		for {
			s.serve_udp_once(300) or {
				if s.stopping {
					break
				}
				continue
			}
		}
	}(mut srv)
	time.sleep(150 * time.millisecond)
	found := identify('127.0.0.1', dport, 400) or {
		srv.close()
		assert false, 'identify: ${err}'
		return
	}
	srv.close()
	assert found.len == 1
	assert found[0].info.vin_text() == 'TESTVIN0000000042'
	assert found[0].info.logical_address == 0x07A0
	assert found[0].dial_address(dport) == '127.0.0.1:${dport}'
}

// A hostname is resolved before the socket is bound, so one with only an IPv6 address
// (ip6-localhost, ::1 in /etc/hosts) is asked over IPv6 rather than refused for having no colon.
fn test_identify_resolves_a_hostname_to_its_own_family() {
	net.resolve_addrs('ip6-localhost:13400', .ip6, .udp) or {
		eprintln('skip: ip6-localhost does not resolve here')
		return
	}
	mut srv := new_server(ServerCfg{ logical_address: 0x07A1, vin: 'TESTVIN0000000043' },
		echo_handler)
	dport := listen_somewhere(mut srv, '::1')
	if dport == 0 {
		eprintln('skip: no IPv6 loopback')
		return
	}
	spawn fn (mut s DoipServer) {
		for {
			s.serve_udp_once(300) or {
				if s.stopping {
					break
				}
				continue
			}
		}
	}(mut srv)
	time.sleep(150 * time.millisecond)
	found := identify('ip6-localhost', dport, 400) or {
		srv.close()
		assert false, 'identify: ${err}'
		return
	}
	srv.close()
	assert found.len == 1
	assert found[0].info.logical_address == 0x07A1
}

// Several resolved addresses are all asked, in ONE window: here the first (127.0.0.2, where
// nothing listens) stays silent and the second answers.
fn test_identify_asks_every_resolved_address_in_one_window() {
	mut srv := new_server(ServerCfg{ logical_address: 0x07A2, vin: 'TESTVIN0000000044' },
		echo_handler)
	dport := listen_somewhere(mut srv, '127.0.0.1')
	if dport == 0 {
		assert false, 'no bindable port in the band'
		return
	}
	spawn fn (mut s DoipServer) {
		for {
			s.serve_udp_once(300) or {
				if s.stopping {
					break
				}
				continue
			}
		}
	}(mut srv)
	time.sleep(150 * time.millisecond)
	mut addrs := net.resolve_addrs('127.0.0.2:${dport}', .ip, .udp) or { panic(err) }
	addrs << net.resolve_addrs('127.0.0.1:${dport}', .ip, .udp) or { panic(err) }
	t0 := time.ticks()
	found := identify_addrs(addrs, 400) or {
		srv.close()
		assert false, 'identify_addrs: ${err}'
		return
	}
	took := time.ticks() - t0
	srv.close()
	assert found.len == 1
	assert found[0].info.logical_address == 0x07A2
	assert took < 800, 'one window, not one per address: ${took} ms'
}

// The power-on announcement, end to end: an entity announces unasked and a LISTENING tester
// hears it. This is the half of discovery a real vehicle performs and the simulator did not —
// a tester that waits for announcements saw nothing at all before this.
fn test_entity_announces_itself_unasked() {
	handler := fn (req []u8) []u8 {
		return []
	}
	mut srv := new_server(ServerCfg{
		logical_address:   0x1234
		vin:               'ANNOUNCEDVIN00001'
		announce_count:    2
		announce_interval: 50
	}, handler)
	aport := listen_somewhere(mut srv, '127.0.0.1')
	if aport == 0 {
		assert false, 'no bindable port in the band'
		return
	}
	defer {
		srv.close()
	}
	// listener first: announcements are not queued for a tester that is not there yet
	mut got := []Announcement{}
	t := spawn fn [aport] () []Announcement {
		// the entity's OWN port: announcements go where it is bound, not to the module default
		return collect_announcements(aport, 900) or { []Announcement{} }
	}()
	time.sleep(150 * time.millisecond)
	srv.announce() or {
		assert false, 'announce: ${err}'
		return
	}
	got = t.wait()
	assert got.len >= 1, 'expected at least one announcement, got ${got.len}'
	assert got[0].info.vin == 'ANNOUNCEDVIN00001'
	assert got[0].info.logical_address == 0x1234
	// the sender endpoint is kept: passive discovery has to be able to dial back
	assert got[0].from.contains('127.0.0.1'), 'lost the sender endpoint: ${got[0].from}'
}

fn test_announce_count_zero_says_nothing() {
	handler := fn (req []u8) []u8 {
		return []
	}
	mut srv := new_server(ServerCfg{
		announce_count: 0
	}, handler)
	zport := listen_somewhere(mut srv, '127.0.0.1')
	if zport == 0 {
		assert false, 'no bindable port in the band'
		return
	}
	defer {
		srv.close()
	}
	t := spawn fn [zport] () []Announcement {
		return collect_announcements(zport, 400) or { []Announcement{} }
	}()
	time.sleep(100 * time.millisecond)
	srv.announce() or {
		assert false, 'announce with count 0 should be a no-op, got: ${err}'
		return
	}
	got := t.wait()
	assert got.len == 0, 'a silent ECU announced ${got.len} time(s)'
}

// An IPv4 announce_to on an IPv6-bound entity cannot work — an IPv6 socket has no route to an
// IPv4 broadcast address, and there is no v4-mapped form of one. What it must NOT do is fail at
// every Start with a bare socket errno: the two settings that disagree are named.
fn test_an_ipv4_announce_to_on_an_ipv6_entity_says_which_settings_disagree() {
	handler := fn (req []u8) []u8 {
		return []
	}
	mut srv := new_server(ServerCfg{
		logical_address: 0x1000
		vin:             'V6ENTITYVIN000001'
		announce_count:  1
		announce_to:     '127.255.255.255'
	}, handler)
	if listen_somewhere(mut srv, '::1') == 0 {
		// the same environment skip test_ipv6_roundtrip uses, and now it means what it says:
		// every candidate refused, not one that happened to be taken
		eprintln('skipping IPv4-announce_to-on-IPv6 (no IPv6 loopback here)')
		return
	}
	defer {
		srv.close()
	}
	if _ := srv.announce() {
		assert false, 'an IPv4 broadcast from an IPv6 socket cannot have succeeded'
		return
	} else {
		assert err.msg().contains('IPv4'), 'unhelpful: ${err}'
		assert err.msg().contains('::1'), 'the message must name the binding too: ${err}'
	}
}

// a timeout before a message's first byte is the carrier's silence; one after bytes of it were
// read is a message that stalled — the stream is inside it, and it must not read as silence
fn test_a_message_that_stalls_mid_read_is_not_silence() {
	for partial in [false, true] {
		mut l := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
		addr := l.addr() or { panic(err) }
		spawn fn [mut l, partial] () {
			mut c := l.accept() or { return }
			if partial {
				c.write([u8(0x02), 0xFD, 0x80]) or {} // three bytes of a header
			}
			time.sleep(600 * time.millisecond)
			c.close() or {}
		}()
		mut conn := net.dial_tcp(addr.str()) or { panic(err) }
		if _ := read_message(mut conn, 200) {
			assert false, 'nothing complete was sent'
		} else {
			if partial {
				assert err.msg().contains('stalled mid-read'), err.msg()
			} else {
				assert err.code() == net.err_timed_out_code, err.msg()
			}
		}
		conn.close() or {}
		l.close() or {}
	}
}

// #358: recv(0) is a POLL — it returns what has already arrived, message by message (an ack in
// front of it skipped), and answers timeout at once when nothing has; which is what lets the UDS
// client's pre-send drain clear a late answer on DoIP as it does on CAN
fn test_recv_zero_polls_what_has_arrived() {
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	spawn fn (mut ln net.TcpListener) {
		mut c := ln.accept() or { return }
		_ := read_message(mut c, 2000) or { return }
		c.write(routing_activation_response(0x0E80, 0x1000, ra_success)) or { return }
		time.sleep(200 * time.millisecond)
		// a late answer, and an ack in front of it, arriving while the client asked nothing
		c.write(diagnostic_message_ack(0x1000, 0x0E80, 0)) or { return }
		c.write(diagnostic_message(0x1000, 0x0E80, [u8(0x62), 0x01])) or { return }
		time.sleep(600 * time.millisecond)
		c.close() or {}
	}(mut ln)
	time.sleep(100 * time.millisecond)
	mut ch := open_doip('127.0.0.1', lport, 0x0E80, 0x1000) or {
		assert false, 'open_doip: ${err}'
		return
	}
	t0 := time.ticks()
	if _ := ch.recv(0) {
		assert false, 'a poll with nothing queued returned data'
	}
	assert time.ticks() - t0 < 100, 'a poll with nothing queued waited'
	time.sleep(350 * time.millisecond) // the late answer is in the socket now
	got := ch.recv(0) or {
		assert false, 'the queued answer was not polled: ${err}'
		return
	}
	assert got == [u8(0x62), 0x01]
	if _ := ch.recv(0) {
		assert false, 'a poll after the queued answer returned data'
	}
	ch.close()
	ln.close() or {}
}

// #358, end to end: a UDS client over DoIP, whose entity answers a first request LATE — after the
// client has given up — takes the second request's own answer, not the late one: the pre-send
// drain polls the late answer away. Both requests are identical, so no echo could tell the two
// answers apart; only the drain can.
fn test_uds_over_doip_drains_a_late_answer() {
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	spawn fn (mut ln net.TcpListener) {
		mut c := ln.accept() or { return }
		_ := read_message(mut c, 2000) or { return }
		c.write(routing_activation_response(0x0E80, 0x1000, ra_success)) or { return }
		_ := read_message(mut c, 2000) or { return } // first request: answered late
		time.sleep(400 * time.millisecond)
		c.write(diagnostic_message(0x1000, 0x0E80, [u8(0x62), 0xF1, 0x90, 0x01])) or { return }
		_ := read_message(mut c, 3000) or { return } // second request: answered at once
		c.write(diagnostic_message(0x1000, 0x0E80, [u8(0x62), 0xF1, 0x90, 0x02])) or { return }
		time.sleep(500 * time.millisecond)
		c.close() or {}
	}(mut ln)
	time.sleep(100 * time.millisecond)
	ch := open_doip('127.0.0.1', lport, 0x0E80, 0x1000) or {
		assert false, 'open_doip: ${err}'
		return
	}
	mut cl := uds.new_client(ch)
	cl.timeout_ms = 200
	if _ := cl.raw([u8(0x22), 0xF1, 0x90]) {
		assert false, 'the first request was answered in time'
	}
	time.sleep(400 * time.millisecond) // the late answer has now arrived and waits in the socket
	cl.timeout_ms = 1000
	got := cl.raw([u8(0x22), 0xF1, 0x90]) or {
		assert false, 'second request: ${err}'
		return
	}
	assert got == [u8(0x62), 0xF1, 0x90, 0x02], 'the late answer was taken for the new request'
	ln.close() or {}
}

fn serve_until_closed(mut s DoipServer) {
	for {
		s.accept_and_serve(300) or {
			if s.is_stopping() {
				break
			}
			continue
		}
	}
}

// A functional request: a diagnostic message to the functional address is acked FROM that address
// and answered from the entity's own; an answer the functional rule withholds is not sent, and a
// message to another address is NACKed unknown-target.
fn test_entity_answers_a_functional_target() {
	mut srv := new_server(ServerCfg{
		logical_address:     0x1000
		functional_withheld: fn (r []u8) bool {
			return r.len == 3 && r[0] == 0x7F && r[2] == 0x11
		}
	}, fn (req []u8) []u8 {
		return if req[0] == 0x31 { [u8(0x7F), 0x31, 0x11] } else { [req[0] + 0x40] }
	})
	lport := listen_somewhere(mut srv, '127.0.0.1')
	if lport == 0 {
		assert false, 'no bindable port in the band'
		return
	}
	spawn serve_until_closed(mut srv)
	defer {
		srv.close()
	}
	mut ch := open_doip('127.0.0.1', lport, 0x0E80, 0x1000) or {
		assert false, 'open_doip: ${err}'
		return
	}
	defer {
		ch.close()
	}
	ch.send_to(0xE400, [u8(0x3E), 0x00]) or { assert false, 'send_to: ${err}' }
	ack := read_message(mut ch.conn, 2000) or {
		assert false, 'ack: ${err}'
		return
	}
	assert ack.payload_type == pt_diagnostic_message_ack
	assert ack.payload[0..4] == [u8(0xE4), 0x00, 0x0E, 0x80], 'the ack is from the functional address'
	rsp := read_message(mut ch.conn, 2000) or {
		assert false, 'response: ${err}'
		return
	}
	dm := parse_diagnostic_message(rsp.payload) or {
		assert false, '${err}'
		return
	}
	assert dm.source == 0x1000, 'the answer is from the entity address'
	assert dm.target == 0x0E80
	assert dm.data == [u8(0x7E)]
	// withheld: the ack and then nothing; the physical request after it is answered at once
	ch.send_to(0xE400, [u8(0x31), 0x01]) or { assert false, 'send_to: ${err}' }
	ch.send([u8(0x22)]) or { assert false, 'send: ${err}' }
	assert ch.recv(2000) or { []u8{} } == [u8(0x62)], 'the withheld answer was sent'
	// another address entirely is NACKed, not acked
	ch.send_to(0xE401, [u8(0x3E), 0x00]) or { assert false, 'send_to: ${err}' }
	if _ := ch.recv(2000) {
		assert false, 'a message to an unknown target was answered'
	} else {
		assert err.msg().contains('negative ack (0x03)'), err.msg()
	}
}

// uds.functional_addressed over a real connection: one entity's answer, the suppressed positive
// response silent, the ack in front of each skipped.
fn test_uds_functional_addressed_over_doip() {
	mut srv := new_server(ServerCfg{ logical_address: 0x1000 }, fn (req []u8) []u8 {
		if req.len > 1 && req[1] & 0x80 != 0 {
			return []u8{} // a suppressed positive response
		}
		return [req[0] + 0x40, req[1]]
	})
	lport := listen_somewhere(mut srv, '127.0.0.1')
	if lport == 0 {
		assert false, 'no bindable port in the band'
		return
	}
	spawn serve_until_closed(mut srv)
	defer {
		srv.close()
	}
	mut dc := open_doip('127.0.0.1', lport, 0x0E80, 0x1000) or {
		assert false, 'open_doip: ${err}'
		return
	}
	defer {
		dc.close()
	}
	mut cl := uds.new_client(dc)
	mut via := uds.AddressedSend(dc)
	r := uds.functional_addressed(mut cl, mut via, default_functional_address, [u8(0x3E), 0x00],
		500) or {
		assert false, '${err}'
		return
	}
	assert r.outcome == .positive
	assert r.resp == [u8(0x7E), 0x00]
	q := uds.functional_addressed(mut cl, mut via, default_functional_address, [u8(0x3E), 0x80],
		300) or {
		assert false, '${err}'
		return
	}
	assert q.outcome == .silent
}

// opening says what it cost, apart: the connect, then the routing activation exchange
fn test_open_times_the_connect_and_the_routing_activation_apart() {
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	spawn fn (mut ln net.TcpListener) {
		mut c := ln.accept() or { return }
		_ := read_message(mut c, 2000) or { return }
		time.sleep(80 * time.millisecond) // an entity slow to activate
		c.write(routing_activation_response(0x0E80, 0x1000, ra_success)) or { return }
		_ := read_message(mut c, 2000) or { Message{} }
		c.close() or {}
	}(mut ln)
	mut ch := open_doip('127.0.0.1', lport, 0x0E80, 0x1000) or {
		assert false, 'open_doip: ${err}'
		return
	}
	assert ch.activate_us >= 80_000
	assert ch.connect_us >= 0 && ch.connect_us < ch.activate_us
	ch.close()
	ln.close() or {}
}

// a stoppable client's recv ends when the stop is requested, not at its deadline
fn test_a_stop_ends_a_blocked_recv() {
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	spawn fn (mut ln net.TcpListener) {
		mut c := ln.accept() or { return }
		_ := read_message(mut c, 2000) or { return }
		c.write(routing_activation_response(0x0E80, 0x1000, ra_success)) or { return }
		_ := read_message(mut c, 5000) or { Message{} } // silent: the request is never answered
		c.close() or {}
	}(mut ln)
	at := time.ticks() + 100
	mut ch := open_doip_stoppable('127.0.0.1', lport, 0x0E80, 0x1000, fn [at] () bool {
		return time.ticks() >= at
	}) or {
		assert false, 'open_doip_stoppable: ${err}'
		return
	}
	sw := time.new_stopwatch()
	if _ := ch.recv(4000) {
		assert false, 'nothing was sent, so nothing can be received'
	} else {
		assert err.msg() == stopped_note, err.msg()
	}
	assert sw.elapsed().milliseconds() < 1000
	ch.close()
	ln.close() or {}
}

// ...and so does the open, in the routing activation read: an entity that accepts and never
// answers held it for the read's two seconds
fn test_a_stop_ends_a_routing_activation_wait() {
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	spawn fn (mut ln net.TcpListener) {
		mut c := ln.accept() or { return }
		_ := read_message(mut c, 3000) or { Message{} }
		time.sleep(2 * time.second) // the request is read and never answered
		c.close() or {}
	}(mut ln)
	at := time.ticks() + 100
	stop := fn [at] () bool {
		return time.ticks() >= at
	}
	sw := time.new_stopwatch()
	mut why := 'opened'
	mut ch := open_doip_stoppable('127.0.0.1', lport, 0x0E80, 0x1000, stop) or {
		why = err.msg()
		&DoipClient{}
	}
	assert why == stopped_note, why
	assert sw.elapsed().milliseconds() < 1000
	ln.close() or {}
}

// ...and in the TCP connect, which has no slice of its own to ask in (the dial is a stand-in for
// one blocked on an unreachable host)
fn test_a_stop_ends_a_blocked_connect() {
	slow := fn (addr string) !&net.TcpConn {
		time.sleep(2 * time.second)
		return error('connect timed out')
	}
	at := time.ticks() + 50
	stop := fn [at] () bool {
		return time.ticks() >= at
	}
	sw := time.new_stopwatch()
	mut why := 'dialed'
	dial_stoppable(slow, '192.0.2.1:13400', stop) or { why = err.msg() }
	assert why == stopped_note, why
	assert sw.elapsed().milliseconds() < 500
}

// unstopped, a stoppable client still answers and still times out
fn test_a_stoppable_client_still_works() {
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	spawn fn (mut ln net.TcpListener) {
		mut c := ln.accept() or { return }
		_ := read_message(mut c, 2000) or { return }
		c.write(routing_activation_response(0x0E80, 0x1000, ra_success)) or { return }
		_ := read_message(mut c, 2000) or { return }
		c.write(diagnostic_message(0x1000, 0x0E80, [u8(0x62), 0xF1, 0x90, 0x01])) or { return }
		_ := read_message(mut c, 2000) or { Message{} }
		c.close() or {}
	}(mut ln)
	mut ch := open_doip_stoppable('127.0.0.1', lport, 0x0E80, 0x1000, fn () bool {
		return false
	}) or {
		assert false, 'open: ${err}'
		return
	}
	ch.send([u8(0x22), 0xF1, 0x90]) or { assert false, 'send: ${err}' }
	got := ch.recv(2000) or {
		assert false, 'recv: ${err}'
		return
	}
	assert got == [u8(0x62), 0xF1, 0x90, 0x01]
	t0 := time.ticks()
	if _ := ch.recv(150) {
		assert false, 'nothing more was sent'
	} else {
		assert err.msg() == 'DoIP recv timeout', err.msg()
	}
	assert time.ticks() - t0 >= 140
	ch.close()
	ln.close() or {}
}

// An entity asks whether the connection is alive (0x0007) during routing activation and again
// between its ack and its answer; the client answers each with 0x0008 carrying its own source
// address, and the open and the exchange both complete.
fn test_an_alive_check_inside_an_exchange_is_answered() {
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	heard := chan Message{cap: 4}
	spawn fn (mut ln net.TcpListener, heard chan Message) {
		mut c := ln.accept() or { return }
		_ := read_message(mut c, 2000) or { return }
		c.write(alive_check_request()) or { return }
		heard <- read_message(mut c, 2000) or { Message{} }
		c.write(routing_activation_response(0x0E80, 0x1000, ra_success)) or { return }
		_ := read_message(mut c, 2000) or { return }
		c.write(diagnostic_message_ack(0x1000, 0x0E80, diag_ack_ok)) or { return }
		c.write(alive_check_request()) or { return }
		heard <- read_message(mut c, 2000) or { Message{} }
		c.write(diagnostic_message(0x1000, 0x0E80, [u8(0x62), 0xF1, 0x90, 0x01])) or { return }
		_ := read_message(mut c, 2000) or { Message{} }
		c.close() or {}
	}(mut ln, heard)
	ch := open_doip('127.0.0.1', lport, 0x0E80, 0x1000) or {
		assert false, 'open_doip: ${err}'
		return
	}
	mut cl := uds.new_client(ch)
	got := cl.raw([u8(0x22), 0xF1, 0x90]) or {
		assert false, 'the exchange did not complete: ${err}'
		return
	}
	assert got == [u8(0x62), 0xF1, 0x90, 0x01]
	for when in ['routing activation', 'the exchange'] {
		m := <-heard
		assert m.payload_type == pt_alive_check_response, 'no alive check response during ${when}'
		assert m.payload == [u8(0x0E), 0x80], 'the response does not carry the tester address'
	}
	mut c := ch
	c.close()
	ln.close() or {}
}

// An alive check on an IDLE connection is answered by `idle`, which waits for nothing; a peer
// that closes the idle connection is the connection lost.
fn test_idle_answers_an_alive_check_and_sees_a_close() {
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	heard := chan Message{cap: 2}
	spawn fn (mut ln net.TcpListener, heard chan Message) {
		mut c := ln.accept() or { return }
		_ := read_message(mut c, 2000) or { return }
		c.write(routing_activation_response(0x0E80, 0x1000, ra_success)) or { return }
		time.sleep(100 * time.millisecond)
		c.write(alive_check_request()) or { return }
		heard <- read_message(mut c, 2000) or { Message{} }
		c.close() or {}
	}(mut ln, heard)
	mut ch := open_doip_stoppable('127.0.0.1', lport, 0x0E80, 0x1000, fn () bool {
		return false
	}) or {
		assert false, 'open: ${err}'
		return
	}
	t0 := time.ticks()
	ch.idle() or { assert false, 'idle with nothing arrived: ${err}' }
	assert time.ticks() - t0 < 50, 'idle waited'
	mut lost := ''
	for lost == '' && time.ticks() - t0 < 2000 {
		ch.idle() or { lost = err.msg() }
		time.sleep(20 * time.millisecond)
	}
	m := <-heard
	assert m.payload_type == pt_alive_check_response
	assert m.payload == [u8(0x0E), 0x80]
	assert lost.starts_with(doip_connection_lost), 'the close was not seen: "${lost}"'
	ch.close()
	ln.close() or {}
}

// A peer that sends PART of a message and stalls holds a stoppable recv no longer than a slice
// past the stop — in the header and in the payload alike.
fn test_a_stop_ends_a_read_stalled_mid_message() {
	full := diagnostic_message(0x1000, 0x0E80, [u8(0x62), 0xF1, 0x90, 0x01])
	for cut in [4, header_len + 3] {
		mut ln, lport := free_listener() or {
			assert false, 'listen: ${err}'
			return
		}
		spawn fn (mut ln net.TcpListener, part []u8) {
			mut c := ln.accept() or { return }
			_ := read_message(mut c, 2000) or { return }
			c.write(routing_activation_response(0x0E80, 0x1000, ra_success)) or { return }
			c.write(part) or { return }
			time.sleep(3 * time.second) // the rest never comes
			c.close() or {}
		}(mut ln, full[..cut])
		at := time.ticks() + 150
		mut ch := open_doip_stoppable('127.0.0.1', lport, 0x0E80, 0x1000, fn [at] () bool {
			return time.ticks() >= at
		}) or {
			assert false, 'open: ${err}'
			return
		}
		sw := time.new_stopwatch()
		if _ := ch.recv(4000) {
			assert false, 'a partial message was returned'
		} else {
			assert err.msg() == stopped_note, 'cut ${cut}: ${err.msg()}'
		}
		assert sw.elapsed().milliseconds() < 400, 'cut ${cut}: the stop waited for the stalled read'
		ch.close()
		ln.close() or {}
	}
}

// a denied routing activation reaches the caller as a RoutingDenied, its code named and the
// tester it asked as in the message — through the stoppable open the panel uses
fn test_a_denied_activation_says_its_code_by_name() {
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	spawn fn (mut ln net.TcpListener) {
		mut c := ln.accept() or { return }
		_ := read_message(mut c, 2000) or { return }
		c.write(routing_activation_response(0x0E80, 0x07A0, 0x00)) or { return }
		time.sleep(100 * time.millisecond)
		c.close() or {}
	}(mut ln)
	if _ := open_doip_stoppable('127.0.0.1', lport, 0x0E80, 0x07A0, fn () bool {
		return false
	})
	{
		assert false, 'a denied activation opened'
	} else {
		assert err is RoutingDenied, err.msg()
		if err is RoutingDenied {
			assert err.code == 0x00
			assert err.tester == 0x0E80
		}
		assert err.msg() == 'DoIP: routing activation denied: 0x00 unknown source address — this entity does not accept tester 0x0E80'
	}
	ln.close() or {}
}

// A gateway that routes to a node behind it (ISO 13400-2) may tie what a tester reaches to what
// it unlocked on the gateway over the same connection — so the tester talks to the gateway first
// and then retargets the connection to the node: its requests go to the node's address, and recv
// takes the node's answers (the gateway's own are now another address's).
fn test_a_retargeted_client_talks_to_the_node_behind_the_gateway() {
	mut ln, lport := free_listener() or {
		assert false, 'listen: ${err}'
		return
	}
	spawn fn (mut ln net.TcpListener) {
		mut c := ln.accept() or { return }
		_ := read_message(mut c, 2000) or { return }
		c.write(routing_activation_response(0x0E80, 0x1000, ra_success)) or { return }
		// the gateway's own exchange
		m1 := read_message(mut c, 2000) or { return }
		d1 := parse_diagnostic_message(m1.payload) or { return }
		if d1.target != 0x1000 {
			return
		}
		c.write(diagnostic_message(0x1000, 0x0E80, [u8(0x50), 0x03])) or { return }
		// after the retarget: the request is the node's, and so is the answer recv takes
		m2 := read_message(mut c, 2000) or { return }
		d2 := parse_diagnostic_message(m2.payload) or { return }
		if d2.target != 0x2000 {
			return
		}
		c.write(diagnostic_message(0x1000, 0x0E80, [u8(0x7E), 0x00])) or { return } // the gateway's: not ours now
		c.write(diagnostic_message(0x2000, 0x0E80, [u8(0x62), 0xF1, 0x90, 0x5A])) or { return }
		time.sleep(200 * time.millisecond)
		c.close() or {}
	}(mut ln)
	time.sleep(150 * time.millisecond)

	mut ch := open_doip('127.0.0.1', lport, 0x0E80, 0x1000) or {
		assert false, 'open_doip: ${err}'
		return
	}
	ch.send([u8(0x10), 0x03]) or { assert false, 'send: ${err}' }
	assert ch.recv(2000) or { []u8{} } == [u8(0x50), 0x03]
	assert ch.rx_id == 0x1000
	ch.retarget(0x2000)
	assert ch.rx_id == 0x2000 // the Channel view names the ECU the traffic is now with
	ch.send([u8(0x22), 0xF1, 0x90]) or { assert false, 'send: ${err}' }
	resp := ch.recv(2000) or {
		assert false, 'recv: ${err}'
		return
	}
	assert resp == [u8(0x62), 0xF1, 0x90, 0x5A]
	// a target past 16 bits is no logical address: refused, never narrowed onto another ECU's
	ch.rx_id = 0x12000
	if _ := ch.send([u8(0x3E), 0x00]) {
		assert false, 'an oversized target was sent to'
	}
	ch.close()
	ln.close() or {}
}
