module transport

// open returns a Bus for the given interface string, dispatching by name:
//   - `udp` / `udp:GROUP` / `udp:GROUP:PORT` → the cross-platform UDP-multicast
//     software bus (udpbus.v),
//   - anything else (e.g. `vcan0`, `can0`) → the Linux SocketCAN backend.
// This is the Linux dispatcher; `open_windows.v` is the Windows counterpart
// (udp + inproc). Keeping `open_socketcan` referenced ONLY here preserves the
// platform seam — `socketcan_linux.v` never has to compile on Windows.
//   - `inproc` / `inproc:NAME` → the driver-free in-process bus (inproc.v).
// Every bus in the process is opened here, which is why listen-only is enforced here: the
// wrapper is applied to whatever the backend returns, so no emitter can route around it
// (issue #117). See listen.v.
pub fn open(iface string) !Bus {
	// TWO WRAPPERS, one choke point. `silenced` refuses what THIS PROCESS has decided must not
	// transmit and asks per send (listen.v); `track_pinned` records what the DRIVER has been
	// configured to, for the wires whose mode a live port fixes (pinned.v, issue #165). The
	// first is a policy we can change at any moment, the second a fact we can only observe.
	return silenced(iface, track_pinned(iface, open_raw(iface)!))
}

fn open_raw(iface string) !Bus {
	if name := parse_inproc_iface(iface) {
		return open_inproc(name)!
	}
	if t := parse_udp_iface(iface) {
		return open_udp(t.group, t.port)!
	}
	return open_socketcan(iface)!
}
