module project

// `simulation:` is parsed identically to the legacy `nodes:` alias.
fn test_simulation_key_parses() {
	y := 'project:
  name: t
channels:
  - name: CAN1
    interface: inproc:CAN1
    databases:
      - dbc/x.dbc
    simulation:
      - name: SUT
        signals:
          - { name: EngineSpeed, type: sine, offset: 1600, amplitude: 1500, freq: 0.7, phase: 0 }
        responses:
          - { request: "0x101", response: "0x102", byte: 0, add: 1 }
'
	p := parse(y)!
	assert p.channels.len == 1
	assert p.channels[0].nodes.len == 1
	assert p.channels[0].nodes[0].name == 'SUT'
	assert p.channels[0].nodes[0].signals[0].signal == 'EngineSpeed'
	assert p.channels[0].nodes[0].signals[0].offset == 1600
	assert p.channels[0].nodes[0].responses[0].request == u32(0x101)
	assert p.channels[0].nodes[0].responses[0].response == u32(0x102)
}

// A built Project survives to_yaml() -> parse() unchanged (the Save round-trip).
fn test_roundtrip() {
	orig := Project{
		name:     'rt'
		channels: [
			Channel{
				name:      'CAN1'
				iface:     'inproc:CAN1'
				databases: ['dbc/blobly_net.dbc']
				manifest:  'manifests/trace-demo.csv'
				nodes:     [
					NodeCfg{
						name:      'SUT'
						signals:   [
							GenCfg{
								signal:    'EngineSpeed'
								typ:       'sine'
								offset:    1600
								amplitude: 1500
								freq:      0.5
							},
							GenCfg{
								signal: 'Gear'
								typ:    'stepmod'
								period: 1
								count:  6
								base:   1
							},
						]
						responses: [
							ResponseCfg{
								request:  0x101
								response: 0x102
								byte:     0
								add:      1
							},
						]
					},
				]
			},
		]
	}
	reparsed := parse(orig.to_yaml())!
	assert reparsed.name == 'rt'
	assert reparsed.channels.len == 1
	c := reparsed.channels[0]
	assert c.name == 'CAN1'
	assert c.iface == 'inproc:CAN1'
	assert c.databases == ['dbc/blobly_net.dbc']
	assert c.manifest == 'manifests/trace-demo.csv'
	assert c.nodes.len == 1
	assert c.nodes[0].name == 'SUT'
	assert c.nodes[0].signals.len == 2
	assert c.nodes[0].signals[0].signal == 'EngineSpeed'
	assert c.nodes[0].signals[0].typ == 'sine'
	assert c.nodes[0].signals[0].offset == 1600
	assert c.nodes[0].signals[0].amplitude == 1500
	assert c.nodes[0].signals[1].signal == 'Gear'
	assert c.nodes[0].signals[1].typ == 'stepmod'
	assert c.nodes[0].signals[1].count == 6
	assert c.nodes[0].signals[1].base == 1
	assert c.nodes[0].responses[0].request == u32(0x101)
	assert c.nodes[0].responses[0].response == u32(0x102)
}

// v2 schema: adapter/address/network compose the iface and survive the round-trip, for a
// mix of a virtual CAN bus, a DoIP endpoint, and a replay bus (built from blank, in code).
fn test_roundtrip_v2() {
	orig := Project{
		name:     'v2'
		channels: [
			Channel{
				name:      'CAN0'
				network:   'Powertrain'
				adapter:   'virtual'
				address:   'CAN1'
				iface:     'inproc:CAN1'
				typ:       'can'
				databases: ['dbc/blobly_net.dbc']
			},
			Channel{
				name:        'Gateway'
				network:     'Diagnostics'
				adapter:     'doip'
				address:     '127.0.0.1:13400'
				iface:       'doip:127.0.0.1:13400'
				typ:         'doip'
				tester_addr: 0x0E80
				ecu_addr:    0x1000
			},
			Channel{
				name:    'Replay'
				adapter: 'virtual'
				address: 'REPLAY'
				iface:   'inproc:REPLAY'
				mode:    .replay
				replay:  Replay{
					source: 'samples/demo.log'
					speed:  2.0
					repeat: true
				}
			},
		]
	}
	rp := parse(orig.to_yaml())!
	assert rp.version == schema_version
	assert rp.channels.len == 3
	c0 := rp.channels[0]
	assert c0.name == 'CAN0'
	assert c0.network == 'Powertrain'
	assert c0.adapter == 'virtual'
	assert c0.address == 'CAN1'
	assert c0.iface == 'inproc:CAN1'
	assert c0.typ == 'can'
	c1 := rp.channels[1]
	assert c1.adapter == 'doip'
	assert c1.address == '127.0.0.1:13400'
	assert c1.is_doip()
	assert c1.tester_addr == 0x0E80
	assert c1.ecu_addr == 0x1000
	c2 := rp.channels[2]
	assert c2.adapter == 'virtual'
	assert c2.iface == 'inproc:REPLAY'
	assert c2.mode == .replay
	r := c2.replay or { panic('replay missing') }
	assert r.source == 'samples/demo.log'
	assert r.speed == 2.0
	assert r.repeat == true
}

