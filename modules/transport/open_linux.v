module transport

// open returns a Bus for the given interface string, dispatching by name:
//   - `udp` / `udp:GROUP` / `udp:GROUP:PORT` → the cross-platform UDP-multicast
//     software bus (udpbus.v),
//   - anything else (e.g. `vcan0`, `can0`) → the Linux SocketCAN backend.
// This is the Linux dispatcher; `open_windows.v` is the Windows counterpart
// (udp only). Keeping `open_socketcan` referenced ONLY here preserves the
// platform seam — `socketcan_linux.v` never has to compile on Windows.
pub fn open(iface string) !Bus {
	if t := parse_udp_iface(iface) {
		return open_udp(t.group, t.port)!
	}
	return open_socketcan(iface)!
}
