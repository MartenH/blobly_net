// Where the bridge listener binds, and the token it holds a bridge to (#587).
//
// By default the listener is on loopback, on a port the OS picks, with a random token. Whoever
// starts a bridge on this machine, the WSL launcher, passes both on the bridge's command line.
// A bridge on another machine (a board on the LAN that captures a bus) cannot be told a port and
// token that change at every launch. So two settings fix them:
//
//     BLOBLY_BRIDGE_LISTEN=<address>:<port>   the address and port to bind: 0.0.0.0:29500,
//                                             192.168.1.5:29500, [::]:29500, 127.0.0.1:29500
//     BLOBLY_BRIDGE_TOKEN=<token>             a fixed token, required off loopback, 16 characters
//                                             at least there; letters, digits and -_.+=:,@%/
//
// With the first set, the GUI, cmd/script and libblobly start the listener at startup, and a bad
// setting stops them with the reason. The address is numeric, because a name may resolve to
// several. The token is sent in the clear: it keeps a stray connection out, not an attacker on
// the network (docs/wsl_bridge.md, "A bridge on the LAN").
module transport

pub const bridge_listen_env = 'BLOBLY_BRIDGE_LISTEN'
pub const bridge_token_env = 'BLOBLY_BRIDGE_TOKEN'

// bridge_min_lan_token is the shortest token a listener off loopback accepts.
pub const bridge_min_lan_token = 16

// bridge_token_marks are the characters besides letters and digits a token may hold.
const bridge_token_marks = '-_.+=:,@%/'.bytes()

// BridgeListenCfg is where the listener binds and the token it holds bridges to.
pub struct BridgeListenCfg {
pub:
	host string = '127.0.0.1' // the address bound, IPv6 without brackets
	port int // 0: the OS picks
	// '' : a random one
	token string
	// Set by BLOBLY_BRIDGE_LISTEN, so the listener starts with the program.
	configured bool
}

// bridge_listen_cfg reads the two settings' values: the default listener when neither is set.
pub fn bridge_listen_cfg(listen string, token string) !BridgeListenCfg {
	if listen == '' {
		if token != '' {
			return error('${bridge_token_env} is set but ${bridge_listen_env} is not: a fixed token is for a listener on a fixed port')
		}
		return BridgeListenCfg{}
	}
	host, port := bridge_split_listen(listen)!
	if why := bridge_token_refusal(token, bridge_is_loopback(host)) {
		return error('${bridge_token_env}: ${why}')
	}
	return BridgeListenCfg{
		host:       host
		port:       port
		token:      token
		configured: true
	}
}

// bridge_split_listen reads `<address>:<port>`, an IPv6 address in brackets.
fn bridge_split_listen(listen string) !(string, int) {
	bad := '${bridge_listen_env}="${listen}"'
	mut host := ''
	mut port_s := ''
	if listen.starts_with('[') {
		end := listen.index(']:') or {
			return error('${bad} is not [<IPv6 address>]:<port>')
		}
		host = listen[1..end]
		port_s = listen[end + 2..]
		bridge_ip6_bytes(host) or { return error('${bad}: "${host}" is not an IPv6 address') }
	} else {
		host = listen.all_before_last(':')
		port_s = listen.all_after_last(':')
		if !listen.contains(':') {
			return error('${bad} is not <address>:<port>, such as 0.0.0.0:29500')
		}
		if host.contains(':') {
			return error('${bad}: an IPv6 address is written in brackets, such as [::]:29500')
		}
		bridge_ip4_bytes(host) or {
			return error('${bad}: "${host}" is not a numeric IPv4 address (a name may resolve to several)')
		}
	}
	if port_s == '' || port_s.len > 5 || !port_s.bytes().all(it.is_digit()) || port_s.int() < 1
		|| port_s.int() > 65535 {
		return error('${bad}: the port must be a number from 1 to 65535, which the bridge is told')
	}
	return host, port_s.int()
}

