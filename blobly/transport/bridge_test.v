module transport

import net
import time

// A bridge over in-process buses, dialled into this process's listener: the whole path a vcan in
// WSL takes, with `inproc:` standing in for the interface.

fn serve_detached(mut c net.TcpConn, cfg BridgeServeCfg) {
	bridge_serve(mut c, cfg) or {}
	c.close() or {}
}

fn inproc_opener(prefix string) fn (string) !Bus {
	return fn [prefix] (name string) !Bus {
		return open_inproc(prefix + name)!
	}
}

// start_bridge dials the listener as a bridge named `name` and waits for it to be registered.
fn start_bridge(name string, channels []string, opener fn (string) !Bus) ! {
	ep := bridge_listen()!
	mut c := net.dial_tcp('127.0.0.1:${ep.port}')!
	spawn serve_detached(mut c, BridgeServeCfg{
		token:    ep.token
		name:     name
		channels: channels
		opener:   opener
	})
	for _ in 0 .. 300 {
		if _ := bridge_session(name) {
			return
		}
		time.sleep(10 * time.millisecond)
	}
	return error('bridge ${name} never registered')
}

fn wait_gone(name string) {
	for _ in 0 .. 300 {
		if _ := bridge_session(name) {
			time.sleep(10 * time.millisecond)
			continue
		}
		return
	}
	assert false, 'bridge ${name} still registered'
}

fn test_frames_cross_both_ways_with_the_bridge_clock() {
	start_bridge('b-traffic', ['A', 'B'], inproc_opener('bt-'))!
	assert 'b-traffic' in bridge_names()
	rows := bridge_rows().filter(it.iface.starts_with('bridge:b-traffic/'))
	assert rows.map(it.iface) == ['bridge:b-traffic/A', 'bridge:b-traffic/B']

	mut app := open('bridge:b-traffic/A')!
	mut sibling := open('bridge:b-traffic/A')!
	mut peer := open_inproc('bt-A')!
	defer {
		app.close()
		sibling.close()
		peer.close()
	}
	// The bus's frame reaches the app stamped in the bridge's domain.
	peer.send(CanFrame{ id: 0x100, data: [u8(1), 2] })!
	got := app.recv(2000)!
	assert got.id == 0x100 && got.data == [u8(1), 2]
	assert got.hw_domain == bridge_domain('b-traffic')
	assert got.hw_ns > 0
	assert sibling.recv(2000)!.id == 0x100

	// The app's frame reaches the bus; the sending handle does not hear it back, a sibling does.
	app.send(CanFrame{ id: 0x18DAF110, extended: true, fd: true, brs: true, data: []u8{len: 64, init: u8(index)} })!
	out := peer.recv(2000)!
	assert out.id == 0x18DAF110 && out.extended && out.fd && out.brs && out.data.len == 64
	echo := sibling.recv(2000)!
	assert echo.id == 0x18DAF110 && echo.hw_domain == bridge_domain('b-traffic')
	if f := app.recv(200) {
		assert false, 'the sender heard its own frame: ${f}'
	}

	// The second channel is its own wire.
	mut app_b := open('bridge:b-traffic/B')!
	defer {
		app_b.close()
	}
	mut peer_b := open_inproc('bt-B')!
	defer {
		peer_b.close()
	}
	app_b.send(CanFrame{ id: 0x7DF, data: [u8(2), 0x10, 3] })!
	assert peer_b.recv(2000)!.id == 0x7DF
	if f := peer.recv(200) {
		assert false, 'channel A heard channel B: ${f}'
	}
}

fn test_unknown_bridge_and_channel_are_named() {
	start_bridge('b-names', ['vcan0'], inproc_opener('bn-'))!
	open('bridge:nobody/vcan0') or {
		assert err.msg().contains('no bridge named "nobody"')
		open('bridge:b-names/vcan9') or {
			assert err.msg().contains('offers vcan0, not vcan9')
			return
		}
		assert false, 'opened a channel the bridge does not offer'
	}
	assert false, 'opened a bridge that is not connected'
}

