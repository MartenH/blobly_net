module transport

import net

const lan_token = '0123456789abcdef'

fn test_unset_is_the_loopback_listener() {
	cfg := bridge_listen_cfg('', '')!
	assert cfg == BridgeListenCfg{}
	assert cfg.host == '127.0.0.1' && cfg.port == 0 && !cfg.configured
	// a token alone fixes nothing a bridge could be told
	bridge_listen_cfg('', lan_token) or {
		assert err.msg().contains(bridge_listen_env)
		return
	}
	assert false
}

fn test_listen_addresses() {
	for listen, want in {
		'0.0.0.0:29500':          '0.0.0.0'
		'192.168.1.5:29500':      '192.168.1.5'
		'[::]:29500':             '::'
		'[fe80::1:2]:1':          'fe80::1:2'
		'[::ffff:10.0.0.1]:65535': '::ffff:10.0.0.1'
	} {
		cfg := bridge_listen_cfg(listen, lan_token)!
		assert cfg.host == want && cfg.configured && cfg.token == lan_token
	}
	assert bridge_listen_cfg('[::]:29500', lan_token)!.port == 29500
	for bad in ['29500', ':29500', 'localhost:29500', 'board.local:29500', '0.0.0.0:0',
		'0.0.0.0:65536', '0.0.0.0:', '0.0.0.0:+1', '0.0.0.0:2x', '::1:29500', '[::1:29500',
		'[::1]29500', '[1::2::3]:1', '[g::1]:1', '256.0.0.1:1', '01.2.3.4:1', '1.2.3:1'] {
		bridge_listen_cfg(bad, lan_token) or {
			assert err.msg().contains(bridge_listen_env), bad
			continue
		}
		assert false, '${bad} was accepted'
	}
}

fn test_tokens() {
	// loopback: random when unset, any length when set
	assert bridge_listen_cfg('127.0.0.1:29500', '')!.token == ''
	assert bridge_listen_cfg('[::1]:29500', 'x')!.token == 'x'
	// off loopback: fixed, and long enough
	for listen in ['0.0.0.0:29500', '[::]:29500', '10.0.0.2:1'] {
		for bad in ['', 'x'.repeat(bridge_min_lan_token - 1)] {
			bridge_listen_cfg(listen, bad) or {
				assert err.msg().contains(bridge_token_env)
				continue
			}
			assert false, '${listen} took "${bad}"'
		}
		assert bridge_listen_cfg(listen, 'x'.repeat(bridge_min_lan_token))!.configured
		assert bridge_listen_cfg(listen, 'Ab9-_.+=:,@%/0123')!.configured
	}
	// what a command line or the hello cannot carry
	for bad in ['with space 0123456', 'quote"0123456789', 'tab\t0123456789ab', 'é0123456789abcde',
		'bench\$ecret-2026xx', 'k7Qx9vR2;echo-0123', '~0123456789abcdef', 'a*0123456789abcdef',
		"it's-0123456789abc", 'x'.repeat(bridge_max_str + 1)] {
		bridge_listen_cfg('0.0.0.0:1', bad) or { continue }
		assert false, '"${bad}" was accepted'
	}
}

fn test_loopback_and_dial_host() {
	for h in ['127.0.0.1', '127.255.0.9', '::1', '0:0:0:0:0:0:0:1', '::ffff:127.0.0.1'] {
		assert bridge_is_loopback(h), h
	}
	for h in ['0.0.0.0', '::', '10.0.0.1', '::2', 'fe80::1', '::ffff:10.0.0.1'] {
		assert !bridge_is_loopback(h), h
	}
	assert bridge_dial_host('0.0.0.0') == '127.0.0.1'
	// mirrored WSL forwards 127.0.0.1 to the host, not ::1, and [::] takes both families
	assert bridge_dial_host('::') == '127.0.0.1'
	assert bridge_dial_host('0:0::0') == '127.0.0.1'
	assert bridge_dial_host('::1') == '::1'
	assert bridge_dial_host('192.168.1.5') == '192.168.1.5'
	assert bridge_host_port('::1', 5) == '[::1]:5'
	assert bridge_host_port('127.0.0.1', 5) == '127.0.0.1:5'
	assert bridge_launch_args('Ubuntu', BridgeEndpoint{ host: '::1', port: 7, token: 't' }) == [
		'--vcan',
		'${bridge_wsl_vcans}',
		'--connect',
		'[::1]:7',
		'--token',
		't',
		'--name',
		'Ubuntu',
	]
}

fn test_ip6_text() {
	assert bridge_ip6_bytes('::')? == []u8{len: 16}
	mut one := []u8{len: 16}
	one[15] = 1
	assert bridge_ip6_bytes('::1')? == one
	assert bridge_ip6_bytes('0:0:0:0:0:0:0:1')? == one
	assert bridge_ip6_bytes('2001:DB8::FF00:42:8329')? == [u8(0x20), 0x01, 0x0d, 0xb8, 0, 0, 0, 0,
		0, 0, 0xff, 0x00, 0x00, 0x42, 0x83, 0x29]
	assert bridge_ip6_bytes('1::')?[..2] == [u8(0), 1]
	assert bridge_ip6_bytes('::ffff:1.2.3.4')?[10..] == [u8(0xff), 0xff, 1, 2, 3, 4]
	for bad in ['', ':', ':::', '1:2:3:4:5:6:7', '1:2:3:4:5:6:7:8:9', '1::2:3:4:5:6:7:8',
		'12345::', '1.2.3.4', '::1.2.3.4:1', 'fe80::1%eth0', '1:2:3:4:5:6:7:', ':1:2:3:4:5:6:7'] {
		if _ := bridge_ip6_bytes(bad) {
			assert false, '${bad} read as IPv6'
		}
	}
}

fn test_a_bridge_connection_is_kept_alive_at_its_timers() {
	mut l := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer {
		l.close() or {}
	}
	mut c := net.dial_tcp(l.addr()!.str())!
	defer {
		c.close() or {}
	}
	bridge_keepalive(mut c)
	$if linux {
		fd := i32(c.sock.handle)
		mut on := i32(0)
		mut idle := i32(0)
		mut probes := i32(0)
		mut n := u32(sizeof(i32))
		assert C.getsockopt(fd, i32(C.SOL_SOCKET), i32(C.SO_KEEPALIVE), &on, &n) == 0
		assert on == 1
		assert C.getsockopt(fd, i32(C.IPPROTO_TCP), i32(C.TCP_KEEPIDLE), &idle, &n) == 0
		assert idle == bridge_keepalive_idle_s
		assert C.getsockopt(fd, i32(C.IPPROTO_TCP), i32(C.TCP_KEEPCNT), &probes, &n) == 0
		assert probes == bridge_keepalive_probes
	}
}
