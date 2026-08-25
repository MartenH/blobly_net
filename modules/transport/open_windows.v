module transport

// open returns a Bus for the given interface string. Windows has no SocketCAN, so
// the available backends are the cross-platform software buses (`inproc:`, `udp:`)
// and the vendor CAN-hardware backends:
//   - `pcan:<channel>[@<bitrate>]`   PEAK PCAN-Basic (pcan_windows.v)
//   - `kvaser:<channel>[@<bitrate>]` Kvaser CANlib   (kvaser_windows.v)
//   - `vector:<channel>[@<bitrate>][,silent]` Vector XL (vector_windows.v)
//   - `cansub:<device-id>/<channel>[@<arb>[/<data>]]` CSS Electronics CANsub (cansub.v) — not a
//     vendor DLL but an HTTP server on the end of a USB cable, so it is the one hardware backend
//     that works identically on Linux; open_linux.v routes it too.
// The Linux counterpart (open_linux.v) accepts `vcan0`/`can0` instead.
// Every bus in the process is opened here, which is why listen-only is enforced here: the
// wrapper is applied to whatever the backend returns, so no emitter can route around it
// (issue #117). See listen.v.
pub fn open(iface string) !Bus {
	// TWO LAYERS, one choke point. `silenced` refuses what THIS PROCESS has decided must not
	// transmit and asks per send (listen.v); `pinned_open` records what the DRIVER is being
	// configured to, for the wires whose mode a live port fixes (pinned.v, issue #165). The
	// first is a policy we can change at any moment, the second a fact we can only observe —
	// which is why it WRAPS the open rather than the bus: the record has to exist before the
	// port does, not after.
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
		// Through the shared registry for the same reason `pcan:` is: the vendor states that a
		// single client may be connected to each channel's WebSocket, and the app opens each wire
		// several times per Start. Keyed on the WIRE — the device id and channel, without the
		// bitrate — so a 250k row and a 500k row on one channel meet in the conflict check
		// instead of both reaching the device and the second being refused by it.
		return shared_open(wire_key_for('cansub', iface), iface, open_cansub_bus)!
	}
	if iface.starts_with('pcan:') {
		// Through the shared registry, not straight to the driver: PCANBasic permits exactly
		// one CAN_Initialize per channel per process (issue #147), and the app opens each wire
		// several times per Start — a monitor plus one transmit tap per channel plus the
		// anonymous tap. Whichever call arrived first won and the rest were told the adapter
		// was missing; usually the loser was the reader, so the measurement transmitted and
		// heard nothing. The other backends are deliberately NOT routed through here — see
		// shared.v for why a second open of `inproc:`/`udp:` is a second subscriber and must
		// stay one.
		// Keyed on the WIRE, which is destination_key WITHOUT the bitrate. The channel is the
		// thing the driver lets us open once; the rate is a setting ON it. Keyed WITH the rate,
		// a 250k row and a 500k row on one channel would be two entries, both would reach
		// CAN_Initialize, and the second would fail with the very error this exists to prevent
		// — instead of being told the two disagree. Same reasoning as wire_key_for.
		return shared_open(wire_key_for('pcan', iface), iface, open_pcan_bus)!
	}
	if iface.starts_with('kvaser:') {
		return open_kvaser(iface['kvaser:'.len..])!
	}
	if iface.starts_with('vector:') {
		return open_vector(iface['vector:'.len..])!
	}
	return error('no SocketCAN on Windows; use inproc:/udp:/pcan:/kvaser:/vector: (got "${iface}")')
}
