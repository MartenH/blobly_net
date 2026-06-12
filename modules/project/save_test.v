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
				databases: ['dbc/cantester.dbc']
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
	assert c.databases == ['dbc/cantester.dbc']
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
