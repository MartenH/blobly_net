module project

const sample = '
project:
  name: demo-bench
  version: 2
channels:
  - name: CAN1
    type: can
    interface: vcan0
    bitrate: 500000
    mode: monitor
    databases:
      - dbc/blobly_net.dbc
  - name: CAN2
    interface: vcan1
    bitrate: 250000
    mode: replay
    enabled: false
    listen_only: true
    timing:
      brp: 4
      tseg1: 13
      tseg2: 2
      sjw: 1
    replay:
      source: samples/demo.mf4
      speed: 2.0
      loop: true
'

fn test_parse_project_meta() {
	p := parse(sample) or { panic(err) }
	assert p.name == 'demo-bench'
	assert p.version == 2
	assert p.channels.len == 2
}

fn test_channel_one_defaults_and_db() {
	p := parse(sample) or { panic(err) }
	c := p.channels[0]
	assert c.name == 'CAN1'
	assert c.iface == 'vcan0'
	assert c.bitrate == 500000
	assert c.mode == .monitor
	assert c.enabled == true // default
	assert c.listen_only == false // default
	assert c.databases == ['dbc/blobly_net.dbc']
	assert c.replay == none
}

fn test_channel_two_full() {
	p := parse(sample) or { panic(err) }
	c := p.channels[1]
	assert c.iface == 'vcan1'
	assert c.bitrate == 250000
	assert c.mode == .replay
	assert c.enabled == false
	assert c.listen_only == true
	assert c.timing.brp == 4
	assert c.timing.tseg1 == 13
	r := c.replay or { panic('expected replay') }
	assert r.source == 'samples/demo.mf4'
	assert r.speed == 2.0
	assert r.repeat == true
}

fn test_default_project() {
	p := default_project()
	assert p.channels.len == 1
	assert p.channels[0].iface == 'vcan0'
	assert p.channels[0].mode == .monitor
	assert p.channels[0].databases == ['dbc/blobly_net.dbc']
}

fn test_mode_from_and_str() {
	assert mode_from('off') == .off
	assert mode_from('REPLAY') == .replay
	assert mode_from('nonsense') == .monitor
	assert Mode.monitor.str() == 'monitor'
}

fn test_empty_channels() {
	p := parse('project:\n  name: bare\n') or { panic(err) }
	assert p.name == 'bare'
	assert p.channels.len == 0
}

const senders_sample = '
project:
  name: senders
channels:
  - name: CAN1
    interface: inproc:CAN1
    senders:
      - name: Ignition On
        key: i
        message: Powertrain
        trigger: key
        signals:
          - { name: EngineSpeed, value: 800 }
          - { name: Gear, value: 1 }
      - name: Wake pulse
        id: "0x123"
        data: DE AD BE EF
        trigger: cyclic
        cycle_ms: 100
'

fn test_parse_senders() {
	p := parse(senders_sample) or { panic(err) }
	c := p.channels[0]
	assert c.senders.len == 2

	s0 := c.senders[0]
	assert s0.name == 'Ignition On'
	assert s0.key == 'i'
	assert s0.message == 'Powertrain'
	assert s0.trigger == 'key'
	assert s0.signals.len == 2
	assert s0.signals[0].name == 'EngineSpeed'
	assert s0.signals[0].value == 800.0
	assert s0.signals[1].name == 'Gear'
	assert s0.signals[1].value == 1.0

	s1 := c.senders[1]
	assert s1.name == 'Wake pulse'
	assert s1.id == 0x123
	assert s1.data == [u8(0xDE), 0xAD, 0xBE, 0xEF]
	assert s1.trigger == 'cyclic'
	assert s1.cycle_ms == 100
}

fn test_sender_defaults() {
	p := parse('project:\n  name: d\nchannels:\n  - name: CAN1\n    senders:\n      - name: Bare\n') or {
		panic(err)
	}
	s := p.channels[0].senders[0]
	assert s.name == 'Bare'
	assert s.trigger == 'manual' // default
	assert s.key == ''
	assert s.signals.len == 0
}

fn test_parse_hex_bytes() {
	assert parse_hex_bytes('DEADBEEF') == [u8(0xDE), 0xAD, 0xBE, 0xEF]
	assert parse_hex_bytes('DE AD BE EF') == [u8(0xDE), 0xAD, 0xBE, 0xEF]
	assert parse_hex_bytes('de:ad') == [u8(0xDE), 0xAD]
	assert parse_hex_bytes('') == []u8{}
	assert parse_hex_bytes('AABBC') == [u8(0xAA), 0xBB] // odd trailing nibble dropped
}

