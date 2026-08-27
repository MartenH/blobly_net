module project

import transport

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

// Two rates is a contradiction the transport parser must get to see. Sanitising it here to the
// last one sent a tidy single rate to the driver and the disagreement was never reported.
fn test_legacy_double_rate_is_preserved() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1@250000@500000
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.iface == 'vector:1@250000@500000'
	assert compose_iface(c.adapter, c.address) == 'vector:1@250000@500000', 'must survive a save'
}

// Preserving a malformed rate must not cost the rest of the channel. An early return here
// skipped databases, nodes, senders and replay config, so opening such a project and saving it
// wrote them away as defaults — losing configuration on a file the user never edited.
fn test_double_rate_channel_keeps_the_rest_of_its_config() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1@250000@500000
    mode: replay
    listen_only: true
    databases:
      - dbc/a.dbc
      - dbc/b.dbc
    replay:
      source: logs/x.mf4
      bus: CAN1
      speed: 2.0
      loop: true
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.iface == 'vector:1@250000@500000', 'the malformed rate still survives'
	assert c.databases.len == 2, 'databases must not be lost'
	assert c.mode == .replay
	assert c.listen_only
	r := c.replay or {
		assert false, 'replay config was lost'
		return
	}

	assert r.source == 'logs/x.mf4'
	assert r.bus == 'CAN1'
	assert r.speed == 2.0
	assert r.repeat
}

// A v1 file that says listen_only explicitly keeps it, even beside a `,normal` suffix. The two
// must not disagree: iface_with_bitrate already makes the flag win over an embedded mode, so
// clearing it here would open a transceiver on a bench that asked for quiet.
fn test_legacy_explicit_listen_only_survives_normal_suffix() {
	p := parse('
project:
  name: legacy
channels:
  - name: CAN1
    interface: vector:1,normal
    listen_only: true
') or {
		assert false, '${err}'
		return
	}
	c := p.channels[0]
	assert c.listen_only, 'the explicit flag wins'
	assert c.iface_with_bitrate().ends_with(',silent')
}

// One wire, one mode and one rate — the rules both front ends must reach the same verdict on.
fn test_destination_conflicts() {
	// A silenced wire cannot carry another row's simulation, even spelled differently.
	quiet := [
		Channel{
			name:        'mon'
			adapter:     'vector'
			iface:       'vector:ch1'
			enabled:     true
			listen_only: true
		},
		Channel{
			name:     'sim'
			adapter:  'vector'
			iface:    'vector:1'
			enabled:  true
			simulate: ['ECU']
		},
	]
	assert destination_conflicts(quiet).len == 1

	// Two rates on one wire.
	rates := [
		Channel{
			name:    'a'
			adapter: 'vector'
			iface:   'vector:1'
			enabled: true
			bitrate: 250000
		},
		Channel{
			name:    'b'
			adapter: 'vector'
			iface:   'vector:ch1'
			enabled: true
			bitrate: 500000
		},
	]
	assert destination_conflicts(rates).len == 1

	// A row that merely WATCHES is no longer excused. A script, Quick Send or the shell can tell
	// any channel to transmit, so its configuration says nothing about whether it will — and two
	// rows disagreeing about the mode of one wire have asked the transceiver for something it
	// cannot do, whoever ends up talking.
	mixed := [
		Channel{
			name:        'mon'
			adapter:     'vector'
			iface:       'vector:1'
			enabled:     true
			listen_only: true
		},
		Channel{
			name:    'watch'
			adapter: 'vector'
			iface:   'vector:ch1'
			enabled: true
		},
	]
	assert destination_conflicts(mixed).len == 1

	// Agreeing is fine, either way round.
	agreed := [
		Channel{
			name:        'a'
			adapter:     'vector'
			iface:       'vector:1'
			enabled:     true
			listen_only: true
		},
		Channel{
			name:        'b'
			adapter:     'vector'
			iface:       'vector:ch1'
			enabled:     true
			listen_only: true
		},
	]
	assert destination_conflicts(agreed).len == 0
}

