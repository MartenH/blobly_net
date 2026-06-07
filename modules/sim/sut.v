// sut_ecu — the native-V twin of sut/can_sut.py, built declaratively from the
// 'SUT' node of cantester.dbc. It is the default simulated ECU and the reference
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
