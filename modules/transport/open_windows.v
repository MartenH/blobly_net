module transport

// open returns a Bus for the given interface string. Windows has no SocketCAN,
// so only the cross-platform `udp[:GROUP[:PORT]]` software bus is available here
// until a vendor backend (PCAN/Vector/Kvaser via *_windows.v) lands. The Linux
// counterpart (open_linux.v) also accepts `vcan0`/`can0`.
pub fn open(iface string) !Bus {
	if name := parse_inproc_iface(iface) {
		return open_inproc(name)!
	}
	if t := parse_udp_iface(iface) {
		return open_udp(t.group, t.port)!
	}
	return error('no SocketCAN on Windows; use an "inproc:" or "udp:" interface (got "${iface}")')
}
