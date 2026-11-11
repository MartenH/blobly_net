module project

import transport

// IfaceOverride attaches the row named `name` to `iface` for one run, in place of the
// interface its file states: an interface string as `Channel.iface` reads it (`inproc:BusA`,
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

// override_interfaces attaches each named row to its override's interface, before anything is
// checked or opened. Refused whole, changing nothing, for a name no row has (naming the rows),
// a name two rows share, a name given twice, or an interface iface_override_refusal refuses.
// A generator whose `bus:` named a moved row by its old interface is rewritten to name it again.
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
		chs[i].adapter = adapter
		chs[i].address = address
		chs[i].iface = compose_iface(adapter, address)
		moved[i] = true
	}
	// a `bus:` naming a moved row by its old interface follows the row
	for ci, own in p.channels {
		for si, s in own.senders {
			was := resolve_sender_bus(s.bus, own, p.channels)
			if was.kind != .iface || was.row !in moved {
				continue
			}
			v := sender_bus_value(chs[was.row], chs[ci], chs) or {
				return error('interface override: generator "${s.name}" of row "${own.name}" names row "${chs[was.row].name}" by its interface, and nothing can name it once moved; name the row in its bus:')
			}
			mut ss := chs[ci].senders.clone()
			ss[si].bus = v
			chs[ci].senders = ss
		}
	}
	p.channels = chs
}
