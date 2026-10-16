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
	assert got.hw_domain.starts_with('bridge:b-traffic#')
	assert got.hw_ns > 0
	assert sibling.recv(2000)!.id == 0x100

	// The app's frame reaches the bus; the sending handle does not hear it back, a sibling does.
	app.send(CanFrame{ id: 0x18DAF110, extended: true, fd: true, brs: true, data: []u8{len: 64, init: u8(index)} })!
	out := peer.recv(2000)!
	assert out.id == 0x18DAF110 && out.extended && out.fd && out.brs && out.data.len == 64
	echo := sibling.recv(2000)!
	assert echo.id == 0x18DAF110 && echo.hw_domain == got.hw_domain
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

fn (mut b RefusingBus) send(_ CanFrame) ! {
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

fn (mut b RefusingBus) reconcile_silence(_ bool) ! {}

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

fn (mut b DyingBus) send(_ CanFrame) ! {}

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

fn (mut b DyingBus) reconcile_silence(_ bool) ! {}

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
	for hello in [bridge_encode_hello('not-the-token', 'b-intruder', ['A'], ''),
		bridge_encode_hello(ep.token, 'bad/name', ['A'], '')] {
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

fn (mut b BlankErrorBus) send(_ CanFrame) ! {
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

fn (mut b BlankErrorBus) reconcile_silence(_ bool) ! {}

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
	// Several sends, none of their acknowledgements consumed before the next: all are kept, in
	// order, behind the frames already queued.
	commit := fn () {}
	for i in 0 .. 3 {
		drv.send(CanFrame{ id: 0x7E0, data: [u8(i)] }, commit)!
	}
	mut acks := []u8{}
	for {
		got := drv.recv_shared(0) or { break }
		if got.tx_ack && got.frame.id == 0x7E0 {
			acks << got.frame.data[0]
		}
	}
	assert acks == [u8(0), 1, 2], 'acknowledgements lost or reordered: ${acks}'
	assert drv.diagnostics().dropped > 0
}

fn test_records_from_a_previous_open_of_a_channel_are_dropped() {
	start_bridge('b-reopen', ['A'], inproc_opener('bro-'))!
	mut s := bridge_session('b-reopen') or { panic('not registered') }
	mut c := &BridgeChan{
		gen:     7
		rx:      chan SharedIngress{cap: 8}
		results: chan BridgeResult{cap: 8}
		opened:  chan string{cap: 1}
	}
	lock s.st {
		s.st.chans[0] = c
	}
	// The previous open's (gen 6) records still in the stream, interleaved with this open's —
	// whose pump may well write before its `opened` answer does.
	s.dispatch(BridgeRecord{ kind: .frame, gen: 6, frame: CanFrame{ id: 0x111 } })!
	s.dispatch(BridgeRecord{ kind: .frame, gen: 7, frame: CanFrame{ id: 0x222 } })!
	s.dispatch(BridgeRecord{ kind: .lost, gen: 6, error: 'old pump failed' })!
	s.dispatch(BridgeRecord{ kind: .status, gen: 6, health: .bus_off })!
	s.dispatch(BridgeRecord{ kind: .opened, gen: 6 })!
	s.dispatch(BridgeRecord{ kind: .opened, gen: 7 })!
	s.dispatch(BridgeRecord{ kind: .frame, gen: 7, frame: CanFrame{ id: 0x333 } })!
	assert c.rx.len == 2
	assert (<-c.rx).frame.id == 0x222
	assert (<-c.rx).frame.id == 0x333
	assert c.opened.len == 1
	st := rlock c.st {
		c.st
	}
	assert !st.lost && st.health == .unknown
	s.forget(0, c)
}

fn test_each_session_is_its_own_clock_domain() {
	assert bridge_domain('x', 1) != bridge_domain('x', 2)
}

struct EchoingBus {
mut:
	replies chan CanFrame
}

fn (mut b EchoingBus) send(frame CanFrame) ! {
	// An ECU that answers at once: the reply is ready before send returns.
	b.replies <- CanFrame{
		id:   frame.id + 8
		data: [u8(0x50)]
	}
}

fn (mut b EchoingBus) recv(timeout_ms int) !CanFrame {
	select {
		f := <-b.replies {
			return f
		}
		timeout_ms * time.millisecond {}
	}
	return error('timeout')
}

fn (mut b EchoingBus) close() {}

fn (mut b EchoingBus) health() BusHealth {
	return .unknown
}

fn (mut b EchoingBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

fn (mut b EchoingBus) reconcile_silence(_ bool) ! {}

fn test_a_reply_never_overtakes_the_acknowledgement_of_its_request() {
	echoing := fn (name string) !Bus {
		return &EchoingBus{
			replies: chan CanFrame{cap: 4}
		}
	}
	start_bridge('b-order', ['A'], echoing)!
	mut drv := open_bridge_bus('bridge:b-order/A')!
	defer {
		drv.close()
	}
	commit := fn () {}
	for _ in 0 .. 20 {
		drv.send(CanFrame{ id: 0x7E0, data: [u8(0x10)] }, commit)!
		first := drv.recv_shared(1000)!
		second := drv.recv_shared(1000)!
		assert first.tx_ack && first.frame.id == 0x7E0, 'the reply came first'
		assert !second.tx_ack && second.frame.id == 0x7E8
	}
}

fn test_only_a_certain_refusal_is_not_written() {
	refusing := fn (name string) !Bus {
		return &RefusingBus{}
	}
	// A SocketCAN interface takes a frame whole or not at all; another backend's failed write may
	// have reached the wire, so the hub must keep the send matchable.
	start_bridge('b-maybe', ['can0', 'net:A'], refusing)!
	mut sure := open('bridge:b-maybe/can0')!
	mut maybe := open('bridge:b-maybe/net:A')!
	defer {
		sure.close()
		maybe.close()
	}
	if _ := sure.send(CanFrame{ id: 1, data: [u8(1)] }) {
		assert false
	} else {
		assert err is NotWritten, err.msg()
	}
	if _ := maybe.send(CanFrame{ id: 1, data: [u8(1)] }) {
		assert false
	} else {
		assert err !is NotWritten, err.msg()
		assert err.msg().contains('Network is down')
	}
}

struct HoldingBus {
mut:
	calls int
}

fn (mut b HoldingBus) send(_ CanFrame) ! {}

// recv returns one frame, then stalls in the next look, so that frame is held as pending while a
// send arrives; afterwards the bus is idle.
fn (mut b HoldingBus) recv(timeout_ms int) !CanFrame {
	b.calls++
	if b.calls == 1 {
		return CanFrame{
			id:   0x111
			data: [u8(1)]
		}
	}
	if b.calls == 2 {
		time.sleep(400 * time.millisecond)
	} else {
		time.sleep(timeout_ms * time.millisecond)
	}
	return error('timeout')
}

fn (mut b HoldingBus) close() {}

fn (mut b HoldingBus) health() BusHealth {
	return .unknown
}

fn (mut b HoldingBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

fn (mut b HoldingBus) reconcile_silence(_ bool) ! {}

fn test_a_frame_received_before_a_send_comes_before_its_acknowledgement() {
	holding := fn (name string) !Bus {
		return &HoldingBus{}
	}
	start_bridge('b-pending', ['A'], holding)!
	mut drv := open_bridge_bus('bridge:b-pending/A')!
	defer {
		drv.close()
	}
	// The pump has taken 0x111 and is stalled before writing it.
	time.sleep(100 * time.millisecond)
	commit := fn () {}
	drv.send(CanFrame{ id: 0x7E0, data: [u8(2)] }, commit)!
	first := drv.recv_shared(1000)!
	second := drv.recv_shared(1000)!
	assert !first.tx_ack && first.frame.id == 0x111, 'the earlier frame came after the acknowledgement'
	assert second.tx_ack && second.frame.id == 0x7E0
}

fn test_a_bridge_that_cannot_start_says_why_and_a_forged_failure_is_ignored() {
	ep := bridge_listen()!
	mut forged := net.dial_tcp('127.0.0.1:${ep.port}')!
	bridge_report_failure(mut forged, 'not-the-token', 'b-cannot', 'forged')!
	forged.close() or {}
	mut c := net.dial_tcp('127.0.0.1:${ep.port}')!
	bridge_report_failure(mut c, ep.token, 'b-cannot', 'cannot create vcan0: no vcan module')!
	c.close() or {}
	for _ in 0 .. 300 {
		st, why := bridge_state('b-cannot')
		if st == .failed {
			assert why == 'cannot create vcan0: no vcan module'
			assert 'b-cannot' !in bridge_names()
			return
		}
		time.sleep(10 * time.millisecond)
	}
	assert false, 'the failure was never recorded'
}

fn test_bridge_states_and_a_name_that_is_not_a_wsl_distribution() {
	st, _ := bridge_state('b-nobody')
	assert st == .idle
	open('bridge:b-nobody/vcan0') or {
		assert err.msg().contains('no bridge named "b-nobody" is connected'), err.msg()
		start_bridge('b-state', ['A'], inproc_opener('bs-'))!
		st2, _ := bridge_state('b-state')
		assert st2 == .connected
		return
	}
	assert false
}

fn test_launch_arguments() {
	args := bridge_launch_args('Ubuntu-24.04', BridgeEndpoint{ port: 4321, token: 'abc' })
	assert args == ['--vcan', '2', '--connect', '127.0.0.1:4321', '--token', 'abc', '--name',
		'Ubuntu-24.04']
}

fn test_an_address_no_bridge_could_answer_is_refused_in_the_editor() {
	assert bridge_address_error('bridge:Ubuntu-24.04/vcan0') == none
	for bad in ['bridge:a/b/vcan0', 'bridge:${'x'.repeat(bridge_max_label + 1)}/vcan0', 'bridge:x',
		'bridge:x/vcan0@500000'] {
		assert bridge_address_error(bad) != none, bad
	}
}
