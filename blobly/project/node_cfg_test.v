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
          - { message: Brake, counter: C, crc: K, profile: autosar_p01, data_id: 0x1244, data_id_mode: alt }
'
	p := parse(y) or { panic(err) }
	n := p.channels[0].nodes[0]
	assert n.protect.len == 3
	assert n.protect[2].profile == 'autosar_p01' && n.protect[2].data_id_mode == 'alt'
	assert n.protect[0].data_id_mode == '' // absent: the profile's default
	assert n.protect[0].message == 'Powertrain'
	assert n.protect[0].counter == 'AliveCounter'
	assert n.protect[0].crc == 'CRC'
	assert n.protect[0].profile == 'crc8_j1850'
	assert n.protect[0].data_id or { u32(999) } == 42
	assert n.protect[1].crc == '' // counter-only protection is legitimate
	assert n.protect[1].profile == 'crc8_j1850' // the default, even when unused

	again := parse(p.to_yaml()) or { panic(err) }
	m := again.channels[0].nodes[0]
	assert m.protect.len == 3, 'save() dropped the protection'
	assert m.protect[2].data_id_mode == 'alt', 'data_id_mode lost on save'
	assert m.protect[0].data_id_mode == ''
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
          functional: "0x7DF"
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
	assert u.functional == 0x7DF && v.functional == 0x7DF, 'functional lost on save'
	assert version_for(p) == 8
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

// #383: a protect:/verify: entry reads its profile through candb.profile_from_dbc, so `P01` and
// `PROFILE_01` are Profile 1 here as in a DBC — and the file declares the version Profile 1 needs
fn test_protect_profile_1_spellings() {
	for spelling in ['P01', 'PROFILE_01'] {
		p := parse('project:
  name: t
channels:
  - name: CAN1
    interface: inproc:CAN1
    verify:
      - { message: M, counter: C, crc: K, profile: ${spelling}, data_id: 1 }
    simulation:
      - name: BCM
        protect:
          - { message: M, counter: C, crc: K, profile: ${spelling}, data_id: 1 }
') or {
			panic(err)
		}
		assert p.channels[0].verify[0].profile == 'autosar_p01', spelling
		assert p.channels[0].nodes[0].protect[0].profile == 'autosar_p01', spelling
		assert version_for(p) == 7, spelling
	}
}

fn test_builtin_uds_io_and_memory_round_trip() {
	y := 'project:
  name: t
buses:
  - name: CAN1
    interface: inproc:CAN1
    builtin_uds: false
    simulate: [BodyECU]
    simulation:
      - name: BCM
        uds:
          rx: "0x7E1"
          tx: "0x7E9"
          io:
            - { id: "0x1234", size: 1 }
          memory:
            - { address: "0x20000000", size: 256 }
'
	p := parse(y) or { panic(err) }
	assert !p.channels[0].builtin_uds
	u := p.channels[0].nodes[0].uds or { panic('uds lost') }
	assert u.io == [IoCfg{
		id:   0x1234
		size: 1
	}]
	assert u.memory == [MemCfg{
		address: 0x2000_0000
		size:    256
	}]
	assert u.malformed.len == 0
	assert version_for(p) == 13
	again := parse(p.to_yaml()) or { panic(err) }
	assert !again.channels[0].builtin_uds, 'builtin_uds lost on save'
	v := again.channels[0].nodes[0].uds or { panic('uds lost on save') }
	assert v.io == u.io && v.memory == u.memory, 'io/memory lost on save'
	assert again.version == 13
}

fn test_builtin_uds_defaults_on_and_is_not_written() {
	p := parse(node_yaml) or { panic(err) }
	assert p.channels[0].builtin_uds
	assert !p.to_yaml().contains('builtin_uds')
	assert version_for(p) < 13
}

fn test_a_malformed_io_id_or_address_is_named() {
	p := parse('project:
  name: t
buses:
  - name: CAN1
    interface: inproc:CAN1
    simulation:
      - name: BCM
        uds:
          rx: "0x7E1"
          tx: "0x7E9"
          io:
            - { id: "0x12G4", size: 1 }
          memory:
            - { address: "0x2000_0000", size: 4 }
') or {
		panic(err)
	}
	u := p.channels[0].nodes[0].uds or { panic('uds lost') }
	assert u.malformed == ['io 0x12G4', 'memory 0x2000_0000']
}