// The rate is what these rows disagree about, so the key that groups them must not contain it.
// With the rate in the key each row got its own and the check never fired.
fn test_rate_conflict_actually_fires() {
	rows := [
		Channel{
			name:    'a'
			adapter: 'vector'
			iface:   'vector:1'
			enabled: true
			bitrate: 250000
		},
		Channel{
			name:    'b'
			adapter: 'vector'
			iface:   'vector:1'
			enabled: true
			bitrate: 500000
		},
	]
	got := destination_conflicts(rows)
	assert got.len == 1, 'two rates on one wire must be reported, got ${got}'
	assert got[0].contains('250000') && got[0].contains('500000')

	// THE CASE THAT ACTUALLY BROKE IT: the rate carried in the INTERFACE, as a v1 project
	// writes it. destination_key_for keeps that rate in the key, so the two rows were filed
	// under different wires and the disagreement they exist to report was never compared.
	legacy := [
		Channel{
			name:    'a'
			adapter: 'vector'
			iface:   'vector:1@250000'
			enabled: true
			bitrate: 250000
		},
		Channel{
			name:    'b'
			adapter: 'vector'
			iface:   'vector:ch1@500000'
			enabled: true
			bitrate: 500000
		},
	]
	legacy_got := destination_conflicts(legacy)
	assert legacy_got.len == 1, 'one wire, two rates in the interfaces: ${legacy_got}'
}

// Listen-only is enforced on every backend since #117, so a disagreement about it is a conflict
// on every backend too -- not only on Vector, where `,silent` used to be the only version of it
// that did anything. Before, these rows started happily and the software row simply transmitted.
fn test_listen_only_conflicts_on_non_vendor_wires() {
	rows := [
		Channel{
			name:        'watch'
			iface:       'vcan0'
			enabled:     true
			listen_only: true
		},
		Channel{
			name:     'drive'
			iface:    'vcan0'
			enabled:  true
			simulate: ['ECU']
		},
	]
	got := destination_conflicts(rows)
	assert got.len == 1
	assert got[0].contains('watch')

	// A disabled row states nothing.
	mut off := rows.clone()
	off[0].enabled = false
	assert destination_conflicts(off).len == 0

	// Two rows that AGREE are not a conflict, however many of them there are.
	agreed := [
		Channel{
			name:        'a'
			iface:       'vcan0'
			enabled:     true
			listen_only: true
		},
		Channel{
			name:        'b'
			iface:       'vcan0'
			enabled:     true
			listen_only: true
		},
	]
	assert destination_conflicts(agreed).len == 0
}

// `@` is a bitrate on a vendor address and part of the NAME on a software bus. Grouped by a key
// that cut at it, two unrelated in-process hubs would be reported as one contended wire.
fn test_at_sign_does_not_merge_software_buses() {
	rows := [
		Channel{
			name:        'quiet'
			iface:       'inproc:bench@A'
			enabled:     true
			listen_only: true
		},
		Channel{
			name:     'loud'
			iface:    'inproc:bench@B'
			enabled:  true
			simulate: ['ECU']
		},
	]
	assert destination_conflicts(rows).len == 0
}

// apply_listen_only registers ENABLED CAN rows only. A disabled row states nothing about the
// wire -- and destination_conflicts skips disabled rows too, so a disabled row silencing an
// enabled sibling would be a contradiction nothing could warn about. A DoIP row addresses a TCP
// endpoint rather than a wire, and its editor never draws the tick.
fn test_apply_listen_only_registers_enabled_can_rows_only() {
	transport.clear_listen_only()
	p := Project{
		channels: [
			Channel{
				name:        'on'
				iface:       'inproc:lo_on'
				enabled:     true
				listen_only: true
			},
			Channel{
				name:        'off'
				iface:       'inproc:lo_off'
				enabled:     false
				listen_only: true
			},
			Channel{
				name:        'plain'
				iface:       'inproc:lo_plain2'
				enabled:     true
				listen_only: false
			},
		]
	}
	apply_listen_only(p.channels)
	assert transport.is_listen_only('inproc:lo_on')
	assert !transport.is_listen_only('inproc:lo_off'), 'a disabled row silenced a wire'
	assert !transport.is_listen_only('inproc:lo_plain2')

	// Applying a project REPLACES the previous one's marks, so a wire reused by the next
	// project is not silenced by a tick it never carried.
	next := Project{
		channels: [
			Channel{
				name:    'on'
				iface:   'inproc:lo_on'
				enabled: true
			},
		]
	}
	apply_listen_only(next.channels)
	assert !transport.is_listen_only('inproc:lo_on')
	transport.clear_listen_only()
}

