module script

import blobly.transport

fn test_an_address_is_a_channel_the_bus_primitives_take() {
	mut peer := transport.open('inproc:SCRIPT_IFACE')!
	defer {
		peer.close()
	}
	mut env := new_env([
		ChanInfo{
			name:    'CAN1'
			iface:   'inproc:SCRIPT_IFACE_ROW'
			nominal: 250000
		},
	])!
	env.on_output = fn (_ string) {}
	defer {
		env.close()
	}
	env.run_source('
		test("send and load on an address", function()
			local a = bus.open_iface("inproc:SCRIPT_IFACE")
			bus.send(a, 0x321, "\\170")
			check.equal(bus.load(a).nominal, 500000)
			check.equal(bus.load(bus.open_iface("inproc:SCRIPT_IFACE_ROW")).nominal, 250000)
		end)
		test("a project channel name is not an address", function()
			check.truthy(not pcall(bus.open_iface, "CAN1"))
			check.truthy(not pcall(bus.open_iface, "someip:0.0.0.0:30490"))
		end)
	')!
	assert env.passed() == 2, env.results.str()
	f := peer.recv(1000)!
	assert f.id == 0x321 && f.data == [u8(0xAA)]
}