// An address past 2^64-1 is refused, never saturated to the valid 0xFFFFFFFFFFFFFFFF, and a Save
// writes it back as written so it stays refused.
fn test_a_memory_address_past_64_bits_is_malformed() {
	y := 'project:
  name: t
buses:
  - name: CAN1
    interface: inproc:CAN1
    simulation:
      - name: BCM
        uds:
          rx: "0x7E1"
          tx: "0x7E9"
          memory:
            - { address: "0x10000000000000000", size: 1 }
            - { address: "18446744073709551616", size: 1 }
            - { address: "0xFFFFFFFFFFFFFFFF", size: 1 }
'
	p := parse(y) or { panic(err) }
	u := p.channels[0].nodes[0].uds or { panic('uds lost') }
	assert u.malformed == ['memory 0x10000000000000000', 'memory 18446744073709551616']
	assert u.memory[0].address_text == '0x10000000000000000'
	assert u.memory[2].address == max_u64 && u.memory[2].address_text == ''
	again := parse(p.to_yaml()) or { panic(err) }
	v := again.channels[0].nodes[0].uds or { panic('uds lost on save') }
	assert v.malformed == u.malformed, 'a refused address must stay refused after a save'
	assert v.memory == u.memory
}

fn test_parse_id_exact() {
	assert parse_id_exact('0x7E0') or { 0 } == 0x7E0
	assert parse_id_exact('"2016"') or { 0 } == 2016
	assert parse_id_exact('0xFFFFFFFFFFFFFFFF') or { 0 } == max_u64
	assert parse_id_exact('0x10000000000000000') == none
	assert parse_id_exact('0x7G1') == none
	assert parse_id_exact('0x') == none
	assert parse_id_exact('12abc') == none
}

fn test_builtin_uds_off_asks_every_enabled_row_of_the_wire() {
	a := Channel{
		name:    'A'
		adapter: 'virtual'
		address: 'W'
		iface:   'inproc:W'
	}
	off := Channel{
		...a
		name:        'B'
		builtin_uds: false
	}
	other := Channel{
		...off
		name:    'C'
		address: 'X'
		iface:   'inproc:X'
	}
	assert !builtin_uds_off([a], a)
	assert builtin_uds_off([a, off], a), 'another row of the wire turns it off'
	assert !builtin_uds_off([a, other], a), 'a row of another wire does not'
	assert !builtin_uds_off([a, Channel{
		...off
		enabled: false
	}], a), 'a disabled row does not'
}

// Profile 5 under its spellings, and the version it needs (v13), kept by a save
fn test_protect_profile_5_spellings() {
	for spelling in ['P05', 'PROFILE_05', 'autosar_p05'] {
		p := parse('project:
  name: t
channels:
  - name: CAN1
    interface: inproc:CAN1
    simulation:
      - name: BCM
        protect:
          - { message: M, counter: C, crc: K, profile: ${spelling}, data_id: 0x1234 }
') or {
			panic(err)
		}
		assert p.channels[0].nodes[0].protect[0].profile == 'autosar_p05', spelling
		assert version_for(p) == 13, spelling
		again := parse(p.to_yaml()) or { panic(err) }
		assert again.channels[0].nodes[0].protect[0].profile == 'autosar_p05', spelling
		assert again.version == 13, spelling
	}
}

// #615: an entry names its window by offset and length, both or neither; a project that does is
// v13, and a save keeps them
fn test_protect_window_keys() {
	p := parse('project:
  name: t
channels:
  - name: CAN1
    interface: inproc:CAN1
    verify:
      - { message: M, crc: A, counter: B, profile: autosar_p01, data_id: 0x44, offset: 0, length: 4 }
      - { message: M, crc: C, counter: D, profile: autosar_p01, data_id: 0x45, offset: 0x4, length: 4 }
      - { message: M, crc: C, offset: 4 }
      - { message: M, crc: C, offset: 1, length: 0 }
      - { message: M, crc: C, offset: x, length: 4 }
') or {
		panic(err)
	}
	v := p.channels[0].verify
	assert v[0].offset or { -1 } == 0 && v[0].length or { -1 } == 4 && v[0].window()
	assert v[1].offset or { -1 } == 4 && !v[1].window_malformed
	assert v[2].window_malformed && !v[2].window(), 'an offset alone is no window'
	assert v[3].window_malformed, 'a window of no bytes'
	assert v[4].window_malformed
	assert version_for(p) == 13
	again := parse(p.to_yaml()) or { panic(err) }
	assert again.version == 13
	assert again.channels[0].verify[1].offset or { -1 } == 4
	assert again.channels[0].verify[1].length or { -1 } == 4
	// a malformed window is written back as given, so the entry stays ignored and not widened
	for i in 2 .. 5 {
		assert again.channels[0].verify[i].window_malformed, '${i}'
	}
	assert again.channels[0].verify[2].offset_text == '4'
	assert again.channels[0].verify[3].length_text == '0'
	assert again.channels[0].verify[4].offset_text == 'x'
	only := parse('project:
  name: t
channels:
  - name: CAN1
    interface: inproc:CAN1
    verify:
      - { message: M, crc: C, counter: D, profile: autosar_p01, data_id: 0x44, offset: 0 }
') or {
		panic(err)
	}
	assert version_for(only) == 13
	twice := parse(only.to_yaml()) or { panic(err) }
	assert twice.channels[0].verify[0].window_malformed
	assert twice.version == 13
}
