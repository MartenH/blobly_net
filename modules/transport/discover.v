module transport

// Interface discovery — the GUI-free half of the project-scaffolder. `list_interfaces()`
// (platform-gated in discover_linux.v / discover_windows.v) enumerates the bus interfaces
// available to scaffold into a project; `channels_yaml()` turns them into a `channels:`
// block matching the project schema (see projects/demo.blobnet). A GUI "Bus Configuration"
// dialog (a Discover button) is the eventual front-end; this module does the actual work.

// Iface is a discovered (or always-available virtual) bus interface. `iface` is the string
// open() accepts; `name` is a suggested channel label; `bitrate` is 0 when unknown/virtual.
pub struct Iface {
pub:
	name    string // suggested channel name, e.g. "vcan0", "UDP"
	iface   string // open() string, e.g. "vcan0", "udp:239.63.42.1:20000", "inproc:SIM"
	kind    string // "can" | "vcan" | "udp" | "inproc"
	bitrate int    // nominal bitrate if known (a configured real can0), else 0
	virtual bool   // driver-free software bus (udp/inproc) vs. a real netdev
}

// virtual_ifaces returns the always-available, driver-free software buses. Both platforms
// offer these so there's always something to attach even with no CAN hardware present.
pub fn virtual_ifaces() []Iface {
	return [
		Iface{
			name:    'UDP'
			iface:   'udp:${udp_default_group}:${udp_default_port}'
			kind:    'udp'
			virtual: true
		},
		Iface{
			name:    'SIM'
			iface:   'inproc:SIM'
			kind:    'inproc'
			virtual: true
		},
	]
}

// channels_yaml scaffolds a `channels:` YAML block from discovered interfaces, matching the
// project schema. Real CAN interfaces land enabled + monitor; virtual fallbacks land
// disabled so they don't auto-attach. vcan/virtual omit the (meaningless) bitrate. The
// result is meant to be reviewed and hand-tuned (names / mode / databases) before saving.
pub fn channels_yaml(ifaces []Iface) string {
	mut b := 'channels:\n'
	for f in ifaces {
		b += '  - name: ${f.name}\n'
		b += '    type: can\n' // canfd detection is a later concern
		b += '    interface: ${f.iface}\n'
		if f.bitrate > 0 {
			b += '    bitrate: ${f.bitrate}\n'
		}
		b += '    mode: monitor\n'
		b += '    enabled: ${!f.virtual}\n'
		b += '    databases: []\n'
	}
	return b
}
