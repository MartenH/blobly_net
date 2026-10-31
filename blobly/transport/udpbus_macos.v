// The macOS half of udpbus.v's receive path. vlib's net.UdpConn (used everywhere else) sets only
// SO_REUSEADDR before bind, which is enough on Linux -- and, unchanged from before this file
// existed, on Windows -- for several sockets, in this process or in several processes, to bind
// the SAME multicast port: exactly the vcan0-multi-opener shape udpbus.v exists to replace.
// BSD-derived stacks, macOS included, do not extend SO_REUSEADDR that far: an exact duplicate
// bind (0.0.0.0:port to 0.0.0.0:port) additionally needs SO_REUSEPORT, which vlib's net module
// does not expose (`vlib/net/socket_options.c.v` has it commented out, "TODO make it work in
// windows") -- confirmed on this bench: a second `open_udp` on the same group:port failed at
// bind with EADDRINUSE (errno 48) instead of joining the first.
//
// So macOS gets its own minimal raw-socket receive path, kept to exactly what open_rx/rx_read/
// rx_close in udpbus.v need: create + bind with both reuse options set, join the multicast
// group, read with a timeout, close. Everything else in udpbus.v (framing, the self-echo filter,
// send, health, diagnostics) is unchanged and shared.
module transport

#include "udp_reuseport_shim.h"

fn C.ct_udp_listen_reuseport(port int) int
fn C.ct_udp_join_multicast(fd int, group_dotted &u8, iface_dotted &u8) int
fn C.ct_udp_set_recv_timeout_ms(fd int, ms int) int
fn C.ct_udp_recv(fd int, buf voidptr, len int) int
fn C.ct_udp_close(fd int)
fn C.strerror(int) &char

fn cerr(errno int) string {
	return unsafe { cstring_to_vstring(C.strerror(errno)) }
}
