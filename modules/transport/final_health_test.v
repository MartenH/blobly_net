module transport

struct HealthReplyBus {
mut:
	reads      int
	state      BusHealth = .ok
	failed     bool
	continuous bool
}

fn (mut b HealthReplyBus) send(frame CanFrame) ! {}

fn (mut b HealthReplyBus) close() {}

fn (mut b HealthReplyBus) reconcile_silence(want bool) ! {}

fn (mut b HealthReplyBus) health() BusHealth {
	return b.state
}

fn (mut b HealthReplyBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{ bus_errors: if b.reads > 0 { u64(1) } else { 0 } }
}

fn (mut b HealthReplyBus) recv(timeout_ms int) !CanFrame {
	assert timeout_ms > 0 && timeout_ms <= 1000
	if b.failed {
		return error('disconnected')
	}
	b.reads++
	b.state = .bus_off // the asynchronous status arrives through the receive decoder
	if !b.continuous && b.reads > 1 {
		return error('timeout')
	}
	return CanFrame{ id: 1 }
}

fn test_final_drain_consumes_the_reply_and_keeps_decoder_diagnostics() {
	mut raw := &HealthReplyBus{}
	mut bus := Bus(raw)
	drain_health_reply(mut bus, 1000)!
	assert raw.reads == 2
	assert bus.health() == .bus_off
	assert bus.diagnostics().bus_errors == 1
}

fn test_final_drain_is_bounded_on_a_continuously_busy_wire() {
	mut raw := &HealthReplyBus{ continuous: true }
	mut bus := Bus(raw)
	drain_health_reply(mut bus, 5)!
	assert raw.reads > 0
}

fn test_final_drain_propagates_a_hard_receive_error() {
	mut bus := Bus(&HealthReplyBus{ failed: true })
	if _ := drain_health_reply(mut bus, 1000) {
		assert false
	} else {
		assert err.msg() == 'disconnected'
	}
}
