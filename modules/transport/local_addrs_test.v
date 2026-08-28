module transport

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