fn test_doip_channel() {
	p := parse('project:\n  name: d\nchannels:\n  - name: DoIP1\n    type: doip\n    interface: "doip:127.0.0.1:13400"\n    tester_address: "0x0E80"\n    ecu_address: "0x1000"\n') or {
		panic(err)
	}
	c := p.channels[0]
	assert c.is_doip()
	assert c.tester_addr == 0x0E80
	assert c.ecu_addr == 0x1000
	host, port := c.doip_endpoint()
	assert host == '127.0.0.1'
	assert port == 13400
}

fn test_doip_endpoint_defaults() {
	// `type: doip` with a bare/short interface falls back to 127.0.0.1:13400.
	bare := Channel{
		typ:   'doip'
		iface: 'doip'
	}
	assert bare.is_doip()
	h0, p0 := bare.doip_endpoint()
	assert h0 == '127.0.0.1'
	assert p0 == 13400
	// host-only (no port) keeps the default port.
	hostonly := Channel{
		iface: 'doip:192.168.1.5'
	}
	assert hostonly.is_doip() // recognised via the iface prefix even without type
	h1, p1 := hostonly.doip_endpoint()
	assert h1 == '192.168.1.5'
	assert p1 == 13400
	// bare `interface: doip` shorthand (no explicit type) is recognised too.
	shorthand := Channel{
		iface: 'doip'
	}
	assert shorthand.is_doip()
	hs, ps := shorthand.doip_endpoint()
	assert hs == '127.0.0.1'
	assert ps == 13400
	// default addresses when unset.
	assert bare.tester_addr == 0x0E80
	assert bare.ecu_addr == 0x1000
	// type: doip but interface omitted -> inherits the CAN default `vcan0`, which
	// must NOT be treated as the DoIP host: fall back to localhost.
	inherited := Channel{
		typ: 'doip'
		// iface left at its 'vcan0' default
	}
	assert inherited.is_doip()
	h2, p2 := inherited.doip_endpoint()
	assert h2 == '127.0.0.1'
	assert p2 == 13400
}

fn test_doip_endpoint_parsing() {
	// explicit valid host:port
	h0, p0 := Channel{
		iface: 'doip:10.0.0.5:5000'
	}.doip_endpoint()
	assert h0 == '10.0.0.5'
	assert p0 == 5000
	// typo'd port (non-numeric) → kept whole as host + default port (so it fails
	// loudly on connect rather than silently dialing 13400 on a truncated host).
	h1, p1 := Channel{
		iface: 'doip:ecu.local:1340O'
	}.doip_endpoint()
	assert h1 == 'ecu.local:1340O'
	assert p1 == 13400
	// out-of-range port → not treated as a port.
	h2, p2 := Channel{
		iface: 'doip:host:99999'
	}.doip_endpoint()
	assert h2 == 'host:99999'
	assert p2 == 13400
	// bracketed IPv6 with + without port.
	h3, p3 := Channel{
		iface: 'doip:[fe80::1]:13401'
	}.doip_endpoint()
	assert h3 == 'fe80::1'
	assert p3 == 13401
	h4, p4 := Channel{
		iface: 'doip:[::1]'
	}.doip_endpoint()
	assert h4 == '::1'
	assert p4 == 13400
	// unbracketed IPv6 (multiple colons) → kept whole as host, default port.
	h5, p5 := Channel{
		iface: 'doip:fe80::1'
	}.doip_endpoint()
	assert h5 == 'fe80::1'
	assert p5 == 13400
	// malformed bracketed suffix → kept whole (fails loudly on connect), not
	// silently defaulted to ::1 + 13400.
	h6, p6 := Channel{
		iface: 'doip:[::1]:1340O'
	}.doip_endpoint()
	assert h6 == '[::1]:1340O'
	assert p6 == 13400
	h7, p7 := Channel{
		iface: 'doip:[::1]junk'
	}.doip_endpoint()
	assert h7 == '[::1]junk'
	assert p7 == 13400
}

fn test_doip_address_out_of_range() {
	// a 16-bit-overflowing logical address must surface as an error, not wrap to 0.
	parse('project:\n  name: d\nchannels:\n  - name: D\n    type: doip\n    tester_address: "0x10000"\n') or {
		// expected
		parse('project:\n  name: d\nchannels:\n  - name: D\n    type: doip\n    ecu_address: "0x20000"\n') or {
			return
		}
		assert false, 'expected ecu_address out-of-range error'
		return
	}
	assert false, 'expected tester_address out-of-range error'
}