fn test_a_channel_the_bridge_cannot_open_is_refused_with_its_reason() {
	failing := fn (name string) !Bus {
		return error('no such device')
	}
	start_bridge('b-noopen', ['can7'], failing)!
	open('bridge:b-noopen/can7') or {
		assert err.msg().contains('cannot open can7: no such device')
		return
	}
	assert false
}

struct RefusingBus {}

fn (mut b RefusingBus) send(frame CanFrame) ! {
	return error('Network is down')
}

fn (mut b RefusingBus) recv(timeout_ms int) !CanFrame {
	time.sleep(timeout_ms * time.millisecond)
	return error('timeout')
}

fn (mut b RefusingBus) close() {}

fn (mut b RefusingBus) health() BusHealth {
	return .bus_off
}

fn (mut b RefusingBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{
		bus_errors: 4
	}
}

fn (mut b RefusingBus) reconcile_silence(want bool) ! {}

fn test_a_send_the_interface_refuses_fails_with_its_reason_and_health_arrives() {
	refusing := fn (name string) !Bus {
		return &RefusingBus{}
	}
	start_bridge('b-refuse', ['can0'], refusing)!
	mut app := open('bridge:b-refuse/can0')!
	defer {
		app.close()
	}
	app.send(CanFrame{ id: 1, data: [u8(1)] }) or {
		assert err.msg().contains('Network is down')
		// The bridge reports the ladder and the counts without anything receiving here.
		for _ in 0 .. 200 {
			if app.health() == .bus_off {
				assert app.diagnostics().bus_errors == 4
				return
			}
			time.sleep(10 * time.millisecond)
		}
		assert false, 'health never arrived'
	}
	assert false, 'a refused send reported success'
}

struct DyingBus {
mut:
	reads int
}

fn (mut b DyingBus) send(frame CanFrame) ! {}

fn (mut b DyingBus) recv(timeout_ms int) !CanFrame {
	b.reads++
	if b.reads > 2 {
		return error('recv on can0: No such device')
	}
	time.sleep(timeout_ms * time.millisecond)
	return error('timeout')
}

fn (mut b DyingBus) close() {}

fn (mut b DyingBus) health() BusHealth {
	return .unknown
}

fn (mut b DyingBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

fn (mut b DyingBus) reconcile_silence(want bool) ! {}

fn test_a_channel_that_fails_on_the_bridge_fails_here() {
	dying := fn (name string) !Bus {
		return &DyingBus{}
	}
	start_bridge('b-dying', ['can0'], dying)!
	mut app := open('bridge:b-dying/can0')!
	defer {
		app.close()
	}
	for _ in 0 .. 50 {
		app.recv(100) or {
			if err.msg() == 'timeout' {
				continue
			}
			assert err.msg().contains('No such device')
			return
		}
	}
	assert false, 'the failure never arrived'
}

fn test_a_disconnected_bridge_fails_its_channels_and_may_return() {
	start_bridge('b-drop', ['A'], inproc_opener('bd-'))!
	mut app := open('bridge:b-drop/A')!
	defer {
		app.close()
	}
	bridge_drop('b-drop')
	wait_gone('b-drop')
	app.recv(500) or { assert err.msg().contains('bridge "b-drop"') }
	app.send(CanFrame{ id: 1 }) or { assert err.msg().contains('bridge "b-drop"') }
	// The name is free again once the session has ended.
	start_bridge('b-drop', ['A'], inproc_opener('bd-'))!
}

fn test_a_wrong_token_or_a_name_in_use_is_turned_away() {
	start_bridge('b-taken', ['A'], inproc_opener('bk-'))!
	ep := bridge_listen()!
	for hello in [bridge_encode_hello('not-the-token', 'b-intruder', ['A']),
		bridge_encode_hello(ep.token, 'b-taken', ['A'])] {
		mut c := net.dial_tcp('127.0.0.1:${ep.port}')!
		c.write(hello)!
		c.set_read_timeout(2 * time.second)
		mut buf := []u8{len: 16}
		// The listener closes the connection unheard.
		if n := c.read(mut buf) {
			assert false, 'read ${n} bytes from a refused connection'
		}
		c.close() or {}
	}
	assert 'b-intruder' !in bridge_names()
	assert bridge_names().filter(it == 'b-taken').len == 1
}