// ---- CAN-FD reaches the wire -------------------------------------------------------------
//
// `fd` and `data_bitrate` were in the schema, in the save file and in the editor, and reached no
// transport at all: the address is everything `open` is handed, so a canfd Vector row opened
// CLASSIC and then refused every FD frame one at a time at send(). This is the test that the
// project's answer and the wire's are the same answer.
fn test_a_canfd_vector_channel_carries_its_data_phase_into_the_address() {
	c := Channel{
		adapter:      'vector'
		address:      '1'
		iface:        'vector:1'
		typ:          'canfd'
		fd:           true
		bitrate:      500000
		data_bitrate: 2000000
	}
	assert c.iface_with_bitrate() == 'vector:1@500000/2000000'
	// With listen-only, the mode still goes on the END — after the whole rate, not inside it.
	quiet := Channel{
		...c
		listen_only: true
	}
	assert quiet.iface_with_bitrate() == 'vector:1@500000/2000000,silent'
}

// A row marked FD with no data bitrate is FD at its arbitration rate — 64-byte payloads, no
// bit-rate switch. Dropping the flag instead would silently downgrade it to classic, which is
// the failure above wearing a different hat.
fn test_canfd_without_a_data_bitrate_defaults_to_the_arbitration_rate() {
	c := Channel{
		adapter: 'vector'
		iface:   'vector:2'
		fd:      true
		bitrate: 500000
	}
	assert c.iface_with_bitrate() == 'vector:2@500000/500000'
}

// CLASSIC STAYS CLASSIC, and on the other backends nothing changes: PCAN and Kvaser refuse FD, so
// composing a data phase into their addresses would produce a string their parsers reject.
fn test_a_data_phase_is_composed_only_where_it_can_be_configured() {
	classic := Channel{
		adapter: 'vector'
		iface:   'vector:1'
		bitrate: 500000
	}
	assert classic.iface_with_bitrate() == 'vector:1@500000'
	pc := Channel{
		adapter: 'pcan'
		iface:   'pcan:PCAN_USBBUS1'
		fd:      true
		bitrate: 500000
	}
	assert pc.iface_with_bitrate() == 'pcan:PCAN_USBBUS1@500000', 'PCAN refuses FD; its address must not claim it'
}

// ONE WIRE, ONE PROTOCOL — the same rule as one mode and one rate, and refused from the file
// rather than as a channel that fails to open halfway through a Start.
fn test_two_rows_on_one_wire_must_agree_about_fd() {
	base := Channel{
		adapter: 'vector'
		address: '1'
		iface:   'vector:1'
		bitrate: 500000
		enabled: true
	}
	fd_row := Channel{
		...base
		name:         'FD'
		fd:           true
		data_bitrate: 2000000
	}
	classic_row := Channel{
		...base
		name: 'Classic'
	}
	msgs := destination_conflicts([fd_row, classic_row])
	assert msgs.len > 0, 'a wire asked to be both CAN-FD and classic must be refused'
	assert msgs.any(it.contains('CAN-FD') && it.contains('classic CAN')), 'the message must name both protocols, got ${msgs}'

	// Agreeing rows are not a conflict — including two FD rows at the same data rate.
	same := destination_conflicts([fd_row, Channel{
		...fd_row
		name: 'FD again'
	}])
	assert same.len == 0, 'two rows agreeing about FD is not a conflict: ${same}'

	// …and two FD rows that disagree about the DATA rate are, which a check on the flag alone
	// would have waved through.
	faster := destination_conflicts([fd_row, Channel{
		...fd_row
		name:         'FD fast'
		data_bitrate: 4000000
	}])
	assert faster.len > 0, 'one wire cannot run two data phases'
}

