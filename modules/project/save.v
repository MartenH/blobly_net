// project/save — serialize a Project back to the `.yml` schema (inverse of parse).
//
// Emits the per-channel simulated ECUs under `simulation:` (the new key that keeps
// the simulation workload visually separate from the bus config; `nodes:` stays a
// read-only alias on parse). Only meaningful fields are written so files stay clean,
// and the output round-trips through parse() — see save_test.v.
module project

import doip
import os
import strings

// to_yaml renders the project as a `.yml` document.
pub fn (p Project) to_yaml() string {
	mut b := strings.new_builder(1024)
	b.writeln('project:')
	b.writeln('  name: ${p.name}')
	b.writeln('  version: ${schema_version}') // we always write the current format
	b.writeln('')
	b.writeln('buses:')
	for ch in p.channels {
		// Effective adapter/address. adapter+address are the v2 source of truth (iface is
		// derived); but some callers (tests, defaults) instead set `iface` directly and leave
		// adapter/address at the struct default (vcan/vcan0 → `vcan0`). Only in THAT case does
		// the raw iface win — otherwise explicit v2 adapter/address stays authoritative (so a
		// `Channel{adapter:'virtual', address:'CAN1'}` isn't serialized as vcan0).
		mut adapter := ch.adapter
		mut address := ch.address
		if compose_iface(adapter, address) == 'vcan0' && ch.iface != 'vcan0' {
			adapter, address = decompose_iface(ch.iface)
		}
		b.writeln('  - name: ${yaml_scalar(ch.name)}')
		if ch.network != '' {
			b.writeln('    network: ${yaml_scalar(ch.network)}')
		}
		b.writeln('    adapter: ${adapter}')
		if address != '' {
			b.writeln('    address: ${yaml_scalar(address)}')
		}
		if !ch.is_doip() {
			b.writeln('    protocol: ${ch.typ}')
			b.writeln('    bitrate: ${ch.bitrate}')
		}
		if ch.fd {
			b.writeln('    fd: true')
			if ch.data_bitrate > 0 {
				b.writeln('    data_bitrate: ${ch.data_bitrate}')
			}
		}
		if ch.sample_point != 0 {
			b.writeln('    sample_point: ${num(ch.sample_point)}')
		}
		b.writeln('    mode: ${ch.mode}')
		if ch.listen_only {
			b.writeln('    listen_only: true')
		}
		b.writeln('    enabled: ${ch.enabled}')
		if ch.timing.brp != 0 || ch.timing.tseg1 != 0 || ch.timing.tseg2 != 0 {
			b.writeln('    timing: { brp: ${ch.timing.brp}, tseg1: ${ch.timing.tseg1}, tseg2: ${ch.timing.tseg2}, sjw: ${ch.timing.sjw} }')
		}
		if ch.is_doip() {
			b.writeln('    tester_address: "0x${ch.tester_addr:04X}"')
			b.writeln('    ecu_address: "0x${ch.ecu_addr:04X}"')
			if ch.vin != '' {
				b.writeln('    vin: ${yaml_scalar(ch.vin)}')
			}
			if ch.eid.len > 0 {
				b.writeln('    eid: ${hex_bytes(ch.eid)}')
			}
			// Written because they are READ. A field the parser takes and the writer drops is
			// deleted by the first save — an ECU configured `announce_count: 0` would come
			// back announcing three times, which is the opposite of what it was set to.
			if ch.announce_count != doip.announce_num_default {
				b.writeln('    announce_count: ${ch.announce_count}')
			}
			if ch.announce_interval != doip.announce_interval_default {
				b.writeln('    announce_interval_ms: ${ch.announce_interval}')
			}
			if ch.announce_to != '' {
				b.writeln('    announce_to: ${yaml_scalar(ch.announce_to)}')
			}
		}
		if ch.databases.len > 0 {
			b.writeln('    databases:')
			for d in ch.databases {
				b.writeln('      - ${yaml_scalar(d)}')
			}
		}
		if ch.manifest != '' {
			b.writeln('    manifest: ${yaml_scalar(ch.manifest)}')
		}
		// verify: MUST be written back, like protect: and uds: before it. A field the parser
		// reads and the writer drops loads configured and saves empty, so the checks on the ECU
		// under test silently disappear the first time the project is saved.
		if ch.verify.len > 0 {
			b.writeln('    verify:')
			for pr in ch.verify {
				b.writeln('      - ${protect_inline(pr)}')
			}
		}
		if ch.simulate.len > 0 {
			b.writeln('    simulate:')
			for s in ch.simulate {
				b.writeln('      - ${yaml_scalar(s)}')
			}
		}
		if ch.nodes.len > 0 {
			b.writeln('    simulation:')
			for node in ch.nodes {
				b.writeln('      - name: ${yaml_scalar(node.name)}')
				if node.signals.len > 0 {
					b.writeln('        signals:')
					for g in node.signals {
						b.writeln('          - ${gen_inline(g)}')
					}
				}
				if node.responses.len > 0 {
					b.writeln('        responses:')
					for r in node.responses {
						b.writeln('          - { request: "0x${r.request:X}", response: "0x${r.response:X}", byte: ${r.byte}, add: ${r.add} }')
					}
				}
				// Like `protect` below: a field the parser reads and the writer drops loads
				// configured and saves empty, so the diagnostic addresses silently revert to
				// the channel default and the tester talks to a different ECU than yesterday.
				if u := node.uds {
					b.writeln('        uds:')
					// A DoIP node has no CAN identifiers — it is addressed by the channel's
					// logical pair. Writing them unconditionally turned a deliberately absent
					// pair into `rx: "0x0"` / `tx: "0x0"` on the first save, so the tool's own
					// output then tripped its own "rx/tx are ignored here" warning.
					if !ch.is_doip() {
						b.writeln('          rx: "0x${u.rx:X}"')
						b.writeln('          tx: "0x${u.tx:X}"')
					}
					if u.session != 1 {
						b.writeln('          session: ${u.session}')
					}
					if u.dids.len > 0 {
						b.writeln('          dids:')
						for d in u.dids {
							if d.bytes.len > 0 {
								hex := d.bytes.map('${it:02X}').join(' ')
								b.writeln('            - { id: "0x${d.id:X}", bytes: "${hex}" }')
							} else {
								// ALWAYS quoted: yaml_scalar's rules are for block scalars and
								// only inspect the first character, so "ACME,INC" came out bare
								// inside { } and the comma started another flow entry — the
								// project then failed to reopen, or reopened truncated.
								b.writeln('            - { id: "0x${d.id:X}", text: ${yaml_flow_scalar(d.text)} }')
							}
						}
					}
					if u.dtcs.len > 0 {
						b.writeln('          dtcs:')
						for t in u.dtcs {
							b.writeln('            - { code: "0x${t.code:06X}", status: ${t.status} }')
						}
					}
				}
				// Protection MUST be written back. A field the parser reads and the writer drops
				// is worse than one that was never supported: the project loads protected, saves
				// unprotected, and the next run transmits frames the ECU rejects — with the
				// config that would explain it already gone from the file.
				if node.protect.len > 0 {
					b.writeln('        protect:')
					for pr in node.protect {
						b.writeln('          - ${protect_inline(pr)}')
					}
				}
			}
		}
		if ch.senders.len > 0 {
			b.writeln('    senders:')
			for s in ch.senders {
				b.writeln('      - name: ${yaml_scalar(s.name)}')
				if s.key != '' {
					b.writeln('        key: ${yaml_scalar(s.key)}')
				}
				if s.message != '' {
					b.writeln('        message: ${yaml_scalar(s.message)}')
				}
				if s.id != 0 {
					b.writeln('        id: "0x${s.id:X}"')
				}
				if s.ext {
					b.writeln('        extended: true')
				}
				if s.data.len > 0 {
					b.writeln('        data: ${hex_bytes(s.data)}')
				}
				if s.bus != '' {
					b.writeln('        bus: ${yaml_scalar(s.bus)}')
				}
				b.writeln('        trigger: ${s.trigger}')
				if s.trigger == 'cyclic' && s.cycle_ms > 0 {
					b.writeln('        cycle_ms: ${s.cycle_ms}')
				}
				if s.signals.len > 0 {
					b.writeln('        signals:')
					for sg in s.signals {
						b.writeln('          - { name: ${sg.name}, value: ${num(sg.value)} }')
					}
				}
			}
		}
		if replay := ch.replay {
			b.writeln('    replay:')
			b.writeln('      source: ${yaml_scalar(replay.source)}')
			if replay.bus != '' {
				b.writeln('      bus: ${yaml_scalar(replay.bus)}')
			}
			if replay.exclude.len > 0 {
				b.writeln('      exclude: [${replay.exclude.map(yaml_scalar(it)).join(', ')}]')
			}
			b.writeln('      speed: ${num(replay.speed)}')
			b.writeln('      loop: ${replay.repeat}')
		}
	}
	return b.str()
}

