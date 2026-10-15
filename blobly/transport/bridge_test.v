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
	if f := app.recv(500) {
		assert false, 'received ${f} from a dropped bridge'
	} else {
		assert err.msg().contains('bridge "b-drop"'), err.msg()
	}
	if _ := app.send(CanFrame{ id: 1 }) {
		assert false, 'sent on a dropped bridge'
	} else {
		assert err.msg().contains('bridge "b-drop"'), err.msg()
	}
	// The name is free again once the session has ended.
	start_bridge('b-drop', ['A'], inproc_opener('bd-'))!
}

fn test_a_refused_bridge_is_told_why() {
	ep := bridge_listen()!
	for hello in [bridge_encode_hello('not-the-token', 'b-intruder', ['A']),
		bridge_encode_hello(ep.token, 'bad/name', ['A'])] {
		mut c := net.dial_tcp('127.0.0.1:${ep.port}')!
		c.write(hello)!
		c.set_read_timeout(2 * time.second)
		mut dec := BridgeDecoder{}
		mut buf := []u8{len: 256}
		recs := bridge_read(mut c, mut dec, mut buf)!
		assert recs.len == 1 && recs[0].kind == .refused
		assert recs[0].error.contains('wrong token') || recs[0].error.contains('bad/name')
		c.close() or {}
	}
	assert 'b-intruder' !in bridge_names()
	// The bridge's own side ends with the reason rather than as a clean shutdown.
	mut c := net.dial_tcp('127.0.0.1:${ep.port}')!
	if _ := bridge_serve(mut c, BridgeServeCfg{
		token:    'wrong'
		name:     'b-refused'
		channels: ['A']
		opener:   inproc_opener('br-')
	})
	{
		assert false, 'a refused bridge served cleanly'
	} else {
		assert err.msg().contains('the app refused this bridge: wrong token'), err.msg()
	}
	c.close() or {}
}

fn test_a_bridge_dialling_in_again_replaces_its_stale_session() {
	start_bridge('b-again', ['A'], inproc_opener('ba-'))!
	mut old := open('bridge:b-again/A')!
	defer {
		old.close()
	}
	first := bridge_session('b-again') or { panic('not registered') }
	// The same bridge again, as after its host went away without closing the connection.
	ep := bridge_listen()!
	mut c := net.dial_tcp('127.0.0.1:${ep.port}')!
	spawn serve_detached(mut c, BridgeServeCfg{
		token:    ep.token
		name:     'b-again'
		channels: ['A']
		opener:   inproc_opener('ba-')
	})
	for _ in 0 .. 300 {
		if s := bridge_session('b-again') {
			if voidptr(s) != voidptr(first) {
				break
			}
		}
		time.sleep(10 * time.millisecond)
	}
	second := bridge_session('b-again') or { panic('the new session is not registered') }
	assert voidptr(second) != voidptr(first)
	// The old session's channel fails with the reason; the new one opens.
	mut why := ''
	for _ in 0 .. 50 {
		old.recv(100) or {
			if err.msg() == 'timeout' {
				continue
			}
			why = err.msg()
			break
		}
	}
	assert why.contains('replaced by a new connection'), why
	mut fresh := open('bridge:b-again/A')!
	fresh.close()
}

struct BlankErrorBus {}

fn (mut b BlankErrorBus) send(frame CanFrame) ! {
	return error('')
}

fn (mut b BlankErrorBus) recv(timeout_ms int) !CanFrame {
	time.sleep(timeout_ms * time.millisecond)
	return error('timeout')
}

fn (mut b BlankErrorBus) close() {}

fn (mut b BlankErrorBus) health() BusHealth {
	return .unknown
}

