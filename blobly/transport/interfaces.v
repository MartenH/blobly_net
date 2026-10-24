module transport

import time

// What the interfaces present now are, as data for the Discover dialog and the scripting
// bindings alike: the address open() takes, its kind, a description, and what is known of its
// CAN-FD support.

// FdSupport is whether an interface carries CAN-FD, where the platform can say.
pub enum FdSupport {
	unknown // nothing asked could say (a vendor channel whose driver does not tell, a bridge)
	no      // classic only (a SocketCAN link at mtu 16)
	yes     // FD (a SocketCAN link at mtu 72, a software bus, a Vector channel with ISO CAN-FD)
}

// Interface is one interface present now.
pub struct Interface {
pub:
	address string // what open() takes: "vcan0", "pcan:PCAN_USBBUS1", "vector:1", "inproc:SIM"
	// socketcan, vcan, pcan, kvaser, vector, cansub, bridge, udp or inproc
	kind    string
	desc    string // for a person: "PCAN-USB Pro FD [1-1] · up", "virtual CAN"
	fd      FdSupport
	bitrate int  // the nominal rate it is configured for, where the system says (a SocketCAN can0); else 0
	virtual bool // a software bus, or a vendor's virtual channel, rather than hardware
	// for a vector: row, its application channel's state: "assigned", or "hardware not present"
	// (assigned to an adapter that is unplugged); '' for every other kind
	state string
}

// fd_of_mtu is a SocketCAN link's FD support by its MTU: 72 (CANFD_MTU) carries FD frames, 16
// (CAN_MTU) classic ones only.
@[markused]
fn fd_of_mtu(mtu int) FdSupport {
	return match mtu {
		72 { FdSupport.yes }
		16 { FdSupport.no }
		else { FdSupport.unknown }
	}
}

// iface_kind is an address's kind, by its scheme as the dispatcher reads it (case-sensitive but
// for cansub:); a bare name is a SocketCAN interface.
pub fn iface_kind(address string) string {
	if address.to_lower().starts_with('cansub:') {
		return 'cansub'
	}
	for scheme in ['pcan', 'kvaser', 'vector', 'bridge', 'udp', 'inproc'] {
		if address.starts_with('${scheme}:') || address == scheme {
			return scheme
		}
	}
	return if address.starts_with('vcan') { 'vcan' } else { 'socketcan' }
}

// describe is a listed Iface as an Interface: its kind by its address, a description for a person.
pub fn describe(f Iface) Interface {
	kind := if f.kind == 'vcan' { 'vcan' } else { iface_kind(f.iface) }
	mut d := match kind {
		'vcan' {
			'virtual CAN'
		}
		'udp' {
			'software bus'
		}
		'inproc' {
			'in-process simulation'
		}
		'cansub' {
			f.name
		}
		'bridge' {
			'through canbridge on ${f.iface.all_after('bridge:').all_before_last('/')}'
		}
		else {
			if f.name != '' && f.name != f.iface { f.name } else { 'CAN' }
		}
	}
	if f.bitrate > 0 {
		d += ' · ${f.bitrate}'
	}
	return Interface{
		address: f.iface
		kind:    kind
		desc:    d
		fd:      if f.fd == .unknown && kind in ['udp', 'inproc'] { FdSupport.yes } else { f.fd }
		bitrate: f.bitrate
		virtual: f.virtual
		state:   f.state
	}
}

// local_interfaces is what this host enumerates without waiting on a network: its SocketCAN
// links (the down ones too, described from /sys), the vendor channels the installed drivers
// report, and the software buses; one row per address, the first source's, with a configured
// bitrate taken from a later one where the first had none.
pub fn local_interfaces() []Interface {
	mut out := sysfs_can_ifaces()
	for f in list_interfaces() or { virtual_ifaces() } {
		d := describe(f)
		mut seen := false
		for i, o in out {
			if canonical_iface(o.address) == canonical_iface(d.address) {
				if o.bitrate == 0 && d.bitrate > 0 {
					out[i] = Interface{
						...o
						bitrate: d.bitrate
						desc:    '${o.desc} · ${d.bitrate}'
					}
				}
				seen = true
				break
			}
		}
		if !seen {
			out << d
		}
	}
	return out
}

// interfaces is local_interfaces and the channels of every CAN bridge connected now: everything
// known without a network wait. A CANsub is found by discover_cansub_within, which waits.
pub fn interfaces() []Interface {
	mut out := local_interfaces()
	for f in bridge_rows() {
		d := describe(f)
		if !out.any(it.address == d.address) {
			out << d
		}
	}
	return out
}

// cansub_window_max_ms bounds a script's browse: a device answers within milliseconds, so a
// longer window only waits longer
pub const cansub_window_max_ms = 10_000

// discover_cansub_within browses mDNS for attached CANsub devices for window_ms (1 to
// cansub_window_max_ms), one row per channel, with the browse's note ('' when every interface
// was asked). An error is the browse not having been possible, never "nothing attached".
pub fn discover_cansub_within(window_ms int) !([]Interface, string) {
	if window_ms < 1 || window_ms > cansub_window_max_ms {
		return error('a CANsub browse window is 1 to ${cansub_window_max_ms} ms, not ${window_ms}')
	}
	rows, note := cansub_discovery(window_ms * time.millisecond)!
	return rows.map(describe(it)), note
}
