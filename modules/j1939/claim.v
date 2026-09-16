// Address claiming (J1939-81), OBSERVED. A node announces the address it will use with an
// Address Claimed frame (PGN 0xEE00, broadcast, source = the claimed address) whose eight data
// bytes are its NAME — a 64-bit identity saying what the node is: its function, which instance
// of it, the vehicle system it belongs to, who made it. Two nodes wanting one address settle it
// by NAME: the lower value keeps the address, the other moves or gives up, and a node that gave
// up says so with a Cannot Claim from the null address (0xFE).
//
// This module tracks that conversation and takes no part in it. What it buys the trace is the
// one thing a raw id cannot say — that SA 0x00 is an engine and SA 0x0B a brake controller —
// from what the bus itself declared, so a row can be attributed to a node rather than a number.
module j1939

import encoding.binary

// Name is a 64-bit J1939 NAME taken apart. Bit ranges, LSB first:
//
//   identity(21) | manufacturer(11) | ecu_instance(3) | function_instance(5) | function(8) |
//   reserved(1) | vehicle_system(7) | vehicle_system_instance(4) | industry_group(3) |
//   arbitrary_address_capable(1)
pub struct Name {
pub:
	raw                       u64
	identity                  u32 // serial number, manufacturer-assigned
	manufacturer              u16 // SAE-assigned manufacturer code
	ecu_instance              u8
	function_instance         u8
	function                  u8 // below 128: global (the same in every industry); above: per industry group
	vehicle_system            u8
	vehicle_system_instance   u8
	industry_group            u8
	arbitrary_address_capable bool
}

// decode_name reads a NAME from its eight little-endian data bytes (byte 0 holds the identity's
// low bits). Fewer than eight bytes is not a NAME.
pub fn decode_name(data []u8) ?Name {
	if data.len < 8 {
		return none
	}
	return name_from_raw(binary.little_endian_u64(data))
}

// name_from_raw takes a NAME apart from its 64-bit value.
pub fn name_from_raw(raw u64) Name {
	return Name{
		raw:                       raw
		identity:                  u32(raw & 0x1FFFFF)
		manufacturer:              u16((raw >> 21) & 0x7FF)
		ecu_instance:              u8((raw >> 32) & 0x7)
		function_instance:         u8((raw >> 35) & 0x1F)
		function:                  u8((raw >> 40) & 0xFF)
		vehicle_system:            u8((raw >> 49) & 0x7F)
		vehicle_system_instance:   u8((raw >> 56) & 0xF)
		industry_group:            u8((raw >> 60) & 0x7)
		arbitrary_address_capable: (raw >> 63) & 1 == 1
	}
}

// function_name names a GLOBAL function — the first 32 of J1939's table B11, the ones every
// industry group shares and the ones a truck or off-highway bench actually meets. Anything past
// them, and every industry-specific function (128 and up), is left as its number rather than
// guessed at: a wrong name in a trace column is worse than none.
pub fn function_name(function u8) ?string {
	return match function {
		0 { 'Engine' }
		1 { 'Auxiliary Power Unit' }
		2 { 'Electric Propulsion Control' }
		3 { 'Transmission' }
		4 { 'Battery Pack Monitor' }
		5 { 'Shift Control' }
		6 { 'Power Take-Off' }
		7 { 'Axle - Steering' }
		8 { 'Axle - Drive' }
		9 { 'Brakes - System Controller' }
		10 { 'Brakes - Steer Axle' }
		11 { 'Brakes - Drive Axle' }
		12 { 'Retarder - Engine' }
		13 { 'Retarder - Driveline' }
		14 { 'Cruise Control' }
		15 { 'Fuel System' }
		16 { 'Steering Controller' }
		17 { 'Suspension - Steer Axle' }
		18 { 'Suspension - Drive Axle' }
		19 { 'Instrument Cluster' }
		20 { 'Trip Recorder' }
		21 { 'Cab Climate Control' }
		22 { 'Aerodynamic Control' }
		23 { 'Vehicle Navigation' }
		24 { 'Vehicle Security' }
		25 { 'Network Interconnect ECU' }
		26 { 'Body Controller' }
		27 { 'Power Take-Off (secondary)' }
		28 { 'Off-Vehicle Gateway' }
		29 { 'Virtual Terminal' }
		30 { 'Management Computer' }
		31 { 'Propulsion Battery Charger' }
		else { none }
	}
}

// industry_group_name names the industry group.
pub fn industry_group_name(group u8) string {
	return match group {
		0 { 'Global' }
		1 { 'On-Highway' }
		2 { 'Agricultural and Forestry' }
		3 { 'Construction' }
		4 { 'Marine' }
		5 { 'Industrial / Process Control' }
		else { 'reserved (${group})' }
	}
}

// label is the short reading of a NAME for a table cell: the function's name and, when there is
// more than one of it, which — `Engine`, `Brakes - System Controller #2`. A function this module
// does not name reads as its number, `function 200`.
pub fn (n Name) label() string {
	mut s := function_name(n.function) or { 'function ${n.function}' }
	if n.function_instance > 0 || n.ecu_instance > 0 {
		s += ' #${n.function_instance}.${n.ecu_instance}'
	}
	return s
}

// describe is the long reading, for a log line: every field the NAME carries.
pub fn (n Name) describe() string {
	aac := if n.arbitrary_address_capable { ', arbitrary-address capable' } else { '' }
	return 'NAME 0x${n.raw:016X}: ${n.label()}, ${industry_group_name(n.industry_group)}, vehicle system ${n.vehicle_system}.${n.vehicle_system_instance}, manufacturer ${n.manufacturer}, identity ${n.identity}${aac}'
}