fn test_doip_address_u32_overflow() {
	// a value larger than u32 must NOT wrap through a narrow type and pass as 0.
	parse('project:\n  name: d\nchannels:\n  - name: D\n    type: doip\n    tester_address: "0x100000000"\n') or {
		return
	}
	assert false, 'expected u32-overflowing tester_address to error'
}

fn test_doip_entity_identity() {
	p := parse('project:\n  name: d\nchannels:\n  - name: E\n    type: doip\n    interface: "doip:127.0.0.2:13400"\n    ecu_address: "0x1001"\n    vin: BLOBLYNETENGINE01\n    eid: "02 00 00 00 00 02"\n') or {
		panic(err)
	}
	c := p.channels[0]
	assert c.is_doip()
	assert c.vin == 'BLOBLYNETENGINE01'
	assert c.eid == [u8(0x02), 0x00, 0x00, 0x00, 0x00, 0x02]
	host, port := c.doip_endpoint()
	assert host == '127.0.0.2'
	assert port == 13400
}

fn test_doip_identity_round_trip() {
	orig := Project{
		name:     'net'
		channels: [
			Channel{
				name:        'EngineECU'
				typ:         'doip'
				iface:       'doip:127.0.0.2:13400'
				tester_addr: 0x0E80
				ecu_addr:    0x1001
				vin:         'BLOBLYNETENGINE01'
				eid:         [u8(0x02), 0x00, 0x00, 0x00, 0x00, 0x02]
			},
		]
	}
	back := parse(orig.to_yaml()) or { panic(err) }
	c := back.channels[0]
	assert c.vin == 'BLOBLYNETENGINE01'
	assert c.eid == [u8(0x02), 0x00, 0x00, 0x00, 0x00, 0x02]
	assert c.ecu_addr == 0x1001
}

fn test_doip_vin_must_be_17() {
	parse('project:\n  name: d\nchannels:\n  - name: E\n    type: doip\n    vin: SHORTVIN\n') or {
		return
	}
	assert false, 'expected a non-17-char VIN to error'
}

fn test_doip_eid_strict() {
	// `0x`-prefixed is invalid (the 'x' is not hex) — must error, not silently mangle.
	parse('project:\n  name: d\nchannels:\n  - name: E\n    type: doip\n    eid: "0x020000000002"\n') or {
		// also reject a wrong byte count.
		parse('project:\n  name: d\nchannels:\n  - name: E\n    type: doip\n    eid: "02 00 00"\n') or {
			return
		}
		assert false, 'expected a 3-byte EID to error'
		return
	}
	assert false, 'expected a 0x-prefixed EID to error'
}

// An ABSENT optional key must mean "empty", not a list containing the string "null". `value()`
// on a missing key yields a null node, and `.array()` on that produced ["null"] — an exclusion
// naming a node no database declares, which stopped a replay channel from playing at all.
fn test_replay_without_bus_or_exclude() {
	p := parse('project:\n  name: r\nchannels:\n  - name: CAN1\n    type: can\n    interface: vcan0\n    mode: replay\n    replay:\n      source: samples/demo.mf4\n      speed: 1.0\n      loop: false\n') or {
		assert false, '${err}'
		return
	}
	r := p.channels[0].replay or {
		assert false, 'replay missing'
		return
	}

	assert r.source == 'samples/demo.mf4'
	assert r.bus == '', 'absent bus became "${r.bus}"'
	assert r.exclude == [], 'absent exclude became ${r.exclude}'
}

// And when they ARE given they survive a round trip through the writer.
fn test_replay_bus_and_exclude_round_trip() {
	src := 'project:\n  name: r\nchannels:\n  - name: CAN1\n    type: can\n    interface: vcan0\n    mode: replay\n    replay:\n      source: cap.mf4\n      bus: CAN1\n      exclude: [SUT_ECU, ECM]\n      speed: 2.0\n      loop: true\n'
	p := parse(src) or {
		assert false, '${err}'
		return
	}
	r := p.channels[0].replay or {
		assert false, 'replay missing'
		return
	}

	assert r.bus == 'CAN1'
	assert r.exclude == ['SUT_ECU', 'ECM']
	back := parse(p.to_yaml()) or {
		assert false, 'rewritten project does not parse: ${err}'
		return
	}
	r2 := back.channels[0].replay or {
		assert false, 'replay lost on save'
		return
	}

	assert r2.bus == 'CAN1', 'bus lost on save'
	assert r2.exclude == ['SUT_ECU', 'ECM'], 'exclude lost on save: ${r2.exclude}'
	assert r2.speed == 2.0 && r2.repeat
}

