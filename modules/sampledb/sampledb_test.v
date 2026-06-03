module sampledb

import candb
import os

// The real dbc/cantester.dbc must describe exactly the same layouts as the
// hand-coded catalog here — this test is the contract that lets us swap the
// hand-coded sampledb for DBC loading without changing decode behaviour.
fn cantester_db() candb.Database {
	path := os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'cantester.dbc')
	return candb.load_dbc_file(path) or { panic('cannot load ${path}: ${err}') }
}

fn test_dbc_matches_handcoded_layout() {
	db := cantester_db()
	for hand in catalog() {
		from_dbc := db.lookup(hand.id) or { panic('DBC missing 0x${hand.id:X}') }
		assert from_dbc.dlc == hand.dlc
		assert from_dbc.signals.len == hand.signals.len, 'signal count for ${hand.name}'
		for hs in hand.signals {
			mut ds := candb.Signal{}
			mut found := false
			for cand in from_dbc.signals {
				if cand.name == hs.name {
					ds = cand
					found = true
					break
				}
			}
			assert found, 'DBC missing signal ${hand.name}.${hs.name}'
			assert ds.start_bit == hs.start_bit, '${hs.name} start_bit'
			assert ds.length == hs.length, '${hs.name} length'
			assert ds.factor == hs.factor, '${hs.name} factor'
			assert ds.offset == hs.offset, '${hs.name} offset'
			assert ds.is_signed == hs.is_signed, '${hs.name} is_signed'
			assert ds.byte_order == hs.byte_order, '${hs.name} byte_order'
		}
	}
}

fn test_dbc_decodes_frame_identically() {
	// A concrete Powertrain frame (the kind the Python SUT emits), decoded by the
	// hand-coded catalog and by the DBC, must yield identical physical values.
	hand := powertrain()
	dbc_pt := cantester_db().lookup(0x100) or { panic('no Powertrain in DBC') }

	mut data := []u8{len: 8}
	hand.signals[0].encode(mut data, 1600.0) // EngineSpeed rpm
	hand.signals[1].encode(mut data, 72.3)   // VehicleSpeed km/h
	hand.signals[2].encode(mut data, 95.0)   // CoolantTemp degC
	hand.signals[3].encode(mut data, 40.0)   // ThrottlePos %
	hand.signals[4].encode(mut data, 4.0)    // Gear
	hand.signals[5].encode(mut data, 1.0)    // CruiseOn

	for hs in hand.signals {
		mut ds := candb.Signal{}
		for cand in dbc_pt.signals {
			if cand.name == hs.name {
				ds = cand
				break
			}
		}
		assert ds.physical(data) == hs.physical(data), '${hs.name} physical mismatch'
	}
}