// A row on a DIFFERENT wire is not a conflict, however it is configured — the grouping is by
// wire, and a bug there would report conflicts across a whole bench.
fn test_fd_disagreement_is_per_wire() {
	a := Channel{
		adapter:      'vector'
		name:         'FD'
		iface:        'vector:1'
		bitrate:      500000
		fd:           true
		data_bitrate: 2000000
		enabled:      true
	}
	b := Channel{
		adapter: 'vector'
		name:    'Classic'
		iface:   'vector:3'
		bitrate: 500000
		enabled: true
	}
	assert destination_conflicts([a, b]).len == 0
}

// An FD row on a backend that refuses FD is a warning at Start, not a refusal (issue #170): the
// classic half of such a run is real, so taking the run away would remove something that works.
// What must not happen is silence — replay counts refused frames and keeps going, so the operator
// reads a successful measurement that is missing traffic.
fn test_an_fd_row_on_a_backend_that_refuses_fd_warns() {
	pc := Channel{
		name:    'PCAN FD'
		adapter: 'pcan'
		address: 'PCAN_USBBUS1'
		iface:   'pcan:PCAN_USBBUS1'
		fd:      true
		enabled: true
	}
	w := fd_capability_warnings([pc])
	assert w.len == 1, 'expected one warning, got ${w}'
	assert w[0].contains('PCAN FD') && w[0].contains('pcan')

	// It is NOT a destination_conflicts entry — everything there refuses the project.
	assert destination_conflicts([pc]) == [], 'an FD row on PCAN must not stop the run'
}

fn test_fd_capability_warnings_stay_quiet_where_fd_works() {
	for adapter, address in {
		'vector':    '1'
		'socketcan': 'can0'
		'vcan':      'vcan0'
		'virtual':   'CAN1'
		'udp':       '239.0.0.1:5000'
	} {
		c := Channel{
			name:    adapter
			adapter: adapter
			address: address
			iface:   address
			fd:      true
			enabled: true
		}
		assert fd_capability_warnings([c]) == [], '${adapter} carries FD; it must not warn'
		assert c.can_carry_fd(), '${adapter} carries FD'
	}
}

// DISABLED ROWS HAVE NO SAY, the rule every check here follows — and a CLASSIC row on PCAN is
// perfectly ordinary, so the warning must key on `fd` rather than on the adapter alone.
fn test_fd_capability_warnings_ignore_disabled_and_classic_rows() {
	off := Channel{
		name:    'off'
		adapter: 'pcan'
		iface:   'pcan:PCAN_USBBUS1'
		fd:      true
		enabled: false
	}
	classic := Channel{
		name:    'classic'
		adapter: 'pcan'
		iface:   'pcan:PCAN_USBBUS1'
		enabled: true
	}
	assert fd_capability_warnings([off, classic]) == []
}

// A DoIP row marked canfd is a different mistake, and saying "this backend refuses CAN-FD" about
// an Ethernet channel would answer a question nobody asked.
fn test_a_doip_row_marked_canfd_is_told_what_it_actually_is() {
	d := Channel{
		name:    'ECU'
		adapter: 'doip'
		address: '10.0.0.2'
		iface:   'doip:10.0.0.2'
		typ:     'doip'
		fd:      true
		enabled: true
	}
	w := fd_capability_warnings([d])
	assert w.len == 1
	assert w[0].contains('DoIP') && w[0].contains('does not apply')
	assert !w[0].contains('refuses'), 'a DoIP channel is not a CAN backend that refuses FD'
}

// ---- codex #181 r2 -------------------------------------------------------------------------