// v1 files (top-level `channels:`, `interface:`, `type:`) still load, and the parser
// decomposes `interface` back into adapter+address so the editor has both.
fn test_legacy_v1_loads() {
	y := 'project:
  name: legacy
channels:
  - name: CAN1
    type: can
    interface: inproc:CAN1
    databases:
      - dbc/blobly_net.dbc
  - name: PT
    type: can
    interface: vcan0
  - name: Diag
    type: doip
    interface: doip:127.0.0.1:13400
    tester_address: "0x0E80"
    ecu_address: "0x1000"
'
	p := parse(y)!
	assert p.channels.len == 3
	assert p.channels[0].adapter == 'virtual'
	assert p.channels[0].address == 'CAN1'
	assert p.channels[0].iface == 'inproc:CAN1'
	assert p.channels[1].adapter == 'vcan'
	assert p.channels[1].address == 'vcan0'
	assert p.channels[2].adapter == 'doip'
	assert p.channels[2].address == '127.0.0.1:13400'
	assert p.channels[2].is_doip()
	assert p.channels[2].ecu_addr == 0x1000
}

// compose_iface / decompose_iface are inverses across every adapter.
fn test_iface_compose_decompose() {
	cases := [
		['virtual', 'CAN1', 'inproc:CAN1'],
		['vcan', 'vcan0', 'vcan0'],
		['socketcan', 'can0', 'can0'],
		['udp', '239.0.0.1:5000', 'udp:239.0.0.1:5000'],
		['pcan', 'PCAN_USBBUS1', 'pcan:PCAN_USBBUS1'],
		['kvaser', '0', 'kvaser:0'],
		['doip', '127.0.0.1:13400', 'doip:127.0.0.1:13400'],
	]
	for cse in cases {
		adapter, address, iface := cse[0], cse[1], cse[2]
		assert compose_iface(adapter, address) == iface
		a, ad := decompose_iface(iface)
		assert a == adapter
		assert ad == address
	}
}

// transport_iface appends @<bitrate> for the vendor CAN backends, not for socketcan/vcan.
fn test_transport_iface_bitrate() {
	pc := Channel{
		adapter: 'pcan'
		address: 'PCAN_USBBUS1'
		iface:   'pcan:PCAN_USBBUS1'
		bitrate: 250000
	}
	assert pc.transport_iface() == 'pcan:PCAN_USBBUS1@250000'
	kv := Channel{
		adapter: 'kvaser'
		address: '0'
		iface:   'kvaser:0'
		bitrate: 1000000
	}
	assert kv.transport_iface() == 'kvaser:0@1000000'
	// socketcan/vcan configure the bitrate via `ip link`, so no suffix
	vc := Channel{
		adapter: 'socketcan'
		address: 'can0'
		iface:   'can0'
		bitrate: 250000
	}
	assert vc.transport_iface() == 'can0'
}

// Senders (interactive generators) survive the Save round-trip.
fn test_roundtrip_senders() {
	orig := Project{
		name:     'rts'
		channels: [
			Channel{
				name:    'CAN1'
				iface:   'inproc:CAN1'
				senders: [
					Sender{
						name:    'Ignition On'
						key:     'i'
						message: 'Powertrain'
						trigger: 'key'
						signals: [
							SenderSig{
								name:  'EngineSpeed'
								value: 800
							},
						]
					},
					Sender{
						name:     'Wake'
						id:       0x123
						data:     [u8(0xDE), 0xAD]
						trigger:  'cyclic'
						cycle_ms: 100
					},
				]
			},
		]
	}
	c := parse(orig.to_yaml())!.channels[0]
	assert c.senders.len == 2
	assert c.senders[0].name == 'Ignition On'
	assert c.senders[0].key == 'i'
	assert c.senders[0].message == 'Powertrain'
	assert c.senders[0].trigger == 'key'
	assert c.senders[0].signals[0].name == 'EngineSpeed'
	assert c.senders[0].signals[0].value == 800.0
	assert c.senders[1].name == 'Wake'
	assert c.senders[1].id == 0x123
	assert c.senders[1].data == [u8(0xDE), 0xAD]
	assert c.senders[1].trigger == 'cyclic'
	assert c.senders[1].cycle_ms == 100
}
