module transport

#include "socketcan_shim.h"

fn C.ct_can_link(&u8, &u8, int, &u32, &i32) int

// can_link_of reads interface `name`'s link kind and, for a CAN controller, whether it is
// listen-only — over rtnetlink, changing nothing and needing no privilege (canlink.v). A link that
// cannot be read (no such interface, a netlink failure) is `.unknown`.
pub fn can_link_of(name string) CanLink {
	mut kind := []u8{len: 32}
	mut flags := u32(0)
	mut has := i32(0)
	if C.ct_can_link(name.str, &u8(kind.data), kind.len, &flags, &has) != 0 {
		return CanLink{}
	}
	k := unsafe { cstring_to_vstring(&char(kind.data)) }
	return CanLink{
		kind: k
		mode: link_controller(k, has != 0, flags)
	}
}