// A v1 project may carry the FD address form this release documents. Left to the digits-only
// rule it was "not a number", so the whole spec was preserved verbatim AND another @rate was
// appended — producing two rate separators, which the strict parser then refused. A legacy
// project could not use the advertised form at all.
fn test_a_v1_interface_carrying_both_phases_is_migrated() {
	p := parse('
channels:
  - name: FD
    interface: vector:1@500000/2000000
') or {
		assert false, 'must parse: ${err}'
		return
	}
	c := p.channels[0]
	assert c.adapter == 'vector'
	assert c.bitrate == 500000, 'arbitration phase lifted, got ${c.bitrate}'
	assert c.fd, 'the second rate is what marks the row CAN-FD'
	assert c.data_bitrate == 2000000, 'data phase lifted, got ${c.data_bitrate}'
	// And it recomposes to exactly one rate, not the doubled address that was refused.
	assert c.iface_with_bitrate() == 'vector:1@500000/2000000'
	assert c.iface_with_bitrate().count('@') == 1
}

// A malformed two-phase rate must still be PRESERVED rather than migrated, so the transport
// parser refuses it with the evidence intact instead of the address quietly opening at a default.
fn test_a_malformed_v1_fd_rate_is_still_preserved() {
	p := parse('
channels:
  - name: bad
    interface: vector:1@500000/oops
') or {
		assert false, 'must parse: ${err}'
		return
	}
	c := p.channels[0]
	assert !c.fd, 'a rate that is not a number must not be migrated into an FD configuration'
	assert c.iface.contains('oops'), 'the evidence has to survive, got ${c.iface}'
}

// An FD row with no nominal rate opened CLASSIC while fd_wanted read the same unset value as the
// 500 kbit/s default and reported the wire as CAN-FD — the project refusing a mixture on a wire
// it was itself opening as the other half of that mixture.
fn test_fd_survives_an_unset_nominal_rate() {
	c := Channel{
		adapter:      'vector'
		iface:        'vector:1'
		fd:           true
		bitrate:      0
		data_bitrate: 2000000
	}
	got := c.iface_with_bitrate()
	assert got == 'vector:1@${default_bitrate}/2000000', 'got ${got}'
	// The address and the conflict check must agree about what this row is.
	assert fd_wanted(c) == 2000000
}

// The same, with no data rate either: FD at the default nominal rate, not a silent downgrade.
fn test_fd_with_nothing_set_is_fd_at_the_default_rate() {
	c := Channel{
		adapter: 'vector'
		iface:   'vector:1'
		fd:      true
		bitrate: 0
	}
	assert c.iface_with_bitrate() == 'vector:1@${default_bitrate}/${default_bitrate}'
	assert fd_wanted(c) == default_bitrate
}

fn test_is_all_digits_refuses_a_partial_number() {
	assert is_all_digits('2000000')
	assert !is_all_digits('2000000oops')
	assert !is_all_digits('oops')
	assert !is_all_digits('')
	assert !is_all_digits('2000 000')
	assert !is_all_digits('-2000000')
}

