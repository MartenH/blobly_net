module transport

import io
import net
import os
import time

// A listener bound to every address with a fixed token, as BLOBLY_BRIDGE_LISTEN asks for one: a
// file of its own, since the listener is process-wide and starts once.

const fixed_token = 'lan-token-0123456789'

fn lan_serve(mut c net.TcpConn, cfg BridgeServeCfg) {
	bridge_serve(mut c, cfg) or {}
	c.close() or {}
}

fn handshakes() int {
	return rlock bridge_reg {
		bridge_reg.handshakes
	}
}

fn lan_listener() !BridgeEndpoint {
	return bridge_listen_on(BridgeListenCfg{
		host:       '0.0.0.0'
		token:      fixed_token
		configured: true
	})
}

fn test_a_bad_setting_is_refused_at_startup() {
	os.setenv(bridge_listen_env, 'board:29500', true)
	defer {
		os.unsetenv(bridge_listen_env)
	}
	bridge_listen_configured() or {
		assert err.msg().contains('numeric')
		// nothing was started
		if _ := bridge_listening() {
			assert false, 'a listener started'
		}
		return
	}
	assert false
}

fn test_unset_starts_nothing_at_startup() {
	os.unsetenv(bridge_listen_env)
	os.unsetenv(bridge_token_env)
	assert bridge_listen_configured()! == ''
	if _ := bridge_listening() {
		assert false, 'a listener started'
	}
}

