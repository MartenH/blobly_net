module transport

// can_link_of: SocketCAN is Linux's, so elsewhere no interface is read (canlink.v).
pub fn can_link_of(name string) CanLink {
	return CanLink{}
}