// A rate is digits or it is not a rate — in the FILE too, not only in the editor buffer. The
// round-2 fix guarded the GUI field and left the YAML it saves to unguarded, so the Configuration
// File tab and the headless runner could run a data phase different from the one the project
// states (codex #181 r3).
fn test_a_malformed_data_bitrate_in_the_file_is_refused() {
	for bad in ['2000000oops', 'oops', '2000 000', '-2000000'] {
		if p := parse('
channels:
  - name: FD
    adapter: vector
    address: "1"
    fd: true
    bitrate: 500000
    data_bitrate: ${bad}
')
		{
			assert false, '"${bad}" must not load (got data_bitrate ${p.channels[0].data_bitrate})'
		}
	}
	// …and a well-formed one still loads and reaches the address.
	ok := parse('
channels:
  - name: FD
    adapter: vector
    address: "1"
    fd: true
    bitrate: 500000
    data_bitrate: 2000000
') or {
		assert false, 'a valid rate must load: ${err}'
		return
	}
	assert ok.channels[0].data_bitrate == 2000000
	assert ok.channels[0].iface_with_bitrate() == 'vector:1@500000/2000000'
}

// The editor and the opener must agree about a pair of rates. Digits-only says nothing about
// whether the two phases make sense TOGETHER, so a data phase slower than the arbitration phase
// was accepted, persisted, and refused only at Start (codex #183 r1).
fn test_address_config_error_asks_the_real_parser() {
	base := Channel{
		adapter: 'vector'
		iface:   'vector:1'
		fd:      true
		bitrate: 500000
	}
	// A slower data phase is not a configuration any FD channel can open.
	slow := Channel{
		...base
		data_bitrate: 250000
	}
	if why := slow.address_config_error() {
		assert why.contains('slower') || why.contains('data'), 'unhelpful message: ${why}'
	} else {
		assert false, 'a data phase below the arbitration rate must be reported'
	}
	// Past the range the standard allows.
	if _ := Channel{
		...base
		data_bitrate: 9_000_000
	}.address_config_error()
	{
	} else {
		assert false, '9 Mbit/s is past what ISO 11898-1 allows'
	}
	// The ordinary cases are fine, including FD with no bit-rate switch.
	for ok in [2_000_000, 8_000_000, 500_000] {
		c := Channel{
			...base
			data_bitrate: ok
		}
		if why := c.address_config_error() {
			assert false, '${ok} must be accepted: ${why}'
		}
	}
	// An unset data rate means "at the nominal rate", which is legal.
	if why := base.address_config_error() {
		assert false, 'an unset data rate must default, not fail: ${why}'
	}
	// A classic row has no FD rates to be wrong about, and neither has a backend that refuses FD.
	classic := Channel{
		...base
		fd: false
	}
	if _ := classic.address_config_error() {
		assert false, 'a classic row has no data phase'
	}
	pc := Channel{
		...base
		adapter:      'pcan'
		data_bitrate: 250000
	}
	if _ := pc.address_config_error() {
		assert false, 'PCAN cannot configure a data phase; fd_capability_warnings covers that row'
	}
}

// A RATE LEFT IN THE ADDRESS FIELD IS REFUSED, not quietly honoured. `iface_with_bitrate()`
// appends the row's rate fields, so a suffix in the address is either duplicated — two `@`, which
// the parser rejects — or, when the nominal field is unset, passed through untouched. In that case
// the backend opens at the address's rate while `nominal_bitrate()` and `destination_conflicts()`
// model the row at the default, so a rate conflict on that wire goes unnoticed and the controller
// runs at a rate the editor never showed (codex round 8 on #204).
fn test_a_cansub_address_with_a_rate_suffix_is_refused() {
	c := Channel{
		name:    'CAN1'
		adapter: 'cansub'
		address: '1A2B3C4D/1@250000'
		iface:   'cansub:1A2B3C4D/1@250000'
	}
	why := c.address_config_error() or {
		assert false, 'a rate in the address field must be refused'
		return
	}
	assert why.contains('250000') || why.contains('address'), 'the refusal must point at the field: ${why}'
}

// Including when the row also has rate fields set — that is the two-`@` case, and it must be
// refused here rather than deep in a parser at Start.
fn test_a_cansub_address_with_a_rate_suffix_is_refused_even_with_rate_fields() {
	c := Channel{
		name:    'CAN1'
		adapter: 'cansub'
		address: '1A2B3C4D/1@250000'
		iface:   'cansub:1A2B3C4D/1@250000'
		bitrate: 500000
	}
	if _ := c.address_config_error() {
	} else {
		assert false, 'a rate in the address field must be refused whatever the rate fields say'
	}
}

// A plain address is what the editor is asking for, and it must still pass.
fn test_a_plain_cansub_address_is_accepted() {
	c := Channel{
		name:    'CAN1'
		adapter: 'cansub'
		address: '1A2B3C4D/1'
		iface:   'cansub:1A2B3C4D/1'
		bitrate: 500000
	}
	if why := c.address_config_error() {
		assert false, 'an ordinary CANsub row must be accepted: ${why}'
	}
}

// A SAMPLE POINT THE BACKEND CANNOT BE TOLD ABOUT IS REFUSED, not ignored. The CANsub address
// carries a device, a channel and rates — there is nowhere in it for a sample point, so the solver
// is always asked for the 80% default. A project setting 75% for a long bus ran timing it never
// asked for, and the errors that produces appear under load and nowhere else (codex round 10).
fn test_a_cansub_row_with_an_unsupported_sample_point_is_refused() {
	c := Channel{
		name:         'CAN1'
		adapter:      'cansub'
		address:      '1A2B3C4D/1'
		iface:        'cansub:1A2B3C4D/1'
		bitrate:      500000
		sample_point: 75.0
	}
	why := c.address_config_error() or {
		assert false, 'a sample point this backend cannot honour must be refused'
		return
	}
	assert why.contains('75'), 'the refusal must name the value: ${why}'
}

// Unset is the ordinary case and must pass, as must the value the backend actually uses.
fn test_a_cansub_row_without_a_sample_point_is_accepted() {
	base := Channel{
		name:    'CAN1'
		adapter: 'cansub'
		address: '1A2B3C4D/1'
		iface:   'cansub:1A2B3C4D/1'
		bitrate: 500000
	}
	if why := base.address_config_error() {
		assert false, 'an unset sample point is the ordinary case: ${why}'
	}
	at_default := Channel{
		...base
		sample_point: 80.0
	}
	if why := at_default.address_config_error() {
		assert false, 'asking for what it already does is not a conflict: ${why}'
	}
}

// THE SHARED START CHECK MUST ASK THE SAME QUESTIONS THE EDITOR DOES. Until now
// `address_config_error` had exactly one caller — the GUI editor — so everything it refuses was
// enforced while somebody typed and enforced nowhere at all for a `.blobnet` started headless,
// which calls `check_destinations` and went straight past it (codex round 11 on #204).
fn test_the_shared_check_refuses_a_row_the_editor_would_refuse() {
	bad := Channel{
		name:         'CAN1'
		adapter:      'cansub'
		address:      '1A2B3C4D/1'
		iface:        'cansub:1A2B3C4D/1'
		bitrate:      500000
		sample_point: 75.0
		enabled:      true
	}
	d := check_destinations([bad])
	assert d.problems.len > 0, 'a row the editor refuses must not start headless either'
	assert d.problems[0].contains('CAN1'), 'and the problem must name the row: ${d.problems}'
}

// A DISABLED row is not going to be opened, so it must not stop a start — the same rule every
// other check here follows.
fn test_the_shared_check_ignores_a_disabled_row() {
	off := Channel{
		name:         'CAN1'
		adapter:      'cansub'
		address:      '1A2B3C4D/1'
		iface:        'cansub:1A2B3C4D/1'
		bitrate:      500000
		sample_point: 75.0
		enabled:      false
	}
	d := check_destinations([off])
	assert d.problems.len == 0, 'refusing to start over a wire nobody asked for: ${d.problems}'
}

fn test_the_shared_check_passes_an_ordinary_row() {
	ok := Channel{
		name:    'CAN1'
		adapter: 'cansub'
		address: '1A2B3C4D/1'
		iface:   'cansub:1A2B3C4D/1'
		bitrate: 500000
		enabled: true
	}
	d := check_destinations([ok])
	assert d.problems.len == 0, 'an ordinary CANsub row must start: ${d.problems}'
}

// A FRACTION IS NOT ITS INTEGER PART. `int(80.5)` is 80, so a row asking for 80.5% passed the
// check and then ran at exactly 80% — the same silent substitution one decimal place down.
fn test_a_fractional_sample_point_near_the_default_is_still_refused() {
	for sp in [80.5, 80.999, 79.5] {
		c := Channel{
			name:         'CAN1'
			adapter:      'cansub'
			address:      '1A2B3C4D/1'
			iface:        'cansub:1A2B3C4D/1'
			bitrate:      500000
			sample_point: sp
		}
		if _ := c.address_config_error() {
		} else {
			assert false, '${sp}% is not what the backend configures, so it must be refused'
		}
	}
}
