// keys — the ONE table of the keys a `.blobnet` may carry, per section, and where each section
// nests: a key added to the parser is added here, and nowhere else. `unknown_keys` walks a file
// against it and names every key no section lists, with the row, node or generator it sits in;
// the LIN rows refuse by it (lin.v), every other section notes, and a strict load refuses the
// notes (headless.Options.strict).
module project

import yaml

// KeySection is one section's keys, and which of them hold a list of entries, or one mapping, of
// another section.
struct KeySection {
	keys  []string
	lists map[string]string
	maps  map[string]string
}

// key_table is every section by name; `top` is the file itself.
const key_table = build_key_table()

fn build_key_table() map[string]KeySection {
	// a value source's keys, a simulated node's signal and a generator's alike (parse_gencfg)
	mut signal := ['name', 'type']
	signal << wave_param_names
	return {
		'top':         KeySection{
			keys:  ['project', 'buses', 'channels', 'lin']
			lists: {
				'buses':    'row'
				'channels': 'row'
				'lin':      'lin'
			}
			maps:  {
				'project': 'project'
			}
		}
		'project':     KeySection{
			keys: ['name', 'version']
		}
		'row':         KeySection{
			keys:  ['name', 'network', 'adapter', 'address', 'interface', 'protocol', 'type', 'bitrate',
				'fd', 'data_bitrate', 'sample_point', 'data_sample_point', 'mode', 'listen_only',
				'j1939', 'builtin_uds', 'enabled', 'announce_count', 'announce_interval_ms',
				'announce_to', 'group', 'tester_address', 'ecu_address', 'vin', 'eid', 'databases',
				'manifest', 'simulate', 'verify', 'simulation', 'nodes', 'senders', 'diagnostics',
				'nm', 'timing', 'replay', 'fill']
			lists: {
				'verify':      'protect'
				'simulation':  'node'
				'nodes':       'node'
				'senders':     'sender'
				'diagnostics': 'diagnostics'
			}
			maps:  {
				'nm':     'nm'
				'timing': 'timing'
				'replay': 'replay'
			}
		}
		'lin_row':     KeySection{
			keys: ['name', 'network', 'adapter', 'type', 'protocol', 'address', 'interface', 'bitrate',
				'ldf', 'role', 'simulate', 'schedule', 'enabled']
		}
		'lin':         KeySection{
			keys: ['name', 'address', 'bitrate', 'ldf', 'role', 'simulate', 'schedule', 'enabled']
		}
		'timing':      KeySection{
			keys: ['brp', 'tseg1', 'tseg2', 'sjw']
		}
		'replay':      KeySection{
			keys: ['source', 'speed', 'loop', 'bus', 'exclude']
		}
		'nm':          KeySection{
			keys: ['lo', 'hi', 'ext', 'timeout_ms', 'cycle_ms']
		}
		'diagnostics': KeySection{
			keys: ['node', 'odx', 'variant', 'tx', 'rx']
		}
		'protect':     KeySection{
			keys: ['message', 'id', 'extended', 'counter', 'crc', 'profile', 'data_id', 'data_id_mode',
				'offset', 'length']
		}
		'node':        KeySection{
			keys:  ['name', 'node', 'signals', 'uds', 'protect', 'nm', 'responses']
			lists: {
				'signals':   'signal'
				'protect':   'protect'
				'responses': 'response'
			}
			maps:  {
				'uds': 'uds'
				'nm':  'node_nm'
			}
		}
		'signal':      KeySection{
			keys: signal
		}
		'response':    KeySection{
			keys: ['request', 'response', 'byte', 'add']
		}
		'node_nm':     KeySection{
			keys: ['id', 'nid', 'ext']
		}
		'uds':         KeySection{
			keys:  ['rx', 'tx', 'functional', 'session', 'dids', 'dtcs', 'io', 'memory', 'tx_dl']
			lists: {
				'dids':   'did'
				'dtcs':   'dtc'
				'io':     'io'
				'memory': 'memory'
			}
		}
		'did':         KeySection{
			keys: ['id', 'text', 'bytes']
		}
		'dtc':         KeySection{
			keys: ['code', 'status']
		}
		'io':          KeySection{
			keys: ['id', 'size']
		}
		'memory':      KeySection{
			keys: ['address', 'size']
		}
		'sender':      KeySection{
			keys:  ['name', 'key', 'message', 'extended', 'bus', 'trigger', 'cycle_ms', 'id', 'data',
				'format', 'signals', 'fill']
			lists: {
				'signals': 'signal'
			}
		}
	}
}

// known_keys is the keys section `name` lists.
fn known_keys(name string) []string {
	return key_table[name] or { KeySection{} }.keys
}

// unknown_keys names every key of a parsed `.blobnet` that its section does not list, one line
// each, in file order: `unknown key `cycle_msec` in channel "CAN1" / generator "G" (known: …)`.
pub fn unknown_keys(doc yaml.Any) []string {
	mut out := []string{}
	walk_keys(doc, 'top', '', mut out)
	return out
}

// walk_keys checks one mapping against its section and descends into the sections it nests.
fn walk_keys(v yaml.Any, section string, at string, mut out []string) {
	if v !is map[string]yaml.Any {
		return
	}
	sec := key_table[section] or { return }
	for k, val in v.as_map() {
		if k !in sec.keys {
			place := if at == '' { 'at the top of the file' } else { 'in ${at}' }
			out << 'unknown key `${k}` ${place} (known: ${sec.keys.join(', ')})'
			continue
		}
		if child := sec.maps[k] {
			walk_keys(val, child, join_at(at, k), mut out)
		} else if child := sec.lists[k] {
			if val is []yaml.Any {
				for i, e in val {
					// a LIN row of `buses:` has its own keys
					kind := if child == 'row' && is_lin_row(e) { 'lin_row' } else { child }
					walk_keys(e, kind, join_at(at, entry_label(k, e, i)), mut out)
				}
			}
		}
	}
}

// entry_label names a list entry by what it is called, else by its position: `channel "CAN1"`,
// `generator "G"`, `protect "Status"`, `dids #2`.
fn entry_label(key string, e yaml.Any, i int) string {
	what := match key {
		'buses', 'channels' { 'channel' }
		'lin' { 'lin' }
		'simulation', 'nodes' { 'node' }
		'senders' { 'generator' }
		'signals' { 'signal' }
		else { key }
	}
	if e is map[string]yaml.Any {
		for n in ['name', 'node', 'message'] {
			if x := e[n] {
				if x is string {
					return '${what} "${x}"'
				}
			}
		}
	}
	return '${what} #${i + 1}'
}

fn join_at(at string, part string) string {
	return if at == '' { part } else { '${at} / ${part}' }
}
