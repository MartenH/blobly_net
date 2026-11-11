module project

import transport

// IfaceOverride attaches the row named `name` to `iface` for one run, in place of the
// interface its file states: an interface string without a rate or a mode (`inproc:BusA`,
// `pcan:PCAN_USBBUS2`, `vcan1`, `doip:10.0.0.5:13400`, `lin:tty:/dev/ttyUSB0`).
pub struct IfaceOverride {
pub:
	name  string
	iface string
}

// parse_iface_override reads one `NAME=IFACE`, split at the first `=`, both sides trimmed.
pub fn parse_iface_override(s string) !IfaceOverride {
	if !s.contains('=') {
		return error('interface override "${s}": not NAME=IFACE')
	}
	name := s.all_before('=').trim_space()
	iface := s.all_after('=').trim_space()
	if name == '' {
		return error('interface override "${s}": names no row (NAME=IFACE)')
	}
	if iface == '' {
		return error('interface override "${s}": gives no interface (NAME=IFACE)')
	}
	return IfaceOverride{
		name:  name
		iface: iface
	}
}

// parse_iface_overrides reads one `NAME=IFACE` a line; blank lines are skipped.
pub fn parse_iface_overrides(text string) ![]IfaceOverride {
	mut out := []IfaceOverride{}
	for line in text.split_into_lines() {
		if line.trim_space() == '' {
			continue
		}
		out << parse_iface_override(line)!
	}
	return out
}

// iface_override_refusal is why `iface` cannot replace the interface of row `ch`; none when it
// can. The row keeps its kind, its bitrate, its framing and its listen-only flag, so an
// interface of another kind, or one carrying a rate or a mode of its own, is refused.
fn iface_override_refusal(ch Channel, iface string) ?string {
	want := ch.kind()
	got := kind_of_iface(iface)
	if got != want {
		return 'row "${ch.name}" is a ${want.name()} bus; "${iface}" is a ${got.name()} interface'
	}
	adapter, address := decompose_iface(iface)
	if want == .lin {
		if why := lin_row_refusal(address, '') {
			return '"${iface}": ${why}'
		}
		// a serial address's `@<baud>` (lin.parse_serial's grammar) is a rate
		if (address.starts_with('tty:') || address.starts_with('pty:'))
			&& address.all_before(',plain').contains('@') {
			return '"${iface}": the rate is the row\'s (bitrate:) or its LDF\'s, not the interface\'s'
		}
		return none
	}
	if transport.adapter_configures_bitrate(adapter) && address != iface.trim_space().all_after(':') {
		return '"${iface}": the rate is the row\'s (bitrate: / data_bitrate:), not the interface\'s'
	}
	if adapter == 'vector' && address.contains(',') {
		return '"${iface}": listen-only is the row\'s (listen_only:), not the interface\'s'
	}
	return none
}

// lin_address_rate is the rate a serial LIN address states (`tty:<path>@<baud>[,plain]`), 0 for
// none; a LIN row with no bitrate: runs at it, so a row moved off that address keeps it.
fn lin_address_rate(address string) int {
	if !address.starts_with('tty:') && !address.starts_with('pty:') {
		return 0
	}
	path := address.all_before(',plain')
	if !path.contains('@') {
		return 0
	}
	rate := path.all_after_last('@')
	return if is_all_digits(rate) && rate.len <= 6 { rate.int() } else { 0 }
}

// override_interfaces attaches each named row to its override's interface, before anything is
// checked or opened. Refused whole, changing nothing, for a name no row has (naming the rows),
// a name two rows share, a name given twice, or an interface iface_override_refusal refuses.
// A generator follows its rows: one whose `bus:` named one row by its interface and no longer
// names that row alone (the row respelled, or another row moved onto the interface), or named a
// wire (shared by several rows, or not a row's spelling of it) that every CAN row on it left, is
// rewritten to name where they went; an override to the wire a row is already on moves no wire's
// generators.
pub fn (mut p Project) override_interfaces(overrides []IfaceOverride) ! {
	if overrides.len == 0 {
		return
	}
	mut chs := p.channels.clone()
	mut moved := map[int]bool{}
	mut given := map[string]bool{}
	for o in overrides {
		if o.name in given {
			return error('interface override: row "${o.name}" is given twice')
		}
		given[o.name] = true
		mut at := []int{}
		for i, ch in chs {
			if ch.name == o.name {
				at << i
			}
		}
		if at.len == 0 {
			names := p.channels.map('"${it.name}"').join(', ')
			return error('interface override: the project has no row named "${o.name}" (its rows: ${names})')
		}
		if at.len > 1 {
			return error('interface override: ${at.len} rows are named "${o.name}"; an override cannot say which')
		}
		i := at[0]
		if why := iface_override_refusal(chs[i], o.iface) {
			return error('interface override: ${why}')
		}
		adapter, address := decompose_iface(o.iface)
		was_wire := conflict_wire_key(chs[i])
		if chs[i].kind() == .lin && chs[i].bitrate == 0 {
			chs[i].bitrate = lin_address_rate(chs[i].address)
		}
		chs[i].adapter = adapter
		chs[i].address = address
		chs[i].iface = compose_iface(adapter, address)
		if conflict_wire_key(chs[i]) != was_wire {
			moved[i] = true
		}
	}
	for ci, own in p.channels {
		for si, s in own.senders {
			was := resolve_sender_bus(s.bus, own, p.channels)
			now := resolve_sender_bus(s.bus, chs[ci], chs)
			to := followed_rows(was, now, p.channels, moved)
			if to.len == 0 {
				continue
			}
			v := moved_bus_value(to, chs[ci], chs) or {
				return error('interface override: generator "${s.name}" of row "${own.name}" transmits on `${s.bus}`, which ${to.map('"${chs[it].name}"').join(', ')} left, and nothing names where they went; name a row in its bus:')
			}
			mut ss := chs[ci].senders.clone()
			ss[si].bus = v
			chs[ci].senders = ss
		}
	}
	p.channels = chs
}

// followed_rows is the rows of `chs` (the project before the move) a generator's `bus:` follows,
// given what it resolved to before (`was`) and after (`now`): the one row an interface named when
// the value no longer names that row, or every CAN row on the wire an ambiguous or bare value
// reaches when all of them left it; none when the generator stays where it is.
fn followed_rows(was SenderBus, now SenderBus, chs []Channel, moved map[int]bool) []int {
	if was.kind == .iface {
		same := now.kind in [.iface, .named] && now.row == was.row
		return if same { []int{} } else { [was.row] }
	}
	if was.kind !in [.ambiguous, .bare] || was.iface == '' {
		return []int{}
	}
	adapter, _ := decompose_iface(was.iface)
	wire := conflict_wire_key(Channel{
		adapter: adapter
		iface:   was.iface
	})
	mut on := []int{}
	for i, c in chs {
		if c.kind() == .can && conflict_wire_key(c) == wire {
			if i !in moved {
				return []int{}
			}
			on << i
		}
	}
	return on
}

// moved_bus_value spells where the rows `to` (positions in `chs`, the project after the move)
// now are, for a generator of row `own`: the one row as sender_bus_value names it, or the one
// interface they all moved to where nothing named like it takes the value; none otherwise.
fn moved_bus_value(to []int, own Channel, chs []Channel) ?string {
	if to.len == 1 {
		return sender_bus_value(chs[to[0]], own, chs)
	}
	iface := chs[to[0]].iface
	if to.any(chs[it].iface != iface) || resolve_sender_bus(iface, own, chs).iface != iface {
		return none
	}
	return iface
}