fn test_a_bridge_dials_in_with_the_fixed_token() {
	ep := lan_listener()!
	assert ep.host == '127.0.0.1' && ep.token == fixed_token && ep.port > 0
	// the listener is the one a later bridge_listen finds, whatever the settings say now
	again := bridge_listen()!
	assert again == ep

	// the wrong token is told so
	mut bad := net.dial_tcp('127.0.0.1:${ep.port}')!
	bad.write(bridge_encode_hello('lan-token-0123456780', 'intruder', ['can0'], ''))!
	bad.set_read_timeout(3 * time.second)
	mut dec := BridgeDecoder{}
	mut buf := []u8{len: 4096}
	n := bad.read(mut buf)!
	recs := dec.feed(buf[..n])!
	assert recs.len == 1 && recs[0].kind == .refused && recs[0].error == 'wrong token'
	bad.close() or {}
	assert 'intruder' !in bridge_names()

	mut c := net.dial_tcp('127.0.0.1:${ep.port}')!
	spawn lan_serve(mut c, BridgeServeCfg{
		token:    fixed_token
		name:     'board'
		channels: ['can0']
		opener:   fn (name string) !Bus {
			return open_inproc('lan-' + name)!
		}
	})
	for _ in 0 .. 300 {
		if 'board' in bridge_names() {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert bridge_channels('board') == ['can0']
	mut app := open('bridge:board/can0')!
	mut peer := open_inproc('lan-can0')!
	defer {
		app.close()
		peer.close()
		bridge_drop('board')
	}
	peer.send(CanFrame{ id: 0x123, data: [u8(1)] })!
	f := app.recv(2000)!
	assert f.id == 0x123 && f.data == [u8(1)]
}

fn test_connections_that_never_say_hello_are_capped() {
	ep := lan_listener()!
	mut idle := []&net.TcpConn{}
	for _ in 0 .. bridge_max_handshakes {
		idle << net.dial_tcp('127.0.0.1:${ep.port}')!
	}
	// every one has been accepted before the next is dialled
	for _ in 0 .. 300 {
		if handshakes() == bridge_max_handshakes {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert handshakes() == bridge_max_handshakes
	// one more is closed as it is accepted, well before a hello would time out
	mut extra := net.dial_tcp('127.0.0.1:${ep.port}')!
	extra.set_read_timeout(2 * time.second)
	mut buf := []u8{len: 16}
	if _ := extra.read(mut buf) {
		assert false, 'the extra connection was sent something'
	} else {
		assert err is io.Eof || !bridge_is_timeout(err), 'the extra connection was left open'
	}
	extra.close() or {}
	// the silent ones going away frees their places
	for mut c in idle {
		c.close() or {}
	}
	for _ in 0 .. 300 {
		if handshakes() == 0 {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert handshakes() == 0
}

// hello_with is a hello from a bridge of another version, offering channels of other buses.
fn hello_with(newest u16, oldest u16, name string, chans []string, buses []u8) []u8 {
	mut b := [u8(BridgeKind.hello)]
	bridge_put_u16(mut b, newest)
	bridge_put_u16(mut b, oldest)
	bridge_put_str(mut b, fixed_token)
	bridge_put_str(mut b, name)
	b << u8(chans.len)
	for k, c in chans {
		mut e := []u8{}
		bridge_put_str(mut e, c)
		e << buses[k]
		bridge_put_u16(mut b, u16(e.len))
		b << e
	}
	bridge_put_str(mut b, '')
	return bridge_wrap(b)
}

// first_answer is the first record the app sends a connection that said `hello`.
fn first_answer(port int, hello []u8) !(&net.TcpConn, BridgeRecord) {
	mut c := net.dial_tcp('127.0.0.1:${port}')!
	c.write(hello)!
	c.set_read_timeout(3 * time.second)
	mut dec := BridgeDecoder{}
	mut buf := []u8{len: 4096}
	for {
		n := c.read(mut buf)!
		recs := dec.feed(buf[..n])!
		if recs.len > 0 {
			return c, recs[0]
		}
	}
	return error('unreachable')
}

fn test_a_newer_bridge_is_welcomed_in_this_version_and_its_other_buses_are_not_opened() {
	ep := lan_listener()!
	mut c, rec := first_answer(ep.port, hello_with(5, 3, 'mixed', ['can0', 'lin0'], [bridge_bus_can, 2]))!
	defer {
		c.close() or {}
	}
	assert rec.kind == .welcome && rec.version == bridge_version
	for _ in 0 .. 300 {
		if 'mixed' in bridge_names() {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert bridge_channels('mixed') == ['can0']
	assert bridge_rows().filter(it.iface.starts_with('bridge:mixed/')).map(it.iface) == [
		'bridge:mixed/can0',
	]
	open('bridge:mixed/lin0') or {
		assert err.msg().contains('not CAN')
		return
	}
	assert false, 'a LIN channel opened'
}

fn test_a_bridge_that_does_not_speak_this_version_is_told_so() {
	ep := lan_listener()!
	mut c, rec := first_answer(ep.port, hello_with(5, 4, 'future', ['can0'], [bridge_bus_can]))!
	c.close() or {}
	assert rec.kind == .refused
	assert rec.error == 'protocol version 4 to 5; this app speaks ${bridge_version}'
	assert 'future' !in bridge_names()
}

fn test_a_second_listener_on_the_port_is_refused() {
	ep := lan_listener()!
	bridge_bind('0.0.0.0', ep.port) or {
		assert err.msg().contains('cannot listen on 0.0.0.0:${ep.port}')
		return
	}
	assert false, 'a second listener took the port'
}

fn test_a_bridge_on_the_lan_that_dials_in_after_the_open_began_is_waited_for() {
	ep := lan_listener()!
	spawn fn [ep] () {
		time.sleep(300 * time.millisecond)
		mut c := net.dial_tcp('127.0.0.1:${ep.port}') or { return }
		lan_serve(mut c, BridgeServeCfg{
			token:    fixed_token
			name:     'late'
			channels: ['can0']
			opener:   fn (name string) !Bus {
				return open_inproc('late-' + name)!
			}
		})
	}()
	mut b := open('bridge:late/can0')!
	b.close()
	bridge_drop('late')
}

fn test_a_bridge_on_the_lan_that_cannot_start_says_why_to_the_open_waiting_for_it() {
	ep := lan_listener()!
	spawn fn [ep] () {
		time.sleep(200 * time.millisecond)
		mut c := net.dial_tcp('127.0.0.1:${ep.port}') or { return }
		bridge_report_failure(mut c, fixed_token, 'broken', 'interface can0 is down') or {}
		c.close() or {}
	}()
	t0 := time.ticks()
	open('bridge:broken/can0') or {
		assert err.msg().contains('interface can0 is down')
		assert time.ticks() - t0 < 5000
		return
	}
	assert false, 'a bridge that could not start opened'
}

fn test_a_bridge_opens_nothing_before_the_welcome() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	port := l.addr()!.port()!
	done := chan string{cap: 1}
	spawn fn [port, done] () {
		mut c := net.dial_tcp('127.0.0.1:${port}') or {
			done <- err.msg()
			return
		}
		bridge_serve(mut c, BridgeServeCfg{
			token:    't'
			name:     'eager'
			channels: ['can0']
			opener:   fn (name string) !Bus {
				return open_inproc('eager-' + name)!
			}
		}) or {
			done <- err.msg()
			return
		}
		done <- ''
	}()
	mut app := l.accept()!
	app.write(bridge_encode_open(0, 1))!
	select {
		why := <-done {
			assert why.contains('before its welcome')
		}
		3 * time.second {
			assert false, 'the bridge kept a connection that opened a channel before its welcome'
		}
	}
	app.close() or {}
	l.close() or {}
}
