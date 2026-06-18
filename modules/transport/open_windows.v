module transport

// open returns a Bus for the given interface string. Windows has no SocketCAN, so
// the available backends are the cross-platform software buses (`inproc:`, `udp:`)
// and the vendor CAN-hardware backends:
//   - `pcan:<channel>[@<bitrate>]`   PEAK PCAN-Basic (pcan_windows.v)
//   - `kvaser:<channel>[@<bitrate>]` Kvaser CANlib   (kvaser_windows.v)
// The Linux counterpart (open_linux.v) accepts `vcan0`/`can0` instead.
pub fn open(iface string) !Bus {
	if name := parse_inproc_iface(iface) {
		return open_inproc(name)!
	}
	if t := parse_udp_iface(iface) {
		return open_udp(t.group, t.port)!
	}
	if iface.starts_with('pcan:') {
		return open_pcan(iface['pcan:'.len..])!
	}
	if iface.starts_with('kvaser:') {
		return open_kvaser(iface['kvaser:'.len..])!
	}
	return error('no SocketCAN on Windows; use inproc:/udp:/pcan:/kvaser: (got "${iface}")')
}
