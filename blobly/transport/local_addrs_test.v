module transport

import time

fn test_ip_json_yields_every_inet_address_but_loopback_by_name() {
	text :=
		'[{"ifname":"lo","addr_info":[{"family":"inet","local":"127.0.0.1"},{"family":"inet","local":"10.255.255.254"}]},' +
		'{"ifname":"eth0","addr_info":[{"family":"inet","local":"192.168.0.190"},{"family":"inet6","local":"fe80::1"}]},' +
		'{"ifname":"eth1","addr_info":[{"family":"inet","local":"10.165.125.100"}]}]'
	assert ipv4_addrs_from_ip_json(text) == ['192.168.0.190', '10.165.125.100']
	assert ipv4_addrs_from_ip_json('not json') == []
}

fn test_ipconfig_is_read_in_any_locale() {
	text := 'Ethernet adapter Ethernet 3:\r\n' +
		'   IPv4 Address. . . . . . . . . . . : 10.165.125.100(Preferred)\r\n' +
		'   Subnet Mask . . . . . . . . . . . : 255.255.255.0\r\n' +
		'Ethernet-Adapter Ethernet 4:\r\n' +
		'   IPv4-Adresse  . . . . . . . . . . : 192.168.0.190\r\n' +
		'   Standardgateway . . . . . . . . . : 192.168.0.1\r\n' +
		'Loopback Pseudo-Interface 1:\r\n' +
		'   IPv4 Address. . . . . . . . . . . : 127.0.0.1\r\n' +
		'   Link-local IPv6 Address . . . . . : fe80::1%3\r\n'
	assert ipv4_addrs_from_ipconfig(text) == ['10.165.125.100', '192.168.0.190']
}

// macOS `ifconfig`: every `inet` line's address on any interface, loopback and `inet6` excluded,
// an address once however many interfaces carry it (a bridge and its member).
fn test_ifconfig_yields_every_inet_address_but_loopback() {
	text := 'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384\n' +
		'\tinet 127.0.0.1 netmask 0xff000000\n' +
		'\tinet6 ::1 prefixlen 128\n' +
		'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n' +
		'\tether a4:83:e7:00:00:01\n' +
		'\tinet6 fe80::1c2b:3a4d:5e6f:7081%en0 prefixlen 64 secured scopeid 0xb\n' +
		'\tinet 192.168.0.190 netmask 0xffffff00 broadcast 192.168.0.255\n' +
		'en5: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n' +
		'\tinet 10.215.129.2 netmask 0xffffff00 broadcast 10.215.129.255\n' +
		'bridge0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n' +
		'\tinet 10.215.129.2 netmask 0xffffff00 broadcast 10.215.129.255\n' +
		'utun3: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280\n' +
		'\tinet 100.64.0.7 --> 100.64.0.7 netmask 0xffffffff\n'
	assert ipv4_addrs_from_ifconfig(text) == ['192.168.0.190', '10.215.129.2', '100.64.0.7']
	assert ipv4_addrs_from_ifconfig('') == []
	assert ipv4_addrs_from_ifconfig('\tinet not.an.address netmask 0x0\n') == []
}

fn test_the_interface_enumeration_keeps_to_its_deadline() {
	assert ipv4_enum_skipped(1000, 1000)
	assert !ipv4_enum_skipped(999, 1000)
	assert !ipv4_enum_skipped(5000, 0)
	// a deadline already passed asks nothing and waits for nothing
	t0 := time.ticks()
	assert local_ipv4_addrs_until(t0 - 1) == none
	assert time.ticks() - t0 < 50
}
