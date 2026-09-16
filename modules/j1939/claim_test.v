module j1939

// A NAME built field by field, so the decode is checked against the layout and not against
// itself.
fn build(identity u32, manufacturer u16, ecu_inst u8, fn_inst u8, function u8, vsys u8, vsys_inst u8, ig u8, aac bool) []u8 {
	mut raw := u64(identity & 0x1FFFFF)
	raw |= u64(manufacturer & 0x7FF) << 21
	raw |= u64(ecu_inst & 0x7) << 32
	raw |= u64(fn_inst & 0x1F) << 35
	raw |= u64(function) << 40
	raw |= u64(vsys & 0x7F) << 49
	raw |= u64(vsys_inst & 0xF) << 56
	raw |= u64(ig & 0x7) << 60
	if aac {
		raw |= u64(1) << 63
	}
	mut out := []u8{cap: 8}
	for i in 0 .. 8 {
		out << u8((raw >> (8 * i)) & 0xFF)
	}
	return out
}

fn test_decode_name_fields() {
	d := build(0x12345, 512, 1, 2, 0, 3, 4, 1, true)
	n := decode_name(d)?
	assert n.identity == 0x12345
	assert n.manufacturer == 512
	assert n.ecu_instance == 1
	assert n.function_instance == 2
	assert n.function == 0
	assert n.vehicle_system == 3
	assert n.vehicle_system_instance == 4
	assert n.industry_group == 1
	assert n.arbitrary_address_capable
	assert n.label() == 'Engine #2.1'
	assert n.describe().contains('On-Highway')
	assert n.describe().contains('manufacturer 512')
	// too short to be a NAME
	assert decode_name([u8(1), 2, 3]) == none
}

fn test_name_labels() {
	assert name_from_raw(u64(9) << 40).label() == 'Brakes - System Controller'
	assert name_from_raw(u64(200) << 40).label() == 'function 200'
	assert function_name(31)? == 'Propulsion Battery Charger'
	assert function_name(32) == none
	assert industry_group_name(4) == 'Marine'
	assert industry_group_name(7) == 'reserved (7)'
}

fn test_claim_and_reannounce() {
	mut d := Directory{}
	engine := build(1, 100, 0, 0, 0, 0, 0, 1, false)
	c := d.observe(0x00, engine, 1.0)?
	assert c.kind == .claimed
	assert c.sa == 0x00
	assert d.label(0x00) == 'Engine'
	assert d.node(0x00)?.name.raw == decode_name(engine)?.raw
	// the same node saying it again (answering a request) changes nothing
	assert d.observe(0x00, engine, 2.0) == none
	assert d.len() == 1
}

fn test_lower_name_wins_a_contested_address() {
	mut d := Directory{}
	high := build(2, 100, 0, 0, 3, 0, 0, 1, false) // a transmission, identity 2
	low := build(1, 100, 0, 0, 3, 0, 0, 1, false) // identity 1: the lower NAME
	d.observe(0x03, high, 1.0)
	won := d.observe(0x03, low, 2.0)?
	assert won.kind == .won
	assert won.other.raw == decode_name(high)?.raw
	assert d.node(0x03)?.name.raw == decode_name(low)?.raw
	// the higher one tries again and loses; nothing moves
	lost := d.observe(0x03, high, 3.0)?
	assert lost.kind == .lost
	assert lost.other.raw == decode_name(low)?.raw
	assert d.node(0x03)?.name.raw == decode_name(low)?.raw
	assert lost.str().contains('loses to')
}

fn test_a_name_moving_leaves_its_old_address() {
	mut d := Directory{}
	body := build(7, 100, 0, 0, 26, 0, 0, 1, true)
	d.observe(0x21, body, 1.0)
	mv := d.observe(0x22, body, 2.0)?
	assert mv.kind == .moved
	assert mv.held? == 0x21
	assert mv.sa == 0x22
	assert d.node(0x21) == none
	assert d.label(0x22) == 'Body Controller'
	assert d.len() == 1
}

fn test_cannot_claim_releases_the_address() {
	mut d := Directory{}
	cc := build(5, 100, 0, 0, 19, 0, 0, 1, false)
	d.observe(0x17, cc, 1.0)
	gave_up := d.observe(addr_null, cc, 2.0)?
	assert gave_up.kind == .cannot_claim
	assert gave_up.held? == 0x17
	assert d.node(0x17) == none
	assert gave_up.str().contains('no longer holds SA 0x17')
	// a Cannot Claim from a NAME never seen holding anything
	other := build(6, 100, 0, 0, 19, 0, 0, 1, false)
	c2 := d.observe(addr_null, other, 3.0)?
	assert c2.kind == .cannot_claim
	assert c2.held == none
	assert !c2.str().contains('no longer holds')
}

// A node that claims elsewhere has left its old address whether or not it wins the new one: it
// claims a third or gives up next, and in the meantime nothing is at the old one.
fn test_losing_a_contested_claim_still_releases_the_old_address() {
	mut d := Directory{}
	low := build(1, 100, 0, 0, 0, 0, 0, 1, false)
	high := build(9, 100, 0, 0, 26, 0, 0, 1, false)
	d.observe(0x00, low, 1.0)
	d.observe(0x80, high, 2.0)
	assert d.label(0x80) == 'Body Controller'
	lost := d.observe(0x00, high, 3.0)?
	assert lost.kind == .lost
	assert lost.held? == 0x80
	assert d.node(0x80) == none
	assert d.label(0x00) == 'Engine'
	assert lost.str().contains('no longer holds SA 0x80')
	assert d.len() == 1
}

fn test_is_address_claim_needs_the_global_destination() {
	assert is_address_claim(decompose(0x18EEFF00)) // Address Claimed from 0x00
	assert is_address_claim(decompose(0x18EEFFFE)) // Cannot Claim
	assert !is_address_claim(decompose(0x18EE0000)) // PF 0xEE to one node: not a claim
	assert !is_address_claim(decompose(0x18EAFF00)) // a Request
}

fn test_nodes_are_listed_by_address() {
	mut d := Directory{}
	d.observe(0x0B, build(1, 1, 0, 0, 9, 0, 0, 1, false), 1.0)
	d.observe(0x00, build(2, 1, 0, 0, 0, 0, 0, 1, false), 2.0)
	ns := d.nodes()
	assert ns.len == 2
	assert ns[0].sa == 0x00 && ns[0].name.label() == 'Engine'
	assert ns[1].sa == 0x0B && ns[1].name.label() == 'Brakes - System Controller'
	assert d.label(0x55) == ''
}
