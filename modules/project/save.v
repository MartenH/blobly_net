// project/save — serialize a Project back to the `.yml` schema (inverse of parse).
//
// Emits the per-channel simulated ECUs under `simulation:` (the new key that keeps
// the simulation workload visually separate from the bus config; `nodes:` stays a
// read-only alias on parse). Only meaningful fields are written so files stay clean,
// and the output round-trips through parse() — see save_test.v.
module project

import os
import strings

// to_yaml renders the project as a `.yml` document.
pub fn (p Project) to_yaml() string {
	mut b := strings.new_builder(1024)
	b.writeln('project:')
	b.writeln('  name: ${p.name}')
	b.writeln('  version: ${schema_version}') // we always write the current format
	b.writeln('')
	b.writeln('channels:')
	for ch in p.channels {
		b.writeln('  - name: ${ch.name}')
		b.writeln('    type: ${ch.typ}')
		b.writeln('    interface: ${ch.iface}')
		b.writeln('    bitrate: ${ch.bitrate}')
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
		if ch.databases.len > 0 {
			b.writeln('    databases:')
			for d in ch.databases {
				b.writeln('      - ${d}')
			}
		}
		if ch.simulate.len > 0 {
			b.writeln('    simulate:')
			for s in ch.simulate {
				b.writeln('      - ${s}')
			}
		}
		if ch.nodes.len > 0 {
			b.writeln('    simulation:')
			for node in ch.nodes {
				b.writeln('      - name: ${node.name}')
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
			}
		}
		if replay := ch.replay {
			b.writeln('    replay:')
			b.writeln('      source: ${replay.source}')
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

// num formats an f64 without a trailing `.0` when it's integral (cleaner files).
fn num(v f64) string {
	if v == f64(int(v)) {
		return '${int(v)}'
	}
	return '${v}'
}
