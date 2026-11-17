module sim

import blobly.doip
import blobly.uds

const host_vin = 'NEWVIN00000000017'

fn host_on(srv uds.Server) (&DoipHost, &doip.DoipServer) {
	mut h := &DoipHost{
		server: srv
	}
	mut e := doip.new_server(doip.server_cfg(0x0E80, doip.default_vin, []u8{len: 6}), fn (_ []u8) []u8 {
		return []u8{}
	})
	h.entity = e
	return h, e
}

fn vin_write(vin string) []u8 {
	mut req := [u8(0x2E), 0xF1, 0x90]
	req << vin.bytes()
	return req
}

fn host_serve(mut h DoipHost, req []u8, functional bool) []u8 {
	return if functional { h.handle_functional(req) } else { h.handle(req) }
}

fn test_a_vin_write_moves_the_announcement_either_way_it_is_addressed() {
	for functional in [false, true] {
		mut h, mut e := host_on(uds.default_server())
		assert host_serve(mut h, vin_write(host_vin), functional) == [u8(0x6E), 0xF1, 0x90]
		assert e.announced_vin() == host_vin, 'functional ${functional}'
		assert h.server.dids[u16(0xF190)].bytestr() == host_vin
	}
}

fn test_a_vin_of_another_length_is_refused_either_way_it_is_addressed() {
	for functional in [false, true] {
		mut h, mut e := host_on(uds.default_server())
		assert host_serve(mut h, vin_write('SHORT'), functional) == [u8(0x7F), 0x2E, 0x31]
		assert e.announced_vin() == doip.default_vin, 'functional ${functional}'
		assert h.server.dids[u16(0xF190)].bytestr() == 'BLOBLYNETV0SUT001'
	}
}

fn test_a_described_vin_write_moves_the_announcement_either_way_it_is_addressed() {
	spec := uds.ServerSpec{
		dids: [
			uds.DidSpec{
				id:       0xF190
				data:     doip.default_vin.bytes()
				writable: true
			},
		]
	}
	for functional in [false, true] {
		mut h, mut e := host_on(uds.server_from(spec))
		// the described server judges the size: a short VIN is its own 0x13, announced nowhere
		assert host_serve(mut h, vin_write('SHORT'), functional) == [u8(0x7F), 0x2E, 0x13]
		assert e.announced_vin() == doip.default_vin
		assert host_serve(mut h, vin_write(host_vin), functional) == [u8(0x6E), 0xF1, 0x90]
		assert e.announced_vin() == host_vin, 'functional ${functional}'
	}
}

// a host bound to a new entity (a node ticked off and on: the GUI's watcher re-binds one host and
// does not join the old entity's serving thread) ignores a late close from the old one — only the
// entity bound last ends the connection state; its own close still does
fn test_a_stale_close_does_not_reset_the_new_connection() {
	mut h, _ := host_on(uds.default_server())
	old_close := h.closer() // the entity bound first
	new_close := h.closer() // the one bound after it
	assert h.handle([u8(0x10), 0x03])[0] == 0x50
	seed := h.handle([u8(0x27), 0x01])
	assert seed.len > 2 && seed[0] == 0x67
	mut key := [u8(0x27), 0x02]
	key << uds.security_key(seed[2..])
	assert h.handle(key) == [u8(0x67), 0x02]
	assert h.server.unlocked == 1
	old_close()
	assert h.server.unlocked == 1 && h.server.session == 0x03, 'a stale close reset the new connection'
	new_close()
	assert h.server.unlocked == 0 && h.server.session == 0x01, 'its own close did not end its connection'
}