// A Vector channel decomposes to its own adapter, or the GUI cannot offer it and the bitrate
// never reaches the driver — the bug iface_with_bitrate's own comment describes, repeated for
// a new backend.
fn test_vector_iface_decomposes_to_its_adapter() {
	a, addr := decompose_iface('vector:1@500000')
	assert a == 'vector'
	assert addr == '1', 'the bitrate belongs in the bitrate field, not the address'
}

// Listen-only is part of how the channel opens, so it must survive a round trip through the
// project. Dropping it turns a silent bench into one that acknowledges on the next save.
fn test_vector_silent_suffix_survives_decompose() {
	a, addr := decompose_iface('vector:1@500000,silent')
	assert a == 'vector'
	assert addr == '1,silent'
}

fn test_vector_bitrate_is_reappended_at_open() {
	c := Channel{
		iface:   'vector:1'
		adapter: 'vector'
		bitrate: 250000
	}
	assert c.iface_with_bitrate() == 'vector:1@250000'
}

// The inverse of decompose_iface. Without it a channel discovered on Windows composes to a
// bare address, which the dispatcher does not recognise, and Start fails on hardware that is
// sitting right there.
fn test_vector_composes_with_its_prefix() {
	assert compose_iface('vector', '1') == 'vector:1'
	a, addr := decompose_iface(compose_iface('vector', '1'))
	assert a == 'vector'
	assert addr == '1', 'compose then decompose must be the identity'
}

// listen_only is a promise about the WIRE, and Vector is the first backend able to keep it:
// the interface string must carry it through to the transceiver.
fn test_listen_only_becomes_silent_on_vector() {
	c := Channel{
		iface:       'vector:1'
		adapter:     'vector'
		bitrate:     250000
		listen_only: true
	}
	assert c.iface_with_bitrate() == 'vector:1@250000,silent'
}

// A stored interface that already carries the mode keeps ONE of it, and the bitrate goes
// where the parser expects it: `vector:1,silent@500000` reads the rate as part of the mode
// name and the channel is refused outright.
fn test_listen_only_is_not_duplicated_and_bitrate_precedes_it() {
	c := Channel{
		iface:       'vector:1,silent'
		adapter:     'vector'
		listen_only: true
	}
	assert c.iface_with_bitrate() == 'vector:1@500000,silent'
}

// …and a channel that did NOT ask for it must not be silenced: a rest bus that cannot
// acknowledge is a bench that looks connected and answers nothing.
fn test_normal_vector_channel_is_not_silenced() {
	c := Channel{
		iface:   'vector:1'
		adapter: 'vector'
		bitrate: 500000
	}
	assert c.iface_with_bitrate() == 'vector:1@500000'
}

// A v1 project embeds the rate in the interface. Left unlifted, the channel keeps the 500000
// default, and saving migrates it to that default — so the NEXT load activates a live bus at a
// rate the project never asked for.
fn test_legacy_vector_bitrate_is_lifted() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1@250000
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.adapter == 'vector'
	assert c.address == '1'
	assert c.bitrate == 250000, 'the embedded rate must survive a save/load round trip'
	assert c.iface_with_bitrate() == 'vector:1@250000'
}

// …and a v1 iface that asked for listen-only keeps asking for it.
fn test_legacy_vector_silent_becomes_listen_only() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1@250000,silent
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.bitrate == 250000
	assert c.listen_only, 'v1 said it with ,silent; v2 says it with the flag'
	assert c.iface_with_bitrate() == 'vector:1@250000,silent'
}

// `,silent` without a bitrate is a valid legacy spelling. Migrated only alongside a rate, the
// hardware opened silently while the model thought the channel could transmit — the editor
// offering sends that the backend then refuses.
fn test_legacy_vector_silent_without_bitrate_migrates() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1,silent
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.adapter == 'vector'
	assert c.address == '1'
	assert c.listen_only, 'the mode is not a side effect of finding a bitrate'
}

