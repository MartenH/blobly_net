module transport

// An unopened bus refuses everything, and says a send went nowhere.
fn test_an_unopened_bus_refuses() {
	mut b := Bus(UnopenedBus{})
	b.send(CanFrame{ id: 0x100 }) or { assert err is NotWritten }
	if _ := b.recv(0) {
		assert false, 'an unopened bus received a frame'
	}
	if _ := b.reconcile_silence(true) {
		assert false, 'an unopened bus accepted a mode'
	}
	assert b.health() == .unknown
	assert b.diagnostics() == BusDiagnostics{}
	b.close()
}
