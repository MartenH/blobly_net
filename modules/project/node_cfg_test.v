module project

const node_yaml = 'project:
  name: sim
channels:
  - name: CAN1
    interface: inproc:CAN1
    databases: [dbc/blobly_net.dbc]
    simulate: [Gateway]
    nodes:
      - name: SUT
        signals:
          - { name: EngineSpeed, type: sine, offset: 1600, amplitude: 1500, freq: 0.7, phase: 0 }
          - { name: Counter, type: counter, start: 0, step: 1, modulo: 256 }
          - { name: Gear, type: stepmod, period: 1, count: 6, base: 1 }
        responses:
          - { request: "0x101", response: "0x102", byte: 0, add: 1 }
'

fn test_node_signals_parsed() {
	p := parse(node_yaml) or { panic(err) }
	ch := p.channels[0]
	assert ch.nodes.len == 1
	sut := ch.nodes[0]
	assert sut.name == 'SUT'
	assert sut.signals.len == 3

	eng := sut.signals[0]
	assert eng.signal == 'EngineSpeed'
	assert eng.typ == 'sine'
	assert eng.offset == 1600
	assert eng.amplitude == 1500
	assert eng.freq == 0.7

	cnt := sut.signals[1]
	assert cnt.typ == 'counter'
	assert cnt.step == 1
	assert cnt.modulo == 256

	gear := sut.signals[2]
	assert gear.typ == 'stepmod'
	assert gear.period == 1
	assert gear.count == 6
	assert gear.base == 1
}

fn test_node_responses_and_hex_ids() {
	p := parse(node_yaml) or { panic(err) }
	r := p.channels[0].nodes[0].responses[0]
	assert r.request == 0x101
	assert r.response == 0x102
	assert r.byte == 0
	assert r.add == 1
}

fn test_all_nodes_merges_simulate_shorthand() {
	p := parse(node_yaml) or { panic(err) }
	all := p.channels[0].all_nodes()
	// SUT (configured) + Gateway (simulate shorthand, default behaviour)
	assert all.len == 2
	mut names := all.map(it.name)
	names.sort()
	assert names == ['Gateway', 'SUT']
	// the shorthand node has no signal config
	gw := all.filter(it.name == 'Gateway')[0]
	assert gw.signals.len == 0
}

// End-to-end protection must survive load → save → load. A parser that reads `protect` while
// the writer drops it would load a protected project and save an unprotected one, so the next
// session transmits frames the ECU under test rejects — with the evidence already deleted.
fn test_protect_round_trips() {
	y := 'project:
  name: t
channels:
  - name: CAN1
    interface: inproc:CAN1
    simulation:
      - name: BCM
        protect:
          - { message: Powertrain, counter: AliveCounter, crc: CRC, profile: crc8_j1850, data_id: 42 }
          - { message: Status, counter: Cnt }
'
	p := parse(y) or { panic(err) }
	n := p.channels[0].nodes[0]
	assert n.protect.len == 2
	assert n.protect[0].message == 'Powertrain'
	assert n.protect[0].counter == 'AliveCounter'
	assert n.protect[0].crc == 'CRC'
	assert n.protect[0].profile == 'crc8_j1850'
	assert n.protect[0].data_id or { u32(999) } == 42
	assert n.protect[1].crc == '' // counter-only protection is legitimate
	assert n.protect[1].profile == 'crc8_j1850' // the default, even when unused

	again := parse(p.to_yaml()) or { panic(err) }
	m := again.channels[0].nodes[0]
	assert m.protect.len == 2, 'save() dropped the protection'
	assert m.protect[0].message == n.protect[0].message
	assert m.protect[0].counter == n.protect[0].counter
	assert m.protect[0].crc == n.protect[0].crc
	assert m.protect[0].profile == n.protect[0].profile
	assert m.protect[0].data_id or { u32(999) } == 42, 'data_id lost on save'
	assert m.protect[1].data_id == none, 'an omitted data_id must stay omitted'
	assert m.protect[1].message == 'Status'
	assert m.protect[1].counter == 'Cnt'
}

// A per-ECU diagnostic server must survive load → save → load. Dropping it on save reverts the
// ECU to the channel-wide default addresses, so the tester silently talks to something else.
fn test_uds_round_trips() {
	y := 'project:
  name: t
channels:
  - name: CAN1
    interface: inproc:CAN1
    simulation:
      - name: BCM
        uds:
          rx: "0x7E1"
          tx: "0x7E9"
          session: 3
          dids:
            - { id: "0xF190", text: "BLOBLY-BCM-0001" }
            - { id: "0xF195", bytes: "01 00" }
          dtcs:
            - { code: "0x900101", status: 9 }
            - { code: "0x900102" }
      - name: ECM
'
	p := parse(y) or { panic(err) }
	u := p.channels[0].nodes[0].uds or { panic('uds not parsed') }
	assert u.rx == 0x7E1 && u.tx == 0x7E9
	assert u.session == 3
	assert u.dids.len == 2
	assert u.dids[0].text == 'BLOBLY-BCM-0001'
	assert u.dids[1].bytes == [u8(0x01), 0x00]
	assert u.dtcs.len == 2
	assert u.dtcs[0].code == 0x900101
	assert u.dtcs[1].status == 0x09, 'the status default must apply'
	assert p.channels[0].nodes[1].uds == none, 'a node without uds must stay without one'

	again := parse(p.to_yaml()) or { panic(err) }
	v := again.channels[0].nodes[0].uds or { panic('uds dropped on save') }
	assert v.rx == u.rx && v.tx == u.tx && v.session == u.session
	assert v.dids.len == 2 && v.dids[0].text == 'BLOBLY-BCM-0001'
	assert v.dids[1].bytes == [u8(0x01), 0x00], 'hex bytes must not become text'
	assert v.dtcs.len == 2 && v.dtcs[0].code == 0x900101
	assert again.channels[0].nodes[1].uds == none
}

// A DID value containing a flow-mapping delimiter must survive save → load. Written bare
// inside `{ ... }`, "ACME,INC" starts another flow entry: the project then fails to reopen, or
// reopens with the value truncated.
fn test_did_text_with_a_comma_round_trips() {
	y := 'project:
  name: t
channels:
  - name: CAN1
    interface: inproc:CAN1
    simulation:
      - name: BCM
        uds:
          rx: "0x7E1"
          tx: "0x7E9"
          dids:
            - { id: "0xF190", text: "ACME,INC" }
'
	p := parse(y) or { panic(err) }
	u := p.channels[0].nodes[0].uds or { panic('not parsed') }
	assert u.dids[0].text == 'ACME,INC'

	again := parse(p.to_yaml()) or { panic('saved file cannot be reopened: ${err}') }
	v := again.channels[0].nodes[0].uds or { panic('uds lost on save') }
	assert v.dids[0].text == 'ACME,INC', 'got "${v.dids[0].text}"'
}
