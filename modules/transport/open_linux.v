module transport

// open returns a Bus for the given interface string, dispatching by name:
//   - `udp` / `udp:GROUP` / `udp:GROUP:PORT` → the cross-platform UDP-multicast
//     software bus (udpbus.v),
//   - anything else (e.g. `vcan0`, `can0`) → the Linux SocketCAN backend.
// This is the Linux dispatcher; `open_windows.v` is the Windows counterpart
// (udp + inproc). Keeping `open_socketcan` referenced ONLY here preserves the
// platform seam — `socketcan_linux.v` never has to compile on Windows.
//   - `inproc` / `inproc:NAME` → the driver-free in-process bus (inproc.v).
pub fn open(iface string) !Bus {
	if name := parse_inproc_iface(iface) {
		return open_inproc(name)!
	}
	if t := parse_udp_iface(iface) {
		return open_udp(t.group, t.port)!
	}
	return open_socketcan(iface)!
}
