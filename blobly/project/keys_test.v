module project

import os
import yaml

// every_writer_branch is a project setting what to_yaml can write, so each key it emits is
// written once.
fn every_writer_branch() Project {
	window := ProtectCfg{
		message:      'Status'
		id:           u32(0x100)
		extended:     false
		counter:      'Ctr'
		crc:          'Crc'
		profile:      'autosar_p01'
		data_id:      u32(7)
		data_id_mode: 'low'
		offset:       0
		length:       8
	}
	bad_window := ProtectCfg{
		message:          'Other'
		window_malformed: true
		offset_text:      'x'
		length_text:      'y'
	}
	can_row := Channel{
		name:              'CAN1'
		network:           'body'
		adapter:           'vcan'
		address:           'vcan0'
		typ:               'canfd'
		fd:                true
		data_bitrate:      2000000
		sample_point:      0.8
		data_sample_point: 0.7
		listen_only:       true
		j1939:             true
		builtin_uds:       false
		nm:                NmCfg{
			lo:       0x500
			hi:       0x53F
			ext:      true
			cycle_ms: 200
		}
		diagnostics:       [DiagNodeCfg{
			node:    'N'
			odx:     'n.pdx'
			variant: 'V'
			tx:      0x700
			rx:      0x708
		}]
		timing:            Timing{
			brp:   1
			tseg1: 13
			tseg2: 2
		}
		databases:         ['dbc/blobly_net.dbc']
		manifest:          'm.csv'
		verify:            [window, bad_window]
		simulate:          ['Engine']
		nodes:             [
			NodeCfg{
				name:      'Body'
				signals:   [GenCfg{
					signal: 'S'
					typ:    'sine'
				}]
				responses: [ResponseCfg{
					request:  0x7E0
					response: 0x7E8
				}]
				uds:       UdsCfg{
					rx:         0x7E0
					tx:         0x7E8
					functional: 0x7DF
					session:    3
					dids:       [DidCfg{
						id:   0xF190
						text: 'VIN'
					}, DidCfg{
						id:    0xF180
						bytes: [u8(1)]
					}]
					dtcs:       [DtcCfg{
						code: 0x123456
					}]
					io:         [IoCfg{
						id:   0x4000
						size: 2
					}]
					memory:     [MemCfg{
						address: 0x2000
						size:    4
					}]
				}
				protect:   [window]
				nm:        NodeNm{
					id:  0x501
					nid: 1
				}
			},
		]
		senders:           [
			Sender{
				name:     'G'
				key:      'g'
				message:  'Status'
				id:       0x123
				ext:      true
				data:     [u8(1), 2]
				bus:      'CAN1'
				trigger:  'cyclic'
				cycle_ms: 100
				format:   .fd_brs
				signals:  [SenderSig{
					name:  'S'
					value: 1
					wave:  GenCfg{
						typ: 'counter'
					}
				}]
			},
		]
		replay:            Replay{
			source:  'r.log'
			bus:     'can0'
			exclude: ['Engine']
		}
	}
	doip_row := Channel{
		name:              'DoIP1'
		adapter:           'doip'
		address:           '127.0.0.1:13400'
		typ:               'doip'
		vin:               'ABCDEFGHJKLMNPRST'
		eid:               [u8(1), 2, 3, 4, 5, 6]
		announce_count:    0
		announce_interval: 1
		announce_to:       '127.0.0.1:13401'
	}
	someip_row := Channel{
		name:    'SOMEIP1'
		adapter: 'someip'
		address: '0.0.0.0:30490'
		typ:     'someip'
		group:   '239.0.0.1'
	}
	lin_bus := lin_row('LIN1', 'body', 'inproc:L', 19200, 'l.ldf', 'master', ['Slave'], 'Normal',
		true)
	return Project{
		name:     'all'
		channels: [can_row, doip_row, someip_row, lin_bus]
	}
}

// Every key the writer emits is one the table lists: a key added to the writer and not to
// key_table fails here.
fn test_the_writer_emits_only_listed_keys() {
	text := every_writer_branch().to_yaml()
	doc := yaml.parse_text(text)!
	assert unknown_keys(doc.root) == [], text
	assert parse(text)!.unknown_keys == []
}

fn test_no_shipped_project_carries_an_unknown_key() {
	for f in os.walk_ext('projects', '.blobnet') {
		p := load(f) or { panic('${f}: ${err}') }
		assert p.unknown_keys == [], f
	}
}

fn test_an_unknown_key_is_named_where_it_sits() {
	p := parse('project:
  name: x
  version: 2
  colour: red
buses:
  - name: CAN1
    interface: vcan0
    bitrat: 500000
    simulation:
      - name: Body
        protec: []
        uds: { rx: 0x7E0, tx: 0x7E8, sesion: 3 }
    senders:
      - name: G
        cycle_msec: 10
        signals:
          - { name: S, value: 1, ampl: 2 }
    verify:
      - { message: Status, crc: Crc, profil: sum8 }
')!
	assert p.unknown_keys.len == 7, '${p.unknown_keys}'
	assert p.unknown_keys[0].starts_with('unknown key `colour` in project (known: name, version)')
	assert p.unknown_keys[1].starts_with('unknown key `bitrat` in channel "CAN1" (known: ')
	assert p.unknown_keys[2].starts_with('unknown key `protec` in channel "CAN1" / node "Body"')
	assert p.unknown_keys[3].starts_with('unknown key `sesion` in channel "CAN1" / node "Body" / uds')
	assert p.unknown_keys[4].starts_with('unknown key `cycle_msec` in channel "CAN1" / generator "G"')
	assert p.unknown_keys[5].starts_with('unknown key `ampl` in channel "CAN1" / generator "G" / signal "S"')
	assert p.unknown_keys[6].starts_with('unknown key `profil` in channel "CAN1" / verify "Status"')
	// said among the load's notes, and refused by a strict load
	for k in p.unknown_keys {
		assert k in p.notes
	}
	assert p.strict_refusals() == p.unknown_keys
}

// A file of a newer schema may carry keys this build cannot know: noted, not refused.
fn test_a_newer_schema_notes_unknown_keys_without_refusing() {
	p := parse('project:
  name: x
  version: ${schema_version + 1}
buses:
  - name: CAN1
    interface: vcan0
    shiny: true
  - name: LIN1
    adapter: lin
    address: inproc:L
    sparkly: 1
')!
	assert p.unknown_keys.len == 2, '${p.unknown_keys}'
	assert p.unknown_keys[1].starts_with('unknown key `sparkly` in channel "LIN1" (known: name, network, adapter')
	assert p.strict_refusals() == []
}
