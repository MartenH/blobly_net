module project

// runtime_fingerprint is what lets a front end DERIVE "is my runtime view still the project?"
// instead of remembering to mark it at every mutation site. net#121 spent four review rounds
// finding sites that forgot — a bus checkbox that wrote the model without marking anything, and
// then every consumer that trusted the mark. These tests pin the property that makes the derived
// version work: every edit that changes what a rebuild would produce must change the number.

fn base() Project {
	return Project{
		name: 'p'
		channels: [
			Channel{
				name: 'CAN1'
				adapter: 'vcan'
				address: 'vcan0'
				iface: 'vcan0'
				databases: ['a.dbc']
				nodes: [NodeCfg{
					name: 'Engine'
					signals: [GenCfg{ signal: 'Rpm', typ: 'sine', amplitude: 10 }]
				}]
			},
		]
	}
}

fn test_stable_for_the_same_project() {
	assert base().runtime_fingerprint() == base().runtime_fingerprint()
}

// One case per thing rebuild_from_proj derives its runtime view from.
fn test_every_topology_edit_moves_it() {
	f := base().runtime_fingerprint()

	mut p := base()
	p.channels[0].enabled = false // THE one that started this: the Buses tick
	assert p.runtime_fingerprint() != f, 'enabling/disabling a channel must show'

	p = base()
	p.channels[0].address = 'vcan1'
	p.channels[0].iface = 'vcan1'
	assert p.runtime_fingerprint() != f, 're-addressing a bus must show'

	p = base()
	p.channels[0].databases << 'b.dbc'
	assert p.runtime_fingerprint() != f, 'attaching a DBC must show'

	p = base()
	p.channels[0].databases = []
	assert p.runtime_fingerprint() != f, 'detaching a DBC must show'

	p = base()
	p.channels[0].manifest = 'm.csv'
	assert p.runtime_fingerprint() != f, 'a manifest change must show (it fills the eth shell)'

	p = base()
	p.channels[0].mode = .replay
	assert p.runtime_fingerprint() != f, 'a mode change must show'

	p = base()
	p.channels[0].listen_only = true
	assert p.runtime_fingerprint() != f, 'listen-only must show'

	p = base()
	p.channels[0].typ = 'canfd'
	p.channels[0].fd = true
	assert p.runtime_fingerprint() != f, 'CAN-FD must show'

	p = base()
	p.channels[0].bitrate = 250000
	assert p.runtime_fingerprint() != f, 'a bitrate change must show'

	p = base()
	p.channels[0].nodes[0].name = 'Body'
	assert p.runtime_fingerprint() != f, 'renaming a simulated ECU must show'

	p = base()
	p.channels[0].nodes[0].signals[0].amplitude = 99
	assert p.runtime_fingerprint() != f, "a node's behaviour is part of the runtime, not just its name"

	p = base()
	p.channels[0].nodes = []
	assert p.runtime_fingerprint() != f, 'removing a simulated ECU must show'

	p = base()
	p.channels[0].verify << ProtectCfg{ message: 'M', counter: 'C', crc: 'K' }
	assert p.runtime_fingerprint() != f, 'an E2E verifier must show'

	p = base()
	p.channels[0].replay = Replay{ source: 'r.mf4', speed: 2.0 }
	assert p.runtime_fingerprint() != f, 'a replay source must show'

	p = base()
	p.channels << Channel{ name: 'CAN2', iface: 'vcan1' }
	assert p.runtime_fingerprint() != f, 'adding a bus must show'

	p = base()
	p.channels = []
	assert p.runtime_fingerprint() != f, 'removing the last bus must show'
}

// Generators travel the OTHER way: they are edited in the runtime view and folded back into the
// project. Including them would report the view stale the instant it was brought up to date.
fn test_senders_are_excluded() {
	f := base().runtime_fingerprint()
	mut p := base()
	p.channels[0].senders << Sender{ name: 'g', id: 0x123, trigger: 'manual' }
	assert p.runtime_fingerprint() == f, 'a generator edit must NOT read as a stale runtime'
}

// A fingerprint that concatenated fields without separating them would hash ['ab',''] the same
// as ['a','b'] — and two different bus sets would look identical.
fn test_field_and_channel_boundaries_are_not_ambiguous() {
	mut a := Project{ channels: [Channel{ name: 'ab', iface: 'x' }] }
	mut b := Project{ channels: [Channel{ name: 'a', iface: 'bx' }] }
	assert a.runtime_fingerprint() != b.runtime_fingerprint(), 'field boundary'

	mut c := Project{ channels: [Channel{ name: 'A', iface: 'x' }, Channel{ name: 'B', iface: 'y' }] }
	mut d := Project{ channels: [Channel{ name: 'A', iface: 'x' }] }
	assert c.runtime_fingerprint() != d.runtime_fingerprint(), 'channel count'

	mut e := Project{ channels: [Channel{ name: 'B', iface: 'y' }, Channel{ name: 'A', iface: 'x' }] }
	assert c.runtime_fingerprint() != e.runtime_fingerprint(), 'channel ORDER (row indices are identities here)'
}