// is_address_claim says whether an id is an Address Claimed (or Cannot Claim) frame's: PGN
// 0xEE00 to the GLOBAL address. The PGN alone is not enough — PF 0xEE with any destination
// byte computes to it — and a destination-specific frame there is not a claim and must not
// rename a source address (codex on #329). The ONE predicate, for the directory's feed and for
// the trace's reading of the frame.
pub fn is_address_claim(i Id) bool {
	return i.pgn() == pgn_address_claimed && i.da() == addr_global
}

// Node is one address and the NAME that holds it.
pub struct Node {
pub:
	sa   u8
	name Name
	t_ms f64 // when the claim was seen
}

// ChangeKind is what an Address Claimed frame did to the directory.
pub enum ChangeKind {
	claimed      // a free address, now held
	moved        // a NAME the directory already knew, now at another address
	won          // a held address, taken by a lower NAME; the loser is named in the change
	lost         // a held address, claimed by a higher NAME that does not get it; the holder stays
	cannot_claim // a Cannot Claim from the null address: this NAME gave up
}

// Change is what one observed claim changed, in enough detail to narrate.
pub struct Change {
pub:
	kind ChangeKind
	sa   u8   // the address the frame was about (its source; the null address for a Cannot Claim)
	name Name // the claiming NAME
	// For won / lost: the NAME on the other side of the contention.
	other Name
	// The address the claiming NAME held until this frame, if it held one — a node that claims
	// elsewhere, wins or loses, has left it (it claims a third address or sends Cannot Claim
	// next), and so has a node that gives up.
	held ?u8
}

// str is the change in words.
pub fn (c Change) str() string {
	left := if h := c.held { ', and no longer holds SA 0x${h:02X}' } else { '' }
	return match c.kind {
		.claimed { 'SA 0x${c.sa:02X} claimed by ${c.name.describe()}' }
		.moved { 'SA 0x${c.sa:02X} claimed by ${c.name.describe()}${left}' }
		.won { 'SA 0x${c.sa:02X} contested: ${c.name.describe()} takes it from NAME 0x${c.other.raw:016X} (${c.other.label()}), the lower NAME wins${left}' }
		.lost { 'SA 0x${c.sa:02X} contested: ${c.name.describe()} loses to the NAME holding it, 0x${c.other.raw:016X} (${c.other.label()})${left}' }
		.cannot_claim { 'Cannot Claim from ${c.name.describe()}${left}' }
	}
}

// Directory is who holds which address on one bus.
pub struct Directory {
mut:
	by_sa map[u8]Node
}

// node answers who holds `sa`, if anyone has said.
pub fn (d Directory) node(sa u8) ?Node {
	return d.by_sa[sa] or { return none }
}

// label is the short name of whoever holds `sa`, or '' when nobody has claimed it in this
// listener's hearing.
pub fn (d Directory) label(sa u8) string {
	n := d.by_sa[sa] or { return '' }
	return n.name.label()
}

// nodes lists every held address, by address.
pub fn (d Directory) nodes() []Node {
	mut ks := d.by_sa.keys()
	ks.sort()
	mut out := []Node{cap: ks.len}
	for k in ks {
		out << d.by_sa[k]
	}
	return out
}

// len is how many addresses are held.
pub fn (d Directory) len() int {
	return d.by_sa.len
}

// addr_of is the address a NAME holds, if this directory has it anywhere. The ONE lookup behind
// a move, a loss and a Cannot Claim, which all ask it.
fn (d Directory) addr_of(raw u64) ?u8 {
	for k, n in d.by_sa {
		if n.name.raw == raw {
			return k
		}
	}
	return none
}

// observe reads one Address Claimed frame — `sa` its source address, `data` its NAME — and
// says what changed, or none when it changed nothing (a node re-announcing itself, which J1939
// nodes do on request; or a payload too short to be a NAME).
pub fn (mut d Directory) observe(sa u8, data []u8, t_ms f64) ?Change {
	name := decode_name(data) or { return none }
	if sa == addr_null {
		// Cannot Claim: this NAME has no address. Whatever it held, it holds no longer.
		held := d.addr_of(name.raw)
		if h := held {
			d.by_sa.delete(h)
		}
		return Change{
			kind: .cannot_claim
			sa:   sa
			name: name
			held: held
		}
	}
	if cur := d.by_sa[sa] {
		if cur.name.raw == name.raw {
			return none // re-announced, nothing new
		}
	}
	// Claiming here means leaving wherever it was: a node that moves has left its old address
	// whether or not it wins the new one (it claims a third or gives up next), and a duplicate
	// NAME on two addresses — which J1939 forbids and this directory cannot tell from a move —
	// reads as the last claim.
	held := d.addr_of(name.raw)
	if h := held {
		d.by_sa.delete(h)
	}
	if cur := d.by_sa[sa] {
		if name.raw < cur.name.raw {
			// The lower NAME wins the address; the holder must move or give up, and will say so
			// in its own frame.
			d.by_sa[sa] = Node{sa, name, t_ms}
			return Change{
				kind:  .won
				sa:    sa
				name:  name
				other: cur.name
				held:  held
			}
		}
		return Change{
			kind:  .lost
			sa:    sa
			name:  name
			other: cur.name
			held:  held
		}
	}
	d.by_sa[sa] = Node{sa, name, t_ms}
	moved := held != none
	return Change{
		kind: if moved { ChangeKind.moved } else { ChangeKind.claimed }
		sa:   sa
		name: name
		held: held
	}
}
