// sut_ecu — the native-V twin of sut/can_sut.py, built declaratively from the
// 'SUT' node of blobly_net.dbc. It is the default simulated ECU and the reference
// the native simulation is verified against (its emitted frames must match the
// Python SUT's). Replicates exactly:
//   - Powertrain (0x100) @100ms: EngineSpeed/VehicleSpeed/CoolantTemp/ThrottlePos
//     as sines, Gear/CruiseOn as staircases (same formulas as can_sut.py);
//   - Heartbeat (0x700) @100ms: a rolling 0..255 counter;
//   - Request (0x101) -> Response (0x102) with byte[0]+1.
module sim

import candb

pub fn sut_ecu(db candb.Database) SimEcu {
	mut ecu := SimEcu{
		name: 'SUT'
	}
	for m in db.messages_from('SUT') {
		mut sm := SimMessage{
			msg:       m
			period_ms: m.cycle_ms
		}
		match m.name {
			'Powertrain' {
				sm.signals = [
					SimSignal{'EngineSpeed', gen_sine(1600, 1500, 0.7, 0)},
					SimSignal{'VehicleSpeed', gen_sine(70, 60, 0.9, 1)},
					SimSignal{'CoolantTemp', gen_sine(90, 15, 1.1, 2)},
					SimSignal{'ThrottlePos', gen_sine(45, 45, 1.3, 3)},
					SimSignal{'Gear', gen_stepmod(1, 6, 1)},
					SimSignal{'CruiseOn', gen_stepmod(2, 2, 0)},
				]
			}
			'Heartbeat' {
				sm.signals = [
					SimSignal{'Counter', gen_counter(0, 1, 256)},
				]
			}
			else {} // Response (0x102) is request-driven (period 0), no generators
		}
		ecu.messages << sm
	}
	ecu.rules = [
		ResponseRule{
			req_id:     0x101
			resp_id:    0x102
			byte_index: 0
			add:        1
		},
	]
	return ecu
}

// ecu_from_dbc builds a generic ECU for `node`: every message whose DBC
// transmitter is it, sent cyclically per its GenMsgCycleTime, with signals held
// constant (no generators configured). A neutral default until per-signal
// generators are configured.
pub fn ecu_from_dbc(db candb.Database, node string) SimEcu {
	mut ecu := SimEcu{
		name: node
	}
	for m in db.messages_from(node) {
		ecu.messages << SimMessage{
			msg:       m
			period_ms: m.cycle_ms
		}
	}
	return ecu
}

// build_ecu returns the richest model available for `node`: the hand-tuned SUT
// reference (matching can_sut.py) for 'SUT', else a generic DBC-derived ECU.
pub fn build_ecu(db candb.Database, node string) SimEcu {
	return if node == 'SUT' { sut_ecu(db) } else { ecu_from_dbc(db, node) }
}

// build_configured_ecu builds `node` from the DBC (messages + cyclic periods) and
// attaches the supplied per-signal generators + response rules — the engine model
// for a project-file-configured ECU. Signals without a generator stay constant 0.
pub fn build_configured_ecu(db candb.Database, node string, gens map[string]Gen, rules []ResponseRule) SimEcu {
	mut ecu := ecu_from_dbc(db, node)
	for i, m in ecu.messages {
		for sig in m.msg.signals {
			if g := gens[sig.name] {
				ecu.messages[i].signals << SimSignal{
					name: sig.name
					gen:  g
				}
			}
		}
	}
	ecu.rules = rules
	return ecu
}
