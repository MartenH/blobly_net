module transport

// open returns a Bus for the given interface string, dispatching by name:
//   - `udp` / `udp:GROUP` / `udp:GROUP:PORT` → the cross-platform UDP-multicast
//     software bus (udpbus.v),
//   - `cansub:<device-id>/<channel>[@<arb>[/<data>]]` -> a CSS Electronics CANsub, reached over
//     HTTP rather than a driver, which is why it is dispatched on every platform (cansub.v),
//   - `inproc` / `inproc:NAME` → the driver-free in-process bus (inproc.v),
//   - anything else → refused.
//
// This is the macOS dispatcher: no SocketCAN (a Linux kernel feature) and no vendor DLL backend
// (PCAN/Kvaser/Vector XL ship Windows drivers only, per CLAUDE.md's hardware/OS matrix) — so
// there is no real-CAN-hardware backend to fall through to. A wire this app cannot reach gets a
// named refusal rather than being silently sent somewhere it was never meant to go, which is
// what open_linux.v does for a `pcan:`/`kvaser:`/`vector:` address too (it never recognises
// those prefixes; they fall to open_socketcan and fail there for the same reason).
// Every bus in the process is opened here, which is why listen-only is enforced here: the
// wrapper is applied to whatever the backend returns, so no emitter can route around it
// (issue #117). See listen.v.
pub fn open(iface string) !Bus {
	// TWO LAYERS, one choke point. `silenced` refuses what THIS PROCESS has decided must not
	// transmit and asks per send (listen.v); `pinned_open` records what the DRIVER is being
	// configured to, for the wires whose mode a live port fixes (pinned.v, issue #165) — a no-op
	// here since only Vector pins, and there is no Vector backend on this platform.
	return silenced(iface, pinned_open(iface, open_raw)!)
}

fn open_raw(iface string) !Bus {
	if name := parse_inproc_iface(iface) {
		return open_inproc(name)!
	}
	if t := parse_udp_iface(iface) {
		return open_udp(t.group, t.port)!
	}
	if iface.to_lower().starts_with('cansub:') {
		// The one hardware backend reachable from every OS: a CANsub enumerates as a USB
		// NETWORK adapter and is spoken to over HTTP, so the same code reaches it here as on
		// Linux/Windows. Through the shared registry because the vendor permits a single client
		// per channel WebSocket and the app opens each wire several times per Start.
		return shared_open_events(wire_key_for('cansub', iface), iface, open_cansub_bus)!
	}
	return error('cannot open "${iface}": no CAN hardware backend on macOS (SocketCAN is Linux-only, PCAN/Kvaser/Vector XL are Windows-only) — use inproc:, udp: or cansub: for a driver-free bus, or a real CANsub device')
}
