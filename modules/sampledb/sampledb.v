// sampledb — a tiny hand-coded message catalog used until DBC loading lands
// (Phase 5). Shared by the GUI and the decode demo so the layout lives in one
// place. The Python virtual SUT emits these same IDs/layouts.
module sampledb

import candb

pub fn powertrain() candb.Message {
	return candb.Message{
		name:    'Powertrain'
		id:      0x100
		dlc:     8
		signals: [
			candb.Signal{ name: 'EngineSpeed',  start_bit: 0,  length: 16, factor: 0.25, unit: 'rpm' },
			candb.Signal{ name: 'VehicleSpeed', start_bit: 16, length: 12, factor: 0.1,  unit: 'km/h' },
			candb.Signal{ name: 'CoolantTemp',  start_bit: 28, length: 8,  offset: -40,  unit: '°C' },
			candb.Signal{ name: 'ThrottlePos',  start_bit: 36, length: 7,  unit: '%' },
			candb.Signal{ name: 'Gear',         start_bit: 43, length: 4,  unit: '' },
			candb.Signal{ name: 'CruiseOn',     start_bit: 47, length: 1,  unit: '' },
		]
	}
}

pub fn heartbeat() candb.Message {
	return candb.Message{
		name:    'Heartbeat'
		id:      0x700
		dlc:     1
		signals: [
			candb.Signal{ name: 'Counter', start_bit: 0, length: 8, unit: '' },
		]
	}
}

pub fn catalog() []candb.Message {
	return [powertrain(), heartbeat()]
}

// lookup returns the message defined for `id`, if any.
pub fn lookup(id u32) ?candb.Message {
	for m in catalog() {
		if m.id == id {
			return m
		}
	}
	return none
}