// …and `,normal` asks for the OPPOSITE. Reading any comma as silence turned an explicit
// request to acknowledge into a channel that cannot.
fn test_legacy_vector_normal_is_not_listen_only() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1@250000,normal
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.bitrate == 250000
	assert !c.listen_only, '",normal" is an explicit request to acknowledge'
	assert c.iface_with_bitrate() == 'vector:1@250000'
}

// A MISSPELLED mode must not be quietly dropped: `vector:1,silnt` is plainly a request for
// silence, and stripping it opens the channel normally — acknowledging a live bus. The suffix
// is kept so the transport parser refuses it.
fn test_legacy_vector_unknown_mode_is_not_silently_dropped() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1,silnt
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert !c.listen_only, 'a typo is not a listen-only request we can honour'
	assert c.address.contains(','), 'the bad suffix survives so the open fails loudly'
	assert c.iface_with_bitrate().contains('silnt')
}

// A MALFORMED rate must reach the transport parser too. `vector:1@oops` reads as 0, and
// recomposing a clean interface would drop the evidence and open at the 500 kbit/s default —
// an adapter on a live bus at a rate the project never named.
fn test_legacy_vector_bad_bitrate_is_not_sanitised() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1@oops
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.iface.contains('oops'), 'the bad rate survives so the open fails loudly'
	assert c.iface_with_bitrate().contains('oops')
}

// A rate that is NEARLY a number is not a number. V's `.int()` takes the numeric prefix, so
// `250000garbage` parsed happily and the recomposition dropped the evidence — the adapter then
// opening normally at a rate the project never wrote.
fn test_legacy_vector_partial_bitrate_is_not_accepted() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1@250000garbage,normal
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.iface.contains('garbage'), 'the malformed rate survives so the open fails loudly'
	assert c.bitrate != 250000, 'a prefix that happens to parse is not the configured rate'
}

// A contradictory channel — address says `,normal`, the flag says listen-only — must resolve
// toward silence. It used to resolve toward the transceiver acknowledging, with the application
// still believing the channel was listening quietly.
fn test_listen_only_overrides_an_embedded_normal_mode() {
	c := Channel{
		iface:       'vector:1,normal'
		adapter:     'vector'
		bitrate:     250000
		listen_only: true
	}
	assert c.iface_with_bitrate() == 'vector:1@250000,silent'
}

// A mode written into a v2 ADDRESS must land in the flag, or the port opens silently while the
// model calls the channel transmit-capable — the GUI then offering sends that are refused one
// frame at a time.
fn test_v2_address_silent_lifts_into_listen_only() {
	p := parse('
project:
  name: v2
channels:
  - name: CAN1
    adapter: vector
    address: "1,silent"
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.listen_only, 'one place records this, and it is the flag'
	assert c.address == '1'
	assert c.iface_with_bitrate() == 'vector:1@500000,silent'
}

// One rule for a mode suffix, on every path that can write an address.
fn test_split_vector_mode() {
	a1, s1, ok1 := split_vector_mode('1,silent')
	assert a1 == '1' && s1 && ok1
	a2, s2, ok2 := split_vector_mode('1,normal')
	assert a2 == '1' && !s2 && ok2
	a3, s3, ok3 := split_vector_mode('1')
	assert a3 == '1' && !s3 && ok3
	// An unrecognised one is LEFT ON, so the transport parser refuses it rather than this
	// resolving a typo in the direction that acknowledges.
	a4, s4, ok4 := split_vector_mode('1,silnt')
	assert a4 == '1,silnt' && !s4 && !ok4
}

// A malformed legacy rate must survive a save, or the defence lasts until the first edit.
fn test_bad_legacy_rate_survives_recomposition() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1@oops
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.address.contains('oops'), 'the address is what recomposition reads'
	assert compose_iface(c.adapter, c.address).contains('oops')
}

// A malformed rate is preserved for the transport parser to refuse — on every vendor, and
// without doubling the prefix on the way through.
fn test_bad_legacy_rate_keeps_its_own_prefix() {
	for adapter, iface in {
		'pcan':   'pcan:PCAN_USBBUS1@oops'
		'kvaser': 'kvaser:0@oops'
		'vector': 'vector:1@oops'
	} {
		p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: ${iface}
') or {
			assert false, '${err}'
			return
		}
		c := p.channels[0]
		assert c.adapter == adapter
		assert !c.address.starts_with('${adapter}:'), '${iface}: the prefix belongs to compose, not the address'
		assert compose_iface(c.adapter, c.address) == iface, '${iface}: must round-trip unchanged'
	}
}
