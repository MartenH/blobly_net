// Interfaces from a script: a bus opened by its address with no project row (bus.open_iface),
// the interfaces present (bus.interfaces, bus.discover_cansub) and Vector application-channel
// assignment (vector.*), each over blobly.transport's own rule.
module script

import blobly.lua
import blobly.project
import blobly.transport

fn (mut env Env) register_ifaces() {
	env.st.register('__bus_open_iface', l_bus_open_iface)
	env.st.register('__interfaces', l_interfaces)
	env.st.register('__discover_cansub', l_discover_cansub)
	env.st.register('__vector_driver', l_vector_driver)
	env.st.register('__vector_assignments', l_vector_assignments)
	env.st.register('__vector_slot', l_vector_slot)
	env.st.register('__vector_assign', l_vector_assign)
}

// rates_for is what a bus on `address` is priced at: the rates of a CAN channel of the script on
// that wire (the project's first enabled row's), else the address's own.
fn (env &Env) rates_for(address string) (int, int) {
	key := transport.wire_key(address)
	for c in env.chans {
		if c.carrier.eth_kind() == none && c.nominal > 0 && transport.wire_key(c.iface) == key {
			return c.nominal, c.data_rate
		}
	}
	return project.address_rates(address)
}

// open_iface makes `address` a channel of the script, named by the address, and opens its bus:
// every bus.* primitive, run()'s handlers and uds.open then take it as they take a row's name.
// Opened once; a project channel of that name is refused, since the name would be two channels.
fn (mut env Env) open_iface(address string) !string {
	if address == '' {
		return error('bus.open_iface: no address')
	}
	if address.contains_u8(0) {
		// a C string would end there and reach another wire than the one the policy is asked about
		return error('bus.open_iface: an address has no NUL')
	}
	if project.iface_is_eth(address) {
		return error('bus.open_iface: ${address} is a DoIP or SOME/IP endpoint, which carries no CAN frames')
	}
	if address in env.by_address {
		return address
	}
	if env.chans.any(it.name == address) {
		return error('bus.open_iface: "${address}" is the name of a channel of the project; use that channel')
	}
	nominal, data := env.rates_for(address)
	env.chans << ChanInfo{
		name:      address
		iface:     address
		key_iface: if transport.vendor_iface(address) { address.all_before('@') } else { address }
		nominal:   nominal
		data_rate: data
	}
	env.by_address[address] = true
	env.bus_for(address) or {
		env.chans.pop()
		env.by_address.delete(address)
		return error('bus.open_iface: ${address}: ${err.msg()}')
	}
	return address
}

// __bus_open_iface(address) -> the channel name it is reached by (the address)
fn l_bus_open_iface(l lua.State) i32 {
	mut env := env_of(l)
	name := env.open_iface(l.arg_str(1)) or { return l.fail(err.msg()) }
	l.push_str(name)
	return 1
}

// push_interfaces leaves a list of interface rows on the stack.
fn push_interfaces(l lua.State, rows []transport.Interface) {
	l.new_table()
	for i, f in rows {
		l.new_table()
		l.set_str('address', f.address)
		l.set_str('kind', f.kind)
		l.set_str('description', f.desc)
		match f.fd {
			.yes { l.set_bool('fd', true) }
			.no { l.set_bool('fd', false) }
			.unknown {}
		}
		l.set_int('bitrate', f.bitrate)
		l.set_bool('virtual', f.virtual)
		l.set_str('state', f.state)
		l.set_index(i + 1)
	}
}

// __interfaces() -> every interface known without a network wait
fn l_interfaces(l lua.State) i32 {
	push_interfaces(l, transport.interfaces())
	return 1
}

// __discover_cansub(window_ms) -> the CANsub channels an mDNS browse found, and its note
fn l_discover_cansub(l lua.State) i32 {
	env := env_of(l)
	asked := l.arg_int(1)
	if asked < 1 || asked > transport.cansub_window_max_ms {
		return l.fail('bus.discover_cansub: a window is 1 to ${transport.cansub_window_max_ms} ms, not ${asked}')
	}
	window := env.bounded_window(asked)
	if env.expired() {
		return timeout_at(l)
	}
	rows, note := transport.discover_cansub_within(int(window)) or {
		if env.expired() {
			return timeout_at(l)
		}
		return l.fail('bus.discover_cansub: ${err.msg()}')
	}
	if env.expired() {
		return timeout_at(l)
	}
	push_interfaces(l, rows)
	l.push_str(note)
	return 2
}

// __vector_driver() -> why the Vector driver cannot be used, '' when it can
fn l_vector_driver(l lua.State) i32 {
	l.push_str(transport.vector_driver_refusal() or { '' })
	return 1
}

// __vector_assignments() -> every physical channel the driver lists, with its application channel
fn l_vector_assignments(l lua.State) i32 {
	l.new_table()
	if _ := transport.vector_driver_refusal() {
		return 1
	}
	for i, m in transport.vector_mappings() {
		l.new_table()
		l.set_str('name', m.hw.name)
		l.set_str('transceiver', m.hw.transceiver)
		l.set_int('hw_type', m.hw.hw_type)
		l.set_int('hw_index', m.hw.hw_index)
		l.set_int('hw_channel', m.hw.hw_channel)
		l.set_int('serial', m.hw.serial)
		l.set_int('bitrate', m.hw.bitrate)
		l.set_int('app', m.app)
		l.set_bool('owner_known', m.owner_known)
		l.set_bool('can', m.hw.can_capable)
		l.set_bool('fd_iso', m.hw.fd_iso)
		l.set_bool('fd_bosch', m.hw.fd_bosch)
		l.set_bool('on_bus', m.hw.on_bus)
		l.set_index(i + 1)
	}
	return 1
}

// __vector_slot(app) -> "unreadable", "absent", "empty" or "taken"
fn l_vector_slot(l lua.State) i32 {
	if why := transport.vector_driver_refusal() {
		return l.fail('vector.slot: ${why}')
	}
	app := l.arg_int(1)
	if app < 1 || app > 64 {
		return l.fail('vector.slot: Vector application channels are numbered 1 to 64, not ${app}')
	}
	l.push_str(match transport.vector_app_slot(int(app)) {
		.unreadable { 'unreadable' }
		.absent { 'absent' }
		.empty { 'empty' }
		.taken { 'taken' }
	})
	return 1
}

// __vector_assign(app, hw_type, hw_index, hw_channel, create)
fn l_vector_assign(l lua.State) i32 {
	transport.vector_assign_checked(int(l.arg_int(1)), int(l.arg_int(2)), int(l.arg_int(3)),
		int(l.arg_int(4)), l.arg_bool(5)) or { return l.fail('vector.assign: ${err.msg()}') }
	return 0
}