// save writes the project to a `.yml` file.
pub fn (p Project) save(path string) ! {
	os.write_file(path, p.to_yaml())!
}

// gen_inline renders one signal generator as a compact flow mapping, emitting only
// the params relevant to its type (matching the hand-written demo style).
fn gen_inline(g GenCfg) string {
	mut parts := ['name: ${g.signal}', 'type: ${g.typ}']
	match g.typ {
		'const' {
			parts << 'value: ${num(g.value)}'
		}
		'sine' {
			parts << 'offset: ${num(g.offset)}'
			parts << 'amplitude: ${num(g.amplitude)}'
			parts << 'freq: ${num(g.freq)}'
			parts << 'phase: ${num(g.phase)}'
		}
		'sawtooth' {
			parts << 'min: ${num(g.min)}'
			parts << 'max: ${num(g.max)}'
			parts << 'period: ${num(g.period)}'
		}
		'counter' {
			parts << 'start: ${num(g.start)}'
			parts << 'step: ${num(g.step)}'
			parts << 'modulo: ${num(g.modulo)}'
		}
		'stepmod' {
			parts << 'period: ${num(g.period)}'
			parts << 'count: ${num(g.count)}'
			parts << 'base: ${num(g.base)}'
		}
		else {}
	}
	return '{ ${parts.join(', ')} }'
}