// bridge_token_refusal is why a token cannot be used on a listener, or none. An empty token is a
// random one, which only a bridge on this machine can be told.
fn bridge_token_refusal(token string, loopback bool) ?string {
	if token == '' {
		if loopback {
			return none
		}
		return 'a listener off loopback needs a fixed token of at least ${bridge_min_lan_token} characters, which the bridge is given'
	}
	if !loopback && token.len < bridge_min_lan_token {
		return 'a listener off loopback needs a token of at least ${bridge_min_lan_token} characters, not ${token.len}'
	}
	if token.len > bridge_max_str {
		return 'at most ${bridge_max_str} characters, not ${token.len}'
	}
	// A bridge started in WSL is given it on a command line that the distribution's shell reads,
	// so only what no shell expands or splits.
	if !token.bytes().all(it.is_alnum() || it in bridge_token_marks) {
		return 'letters, digits and ${bridge_token_marks.bytestr()} only'
	}
	return none
}

// bridge_is_loopback is whether an address only this machine can reach. The wildcard addresses
// are reachable from everywhere.
fn bridge_is_loopback(host string) bool {
	if b := bridge_ip4_bytes(host) {
		return b[0] == 127
	}
	if b := bridge_ip6_bytes(host) {
		// ::1, and IPv4's loopback mapped (::ffff:127.x.x.x)
		if b[..15].all(it == 0) && b[15] == 1 {
			return true
		}
		return b[..10].all(it == 0) && b[10] == 0xff && b[11] == 0xff && b[12] == 127
	}
	return false
}

// bridge_dial_host is the address a bridge on this machine dials: the bound one, or 127.0.0.1 when
// the listener is bound to every address. IPv4's for `[::]` too, which takes both families: WSL's
// mirrored networking forwards 127.0.0.1 to the host and not ::1.
fn bridge_dial_host(host string) string {
	if b := bridge_ip4_bytes(host) {
		return if b.all(it == 0) { '127.0.0.1' } else { host }
	}
	if b := bridge_ip6_bytes(host) {
		return if b.all(it == 0) { '127.0.0.1' } else { host }
	}
	return host
}

// bridge_host_port is `host:port`, an IPv6 address in brackets.
fn bridge_host_port(host string, port int) string {
	return if host.contains(':') { '[${host}]:${port}' } else { '${host}:${port}' }
}

// bridge_ip4_bytes reads a dotted-quad IPv4 address, four decimal numbers 0..255 without
// leading zeros.
fn bridge_ip4_bytes(s string) ?[]u8 {
	parts := s.split('.')
	if parts.len != 4 {
		return none
	}
	mut out := []u8{cap: 4}
	for p in parts {
		if p == '' || p.len > 3 || !p.bytes().all(it.is_digit()) || (p.len > 1 && p[0] == `0`) {
			return none
		}
		v := p.int()
		if v > 255 {
			return none
		}
		out << u8(v)
	}
	return out
}

// bridge_ip6_bytes reads an IPv6 address in its text form (RFC 4291 2.2): eight groups of up to
// four hex digits, one `::` standing for a run of zero groups, the last two groups optionally a
// dotted-quad IPv4 address. No zone (`%eth0`).
fn bridge_ip6_bytes(s string) ?[]u8 {
	if s == '' || s.count('::') > 1 {
		return none
	}
	halves := s.split('::')
	head := if halves[0] == '' { []string{} } else { halves[0].split(':') }
	tail := if halves.len < 2 || halves[1] == '' { []string{} } else { halves[1].split(':') }
	mut groups := [][]u8{}
	for k, g in head {
		last := halves.len == 1 && k == head.len - 1
		groups << bridge_ip6_group(g, last)?
	}
	mut tail_groups := [][]u8{}
	for k, g in tail {
		tail_groups << bridge_ip6_group(g, k == tail.len - 1)?
	}
	mut n := 0
	for g in groups {
		n += g.len
	}
	for g in tail_groups {
		n += g.len
	}
	if halves.len == 1 {
		if n != 16 {
			return none
		}
	} else if n > 14 {
		// `::` stands for at least one zero group
		return none
	}
	mut out := []u8{cap: 16}
	for g in groups {
		out << g
	}
	for _ in 0 .. 16 - n {
		out << 0
	}
	for g in tail_groups {
		out << g
	}
	return out
}

// bridge_ip6_group is one group's two bytes, or four for an IPv4 address in the last place.
fn bridge_ip6_group(g string, last bool) ?[]u8 {
	if last && g.contains('.') {
		return bridge_ip4_bytes(g)
	}
	if g == '' || g.len > 4 || !g.bytes().all(it.is_hex_digit()) {
		return none
	}
	v := u16(g.parse_uint(16, 16) or { return none })
	return [u8(v >> 8), u8(v)]
}