fn (mut b BlankErrorBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

fn (mut b BlankErrorBus) reconcile_silence(want bool) ! {}

fn test_refusals_are_not_written_and_never_look_like_success() {
	// A frame no interface could carry is refused here, never clamped on the bridge's side.
	start_bridge('b-shape', ['A'], inproc_opener('bsh-'))!
	mut app := open('bridge:b-shape/A')!
	defer {
		app.close()
	}
	if _ := app.send(CanFrame{ id: 1, data: []u8{len: 9} }) {
		assert false, 'a 9-byte classic frame was sent'
	} else {
		assert err is NotWritten, err.msg()
	}
	// A frame the interface refuses is not written either, even with an empty reason.
	blank := fn (name string) !Bus {
		return &BlankErrorBus{}
	}
	start_bridge('b-blank', ['A'], blank)!
	mut b := open('bridge:b-blank/A')!
	defer {
		b.close()
	}
	if _ := b.send(CanFrame{ id: 1, data: [u8(1)] }) {
		assert false, 'a refused send reported success'
	} else {
		assert err is NotWritten, err.msg()
		assert err.msg().contains('the interface refused the frame'), err.msg()
	}
}

fn test_a_stalled_write_ends_the_session() {
	start_bridge('b-stall', ['A'], inproc_opener('bst-'))!
	mut app := open('bridge:b-stall/A')!
	defer {
		app.close()
	}
	mut s := bridge_session('b-stall') or { panic('not registered') }
	// As if a write had been blocked for three seconds, on a bridge that stopped reading.
	lock s.st {
		s.st.writing_since = time.ticks() - 3000
	}
	s.check_stall()
	wait_gone('b-stall')
	if _ := app.recv(500) {
		assert false
	} else {
		assert err.msg().contains('stalled'), err.msg()
	}
}

fn test_labels_must_be_addressable() {
	assert bridge_label_error('Ubuntu-24.04', ['vcan0', 'can0']) == none
	for name in ['', 'a/b', 'a@b', 'x'.repeat(bridge_max_label + 1)] {
		assert bridge_label_error(name, ['vcan0']) != none, name
	}
	for chans in [[''], ['A/B'], ['A@B'], ['vcan0', 'vcan0']] {
		assert bridge_label_error('n', chans) != none, chans.str()
	}
	// The bridge refuses to offer what cannot be addressed, before it says hello.
	ep := bridge_listen()!
	mut c := net.dial_tcp('127.0.0.1:${ep.port}')!
	if _ := bridge_serve(mut c, BridgeServeCfg{
		token:    ep.token
		name:     'b-label'
		channels: ['net/A']
		opener:   inproc_opener('bl-')
	})
	{
		assert false
	} else {
		assert err.msg().contains('"net/A"'), err.msg()
	}
	c.close() or {}
}

fn test_a_bridge_frame_is_not_normalised_on_the_way_out() {
	// The driver refuses what no controller could send, so nothing upstream may clamp it first.
	assert !clamps_to_classic('bridge:x/vcan0')
	f := CanFrame{
		id:   0x800
		data: []u8{len: 9}
	}
	assert wire_frame('bridge:x/vcan0', f) == f
}

fn test_an_acknowledgement_survives_a_full_receive_queue() {
	start_bridge('b-full', ['A'], inproc_opener('bf-'))!
	mut drv := open_bridge_bus('bridge:b-full/A')!
	defer {
		drv.close()
	}
	mut b := drv as BridgeBus
	// Nothing reads the queue: fill it from the bus, then send.
	mut peer := open_inproc('bf-A')!
	defer {
		peer.close()
	}
	for i in 0 .. bridge_queue_cap + 10 {
		peer.send(CanFrame{ id: 0x100, data: [u8(i)] })!
	}
	for _ in 0 .. 300 {
		if b.c.rx.len >= bridge_queue_cap {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	assert b.c.rx.len == bridge_queue_cap
	commit := fn () {}
	drv.send(CanFrame{ id: 0x7E0, data: [u8(2)] }, commit)!
	mut acked := false
	for {
		got := drv.recv_shared(0) or { break }
		if got.tx_ack && got.frame.id == 0x7E0 {
			acked = true
		}
	}
	assert acked, 'the acknowledgement was dropped'
	assert drv.diagnostics().dropped > 0
}
