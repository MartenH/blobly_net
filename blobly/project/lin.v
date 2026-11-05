// lin — a LIN bus as a row of `buses:`: `adapter: lin`, its LIN address (inproc:<name>,
// tty:<path>[@baud], pty:<path>[@baud][,plain]) in `address:`, so its interface is
// `lin:<address>` and its kind RowKind.lin; then `ldf:`, `role:`, `simulate:` and `schedule:`.
// Parsed here, apart from parse_channel's CAN rules, which never see one. A v11 file's top-level
// `lin:` list is read into rows of the same shape. Plain strings and ints; `blobly/lin` turns a
// row into a running bus (lin.spec_of).
module project

import yaml

// The keys a LIN row may carry; the legacy `lin:` entries carried the same but `type`/`adapter`.
const lin_row_keys = ['name', 'network', 'adapter', 'type', 'protocol', 'address', 'interface',
	'bitrate', 'ldf', 'role', 'simulate', 'schedule', 'enabled']
const lin_keys = ['name', 'address', 'bitrate', 'ldf', 'role', 'simulate', 'schedule', 'enabled']
const lin_roles = ['master', 'slave', 'monitor']

// lin_rows is every LIN row of the project, in row order.
pub fn (p Project) lin_rows() []Channel {
	return p.channels.filter(it.kind() == .lin)
}

// name_taken says whether a row of the project is called `name`.
pub fn (p Project) name_taken(name string) bool {
	return p.channels.any(it.name == name)
}

// name_clash is the refusal of a LIN row sharing `name` with another row (a script opens a LIN
// bus by its name, so it must name one); none when it does not.
pub fn (p Project) name_clash(name string) ?string {
	rows := p.channels.filter(it.name == name)
	if rows.len > 1 && rows.any(it.kind() == .lin) {
		return '`${name}` names a LIN bus and another row; a script opens a LIN bus by its name'
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

// is_lin_row is whether a `buses:` entry is a LIN bus: `adapter: lin`, `type: lin`, or an
// interface of the `lin:` scheme.
fn is_lin_row(c yaml.Any) bool {
	for k in ['adapter', 'type', 'protocol'] {
		if v := c.value_opt(k) {
			if v.string() == 'lin' {
				return true
			}
		}
	}
	if v := c.value_opt('interface') {
		return kind_of_iface(v.string()) == .lin
	}
	return false
}

// lin_row is a LIN row from its parts, the one constructor parse and the legacy section share.
fn lin_row(name string, network string, address string, bitrate int, ldf string, role string, simulate []string, schedule string, enabled bool) Channel {
	return Channel{
		name:     name
		network:  network
		adapter:  'lin'
		address:  address
		typ:      'lin'
		iface:    compose_iface('lin', address)
		bitrate:  bitrate
		ldf:      ldf
		lin_role: role
		simulate: simulate
		schedule: schedule
		enabled:  enabled
	}
}

// parse_lin_row reads a LIN row of `buses:`. An unknown key is refused in a file of this
// build's schema or older, and ignored in a newer one, which the version note covers.
fn parse_lin_row(c yaml.Any, version int) !Channel {
	m := c.as_map()
	label := if n := m['name'] { 'channel "${n.string()}"' } else { 'a LIN channel' }
	for k, _ in m {
		if k !in lin_row_keys && version <= schema_version {
			return error('${label}: unknown key `${k}` for a LIN bus (known: ${lin_row_keys.join(', ')})')
		}
	}
	mut address := c.value('address').default_to('').string().trim_space()
	if address == '' {
		if v := c.value_opt('interface') {
			_, address = decompose_iface(v.string())
		}
	}
	return lin_fields(c, label, address, c.value('network').default_to('').string())
}

// lin_row_refusal is why an address and a typed rate cannot be a LIN row's, as lin_fields reads
// them; none when they can. The GUI's editor asks it before it commits.
pub fn lin_row_refusal(address string, rate string) ?string {
	if address.trim_space() == '' {
		return 'a LIN bus needs an address (inproc:<name>, tty:<path>, pty:<path>)'
	}
	r := rate.trim_space()
	if r == '' || r == '0' {
		return none
	}
	if !is_all_digits(r) || r.int() < 1000 || r.int() > 20000 {
		return 'a LIN bitrate is 1000..20000 baud, or 0 for the address\'s or the LDF\'s (not ${r})'
	}
	return none
}

// lin_fields reads what a LIN row and a legacy `lin:` entry share.
fn lin_fields(c yaml.Any, label string, address string, network string) !Channel {
	name := c.value('name').default_to('').string().trim_space()
	if name == '' {
		return error('${label}: needs a name')
	}
	if address == '' {
		return error('${label}: needs an address (inproc:<name>, tty:<path>, pty:<path>)')
	}
	role := c.value('role').default_to('monitor').string()
	if role !in lin_roles {
		return error('${label}: role `${role}` is not one of ${lin_roles.join(', ')}')
	}
	mut bitrate := 0
	if r := c.value_opt('bitrate') {
		bitrate = int(checked_int(r.str(), '${label}: bitrate', 1000, 20000)!)
	}
	mut simulate := []string{}
	if s := c.value_opt('simulate') {
		simulate = str_list(s, '${label}: simulate')!
	}
	return lin_row(name, network, address, bitrate, c.value('ldf').default_to('').string(),
		role, simulate, c.value('schedule').default_to('').string(), c.value('enabled').default_to(true).bool())
}

// parse_lin reads a v11 file's top-level `lin:` list into LIN rows, appended after `buses:`.
fn parse_lin(v yaml.Any, version int) ![]Channel {
	if v is yaml.Null {
		return []
	}
	if v !is []yaml.Any {
		return error('lin: is a list of LIN buses')
	}
	mut out := []Channel{}
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
		out << lin_fields(e, label, e.value('address').default_to('').string().trim_space(),
			'')!
	}
	return out
}

// check_lin_names refuses a LIN row whose name another row carries.
fn check_lin_names(p Project) ! {
	for ch in p.channels {
		if ch.kind() != .lin {
			continue
		}
		if why := p.name_clash(ch.name) {
			return error('channel "${ch.name}": ${why}')
		}
	}
}

// lin_row_yaml is a LIN row as save writes it, inside `buses:`.
fn lin_row_yaml(ch Channel) string {
	mut s := '  - name: ${yaml_scalar(ch.name)}\n'
	if ch.network != '' {
		s += '    network: ${yaml_scalar(ch.network)}\n'
	}
	s += '    adapter: lin\n'
	s += '    address: ${yaml_scalar(ch.address)}\n'
	if ch.bitrate > 0 {
		s += '    bitrate: ${ch.bitrate}\n'
	}
	if ch.ldf != '' {
		s += '    ldf: ${yaml_scalar(ch.ldf)}\n'
	}
	s += '    role: ${ch.lin_role}\n'
	if ch.simulate.len > 0 {
		s += '    simulate: [${ch.simulate.map(yaml_scalar(it)).join(', ')}]\n'
	}
	if ch.schedule != '' {
		s += '    schedule: ${yaml_scalar(ch.schedule)}\n'
	}
	s += '    enabled: ${ch.enabled}\n'
	return s
}
