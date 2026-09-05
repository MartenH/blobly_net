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
	// the version this project NEEDS (v2 here — it uses no generator value source), not blindly
	// schema_version: a file that uses no v3 feature stays openable by an older build
	assert rp.version == version_for(orig)
	assert rp.version == 2
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

// A legacy v1 vendor file embeds the bitrate in the interface (`pcan:CH@250000`): parse must
// strip it from the address, lift it into the bitrate field, and store a clean iface.
fn test_legacy_vendor_bitrate() {
	y := 'project:
  name: hw
channels:
  - name: PCAN1
    type: can
    interface: pcan:PCAN_USBBUS1@250000
  - name: KV0
    type: can
    interface: kvaser:0@1000000
'
	p := parse(y)!
	c0 := p.channels[0]
	assert c0.adapter == 'pcan'
	assert c0.address == 'PCAN_USBBUS1' // @250000 stripped
	assert c0.iface == 'pcan:PCAN_USBBUS1' // clean — no doubled bitrate at open
	assert c0.bitrate == 250000 // lifted from the iface
	c1 := p.channels[1]
	assert c1.adapter == 'kvaser'
	assert c1.address == '0'
	assert c1.bitrate == 1000000
}

// A v2 Channel that sets adapter/address but leaves iface at the struct default serializes
// from the explicit v2 fields (not the default vcan0).
fn test_v2_fields_authoritative_on_save() {
	orig := Project{
		name:     'v2auth'
		channels: [
			Channel{
				name:    'CAN1'
				adapter: 'virtual'
				address: 'CAN1'
			}, // iface left at the struct default ('vcan0')
		]
	}
	c := parse(orig.to_yaml())!.channels[0]
	assert c.adapter == 'virtual'
	assert c.address == 'CAN1'
	assert c.iface == 'inproc:CAN1'
}

// A DoIP endpoint on a bracketed IPv6 address must survive the Save round-trip (the address
// starts with `[`, which YAML would read as flow syntax unless it's quoted).
fn test_ipv6_address_roundtrip() {
	orig := Project{
		name:     'v6'
		channels: [
			Channel{
				name:    'Gateway'
				adapter: 'doip'
				address: '[::1]:13400'
				iface:   'doip:[::1]:13400'
				typ:     'doip'
			},
		]
	}
	rp := parse(orig.to_yaml())!
	assert rp.channels.len == 1
	c := rp.channels[0]
	assert c.adapter == 'doip'
	assert c.address == '[::1]:13400'
	assert c.is_doip()
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

// A generator signal may carry a VALUE SOURCE — the same GenCfg vocabulary a simulated ECU's
// signals use — and it must survive save/parse. A signal without one keeps the plain name/value
// form every older project already has (and must not gain a spurious 'const' source).
fn test_roundtrip_sender_wave() {
	orig := Project{
		name:     'wave'
		channels: [
			Channel{
				name:    'CAN1'
				iface:   'inproc:CAN1'
				senders: [
					Sender{
						name:     'Sweep'
						message:  'Powertrain'
						trigger:  'cyclic'
						cycle_ms: 100
						signals:  [
							SenderSig{
								name: 'EngineSpeed'
								wave: GenCfg{
									typ:       'sine'
									offset:    1500
									amplitude: 1000
									freq:      0.5
								}
							},
							SenderSig{
								name:  'CoolantTemp'
								value: 42
							},
						]
					},
				]
			},
		]
	}
	txt := orig.to_yaml()
	back := parse(txt) or { panic(err) }
	sigs := back.channels[0].senders[0].signals
	assert sigs.len == 2
	assert sigs[0].name == 'EngineSpeed'
	assert sigs[0].wave.typ == 'sine', 'typ=${sigs[0].wave.typ}'
	assert sigs[0].wave.offset == 1500.0
	assert sigs[0].wave.amplitude == 1000.0
	assert sigs[0].wave.freq == 0.5
	// no source: the static value survives and no waveform is invented
	assert sigs[1].name == 'CoolantTemp'
	assert sigs[1].value == 42.0
	assert sigs[1].wave.typ == '', 'typ=${sigs[1].wave.typ}'
}

// An unusable value source is REPORTED, not silently turned into a constant (or a non-finite
// number packed into raw bits): an unknown type, and the zero divisors sawtooth/stepmod divide by.
fn test_generator_source_warnings() {
	chs := [
		Channel{
			name:    'CAN1'
			senders: [
				Sender{
					name:    'g'
					signals: [
						SenderSig{ name: 'A', wave: GenCfg{ typ: 'counterr' } },
						SenderSig{ name: 'B', wave: GenCfg{ typ: 'sawtooth', period: 0 } },
						SenderSig{ name: 'C', wave: GenCfg{ typ: 'stepmod', period: 1, count: 0 } },
						SenderSig{ name: 'D', wave: GenCfg{ typ: 'sine', freq: 0 } }, // freq 0 is valid (a flat sine)
						SenderSig{ name: 'E', value: 7 }, // no source at all
					]
				},
			]
		},
	]
	w := generator_source_warnings(chs)
	assert w.len == 3, w.str()
	assert w[0].contains('unknown type'), w[0]
	assert w[1].contains('non-zero period'), w[1]
	assert w[2].contains('non-zero count'), w[2]
	// and the predicate agrees per-signal
	assert gen_source_invalid(GenCfg{ typ: '' }) == ''
	assert gen_source_invalid(GenCfg{ typ: 'sine', freq: 0 }) == ''
	assert gen_source_invalid(GenCfg{ typ: 'sawtooth', period: 2 }) == ''
}

// A project is labelled with the version it actually needs: v3 only once a generator carries a
// value source, so an older build is flagged instead of silently dropping the waveform on save.
fn test_version_for_wave() {
	mut p := Project{
		name:     'v'
		channels: [
			Channel{
				name:    'CAN1'
				senders: [
					Sender{
						name:    'g'
						signals: [SenderSig{
							name:  'A'
							value: 1
						}]
					},
				]
			},
		]
	}
	assert version_for(p) == 2
	assert parse(p.to_yaml())!.version == 2
	p.channels[0].senders[0].signals[0].wave = GenCfg{
		typ:    'sawtooth'
		min:    0
		max:    10
		period: 2
	}
	assert version_for(p) == 3
	back := parse(p.to_yaml())!
	assert back.version == 3
	// and the static fallback survives beside the waveform
	sg := back.channels[0].senders[0].signals[0]
	assert sg.value == 1.0, 'value=${sg.value}'
	assert sg.wave.typ == 'sawtooth'
	assert sg.wave.max == 10.0
	assert sg.wave.period == 2.0
}

// A generator's `const` source is the same number as its static value (same key), so it folds
// into that on read: one editable value, and never two `value:` keys in one saved mapping.
fn test_sender_const_source_folds_to_value() {
	p := parse('project:\n  name: c\nchannels:\n  - name: CAN1\n    interface: inproc:CAN1\n    senders:\n      - name: g\n        message: Powertrain\n        signals:\n          - { name: A, type: const, value: 5 }\n') or {
		panic(err)
	}
	sg := p.channels[0].senders[0].signals[0]
	assert sg.value == 5.0
	assert sg.wave.typ == '', 'typ=${sg.wave.typ}'
	// and it saves back as a plain value with no duplicate key
	out := p.to_yaml()
	assert out.contains('{ name: A, value: 5 }'), out
	assert version_for(p) == 2
}