// yaml_scalar renders a string as a YAML scalar, double-quoting it when a bare value would
// be misparsed — empty, a leading indicator char (so a bracketed IPv6 address `[::1]:13400`
// stays a scalar and isn't read as flow syntax), an embedded `: ` / ` #`, a newline, or a
// trailing space. Plain values (can0, PCAN_USBBUS1, 127.0.0.1:13400, paths) pass through bare.
// yaml_flow_scalar quotes unconditionally, for values written inside a `{ ... }` flow mapping
// where a bare comma, brace or bracket would be read as structure rather than text.
// protect_inline renders one protection entry as a flow mapping. Shared by a node's `protect:`
// and a channel's `verify:` — the same shape from opposite ends of the wire, so one writer.
fn protect_inline(pr ProtectCfg) string {
	mut parts := ['message: ${yaml_flow_scalar(pr.message)}']
	if mid := pr.id {
		parts << 'id: "0x${mid:X}"'
	}
	if mext := pr.extended {
		parts << 'extended: ${mext}'
	}
	if pr.counter != '' {
		parts << 'counter: ${yaml_flow_scalar(pr.counter)}'
	}
	if pr.crc != '' {
		parts << 'crc: ${yaml_flow_scalar(pr.crc)}'
		parts << 'profile: ${yaml_flow_scalar(pr.profile)}'
	}
	if id := pr.data_id {
		parts << 'data_id: ${id}' // written even when 0 — it is a real id
	}
	return '{ ${parts.join(', ')} }'
}

fn yaml_flow_scalar(s string) string {
	return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
}

fn yaml_scalar(s string) string {
	if s == '' {
		return '""'
	}
	indicators := '[]{},#&*!|>\'"%@?:- '
	needs := s[0] in indicators.bytes() || s.contains(': ') || s.contains(' #')
		|| s.contains('\n') || s[s.len - 1] == ` `
	if !needs {
		return s
	}
	return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
}

// hex_bytes renders a raw payload as space-separated hex (round-trips through
// parse_hex_bytes): [0xDE,0xAD] -> "DE AD".
fn hex_bytes(data []u8) string {
	mut parts := []string{}
	for b in data {
		parts << '${b:02X}'
	}
	return parts.join(' ')
}

// num formats an f64 without a trailing `.0` when it's integral (cleaner files).
fn num(v f64) string {
	if v == f64(int(v)) {
		return '${int(v)}'
	}
	return '${v}'
}
