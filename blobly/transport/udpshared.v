module transport

import net

// listen_udp_shared is `net.listen_udp` for a UDP port that several sockets bind at once: the
// software bus's multicast port (udpbus.v), mDNS's 5353 beside the host's own responder
// (cansub_mdns.v), a DoIP entity's or a SOME/IP node's port (doip/server.v, someip/call.v), a
// listening window (udpwindow.v). On Linux and Windows it IS net.listen_udp, whose SO_REUSEADDR
// lets those binds share the port. On macOS SO_REUSEADDR is not enough — BSD refuses an exact
// duplicate bind unless every binder sets SO_REUSEPORT, which vlib's net does not expose — so
// the second open of a port failed with EADDRINUSE, and 5353 could never be shared with
// mDNSResponder at all (udpshared_macos.v).
pub fn listen_udp_shared(addr string) !&net.UdpConn {
	$if macos {
		return listen_udp_reuseport(addr)
	} $else {
		return net.listen_udp(addr)
	}
}
