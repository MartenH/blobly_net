module sysview

// subnet_env: blobly_emb's per-bench override of a someip segment's `subnet` (its docs/net.md,
// "Moving the bench network"). Read here by the same rule, so the model names the addresses the
// images were generated with.
pub const subnet_env = 'BLOB_NET_SUBNET'

// resolve_hosts gives each `endpoint = { host = N }` its address: host N of the subnet of the one
// segment it sits on that states one — `override` in its place where exactly one segment does, as
// blobly_emb's sysmodel resolves it. What cannot be resolved stays '' and is said in errs.
pub fn (mut sys System) resolve_hosts(override string) {
	declared := sys.buses.filter(it.subnet != '')
	mut nets := map[string]Subnet{}
	if override != '' && declared.len > 1 {
		sys.errs << '${subnet_env} replaces THE segment subnet, but ${declared.len} buses declare one'
	} else {
		for b in declared {
			text := if override != '' { override } else { b.subnet }
			if sn := parse_subnet(text) {
				nets[b.name] = sn
			} else {
				sys.errs << 'bus "${b.name}": subnet "${text}" is not a network ("192.168.77.0/24")'
			}
		}
	}
	for mut n in sys.nodes {
		if n.host == 0 || n.address != '' {
			continue
		}
		on := n.buses.filter(it in nets)
		if on.len != 1 {
			sys.errs << 'node "${n.name}": endpoint host ${n.host} has no single segment subnet to be a host of'
			continue
		}
		sn := nets[on[0]]
		if n.host < 1 || n.host > i64(~sn.mask - 1) {
			sys.errs << 'node "${n.name}": endpoint host ${n.host} is not a host of ${text_of(sn)}'
			continue
		}
		n.address = dotted(sn.network | u32(n.host))
	}
}

struct Subnet {
	network u32
	mask    u32
}

// parse_subnet: "a.b.c.d/n" with n in 1..30 and no host bits set
fn parse_subnet(s string) ?Subnet {
	parts := s.split('/')
	if parts.len != 2 || parts[1].len == 0 || parts[1].len > 2
		|| !parts[1].bytes().all(it >= `0` && it <= `9`) {
		return none
	}
	p := parts[1].int()
	octets := parts[0].split('.')
	if p < 1 || p > 30 || octets.len != 4 {
		return none
	}
	mut a := u32(0)
	for o in octets {
		if o.len == 0 || o.len > 3 || !o.bytes().all(it >= `0` && it <= `9`) || o.int() > 255 {
			return none
		}
		a = (a << 8) | u32(o.int())
	}
	mask := u32(0xFFFFFFFF) << u32(32 - p)
	if a & ~mask != 0 {
		return none
	}
	return Subnet{a, mask}
}

fn dotted(a u32) string {
	return '${a >> 24}.${(a >> 16) & 0xFF}.${(a >> 8) & 0xFF}.${a & 0xFF}'
}

fn text_of(sn Subnet) string {
	mut p := 0
	for m := sn.mask; m != 0; m <<= 1 {
		p++
	}
	return '${dotted(sn.network)}/${p}'
}
