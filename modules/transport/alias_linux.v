module transport

// physical_wire_key — the PHYSICAL channel an address reaches, where this machine can tell.
//
// This is the Linux half, and it always answers "cannot say". Nothing here can: resolving a
// Vector application channel to the hardware behind it is a question for the XL driver, and on
// Linux `vector:1` is not even a vendor address — open_linux.v sends it to SocketCAN.
//
// NONE, not a guess and not the spelling. A caller uses this to find two addresses that are
// secretly ONE piece of hardware; an answer invented here would either merge wires that are
// separate or report a conflict on a machine that has no way to know. Saying nothing is the only
// honest reading, and every caller is written to treat it as no opinion rather than as agreement.
pub fn physical_wire_key(adapter string, iface string) ?string {
	return none
}
