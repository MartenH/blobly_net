// lin — the project's LIN buses: a top-level `lin:` list, kept apart from `buses:` on purpose.
// A LIN bus is never a row of `channels`, so nothing that reads the CAN and Ethernet rows meets
// one. Plain strings and ints here; `blobly/lin` turns a bus into a running row (headless).
module project

import yaml

// LinBus is one entry of the `lin:` list.
pub struct LinBus {
pub mut:
	name    string
	address string // inproc:<name>, tty:<path>[@baud], pty:<path>[@baud][,plain]
	// bitrate 0 takes the address's rate, else the LDF's LIN_speed
	bitrate  int
	ldf      string
	role     string = 'monitor' // master | slave | monitor
	simulate []string
	schedule string
	enabled  bool = true
}

const lin_keys = ['name', 'address', 'bitrate', 'ldf', 'role', 'simulate', 'schedule', 'enabled']
const lin_roles = ['master', 'slave', 'monitor']

// name_taken says whether a channel or a LIN bus of the project is called `name`.
pub fn (p Project) name_taken(name string) bool {
	return p.channels.any(it.name == name) || p.lin.any(it.name == name)
}

// name_clash is the refusal of a channel and a LIN bus sharing `name` (scripts name both in one
// namespace); none when they do not.
pub fn (p Project) name_clash(name string) ?string {
	if p.channels.any(it.name == name) && p.lin.any(it.name == name) {
		return '`${name}` is both a channel of buses: and a LIN bus; scripts name both in one namespace'
	}
	return none
}

// str_list is a list of names: an explicit null is none, a scalar is one, and an item that is
// not a scalar is refused.
fn str_list(v yaml.Any, what string) ![]string {
	if v is yaml.Null {
		return []
	}
	if v is map[string]yaml.Any {
		return error('${what}: is a list of names, not a mapping')
	}
	mut out := []string{}
	for i, x in v.array() {
		if x is yaml.Null || x is []yaml.Any || x is map[string]yaml.Any {
			return error('${what}: item ${i + 1} is not a name')
		}
		out << x.string()
	}
	return out
}

// parse_lin reads the `lin:` list; `chans` are the project's rows, whose names a LIN bus may not
// take. An unknown key is refused in a file of this build's schema or older, and ignored in a
// newer one, which the version note covers.
fn parse_lin(v yaml.Any, chans []Channel, version int) ![]LinBus {
	if v is yaml.Null {
		return []
	}
	if v !is []yaml.Any {
		return error('lin: is a list of LIN buses')
	}
	mut out := []LinBus{}
	for i, e in v.array() {
		if e !is map[string]yaml.Any {
			return error('lin: entry ${i + 1} is not a mapping')
		}
		m := e.as_map()
		label := if n := m['name'] { 'lin ${n.string()}' } else { 'lin entry ${i + 1}' }
		for k, _ in m {
			if k !in lin_keys && version <= schema_version {
				return error('${label}: unknown key `${k}` (known: ${lin_keys.join(', ')})')
			}
		}
		mut b := LinBus{
			name:     e.value('name').default_to('').string().trim_space()
			address:  e.value('address').default_to('').string().trim_space()
			ldf:      e.value('ldf').default_to('').string()
			role:     e.value('role').default_to('monitor').string()
			schedule: e.value('schedule').default_to('').string()
			enabled:  e.value('enabled').default_to(true).bool()
		}
		if b.name == '' {
			return error('${label}: needs a name')
		}
		if b.address == '' {
			return error('${label}: needs an address (inproc:<name>, tty:<path>, pty:<path>)')
		}
		if b.role !in lin_roles {
			return error('${label}: role `${b.role}` is not one of ${lin_roles.join(', ')}')
		}
		if r := e.value_opt('bitrate') {
			b.bitrate = int(checked_int(r.str(), '${label}: bitrate', 1000, 20000)!)
		}
		if s := e.value_opt('simulate') {
			b.simulate = str_list(s, '${label}: simulate')!
		}
		if out.any(it.name == b.name) {
			return error('${label}: two LIN buses are named `${b.name}`')
		}
		if why := Project{
			channels: chans
			lin:      [b]
		}.name_clash(b.name) {
			return error('${label}: ${why}')
		}
		out << b
	}
	return out
}

// lin_yaml is the `lin:` section as save writes it, after `buses:`; '' when there is none.
fn (p Project) lin_yaml() string {
	if p.lin.len == 0 {
		return ''
	}
	mut s := '\nlin:\n'
	for b in p.lin {
		s += '  - name: ${yaml_scalar(b.name)}\n'
		s += '    address: ${yaml_scalar(b.address)}\n'
		if b.bitrate > 0 {
			s += '    bitrate: ${b.bitrate}\n'
		}
		if b.ldf != '' {
			s += '    ldf: ${yaml_scalar(b.ldf)}\n'
		}
		s += '    role: ${b.role}\n'
		if b.simulate.len > 0 {
			s += '    simulate: [${b.simulate.map(yaml_scalar(it)).join(', ')}]\n'
		}
		if b.schedule != '' {
			s += '    schedule: ${yaml_scalar(b.schedule)}\n'
		}
		s += '    enabled: ${b.enabled}\n'
	}
	return s
}

// lin_refs is every LIN bus's LDF reference.
fn (p Project) lin_refs() []string {
	return p.lin.filter(it.ldf != '').map(it.ldf)
}

// lin_reference_notes is cwd_only_note over the LDFs not in `said`, prefixed with the bus.
fn (p Project) lin_reference_notes(dir string, mut said map[string]bool) []string {
	mut notes := []string{}
	for b in p.lin {
		if b.ldf == '' || b.ldf in said {
			continue
		}
		said[b.ldf] = true
		if n := cwd_only_note(dir, b.ldf) {
			notes << '${b.name}: ${n}'
		}
	}
	return notes
}

// rebase_lin rewrites each LIN bus's LDF for a Save As (rebase_assets), returning one AssetRefs
// per bus with what it was.
fn (mut p Project) rebase_lin(old_dir string, new_dir string) []AssetRefs {
	mut was := []AssetRefs{cap: p.lin.len}
	for mut b in p.lin {
		was << AssetRefs{
			ldf: b.ldf
		}
		b.ldf = rebase_ref(old_dir, new_dir, b.ldf)
	}
	return was
}

// restore_lin puts back what rebase_lin returned, by LIN bus index.
fn (mut p Project) restore_lin(was []AssetRefs) {
	for i, w in was {
		if i < p.lin.len {
			p.lin[i].ldf = w.ldf
		}
	}
}
