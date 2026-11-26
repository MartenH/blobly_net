module transport

import net
import os

fn sample_ifaces() []NetIface {
	return [
		NetIface{
			index4: 1
			index6: 1
			name:   'lo'
			addr:   '127.0.0.1'
		},
		NetIface{
			index4: 2
			index6: 2
			name:   'eth1'
			addr:   '192.168.0.191'
		},
		NetIface{
			index4: 2
			index6: 2
			name:   'eth1'
			addr:   'fe80::1e36:cc8d:9811:d04d%eth1'
		},
		NetIface{
			index4: 3
			index6: 3
			name:   'tap1'
			addr:   '192.168.62.3'
		},
		NetIface{
			index4: 4
			index6: 4
			name:   'tap2'
			addr:   '192.168.62.3'
		},
		NetIface{
			index4: 7
			index6: 0
			name:   'Ethernet 2'
			alias:  '{4D36E972-E325-11CE-BFC1-08002BE10318}'
			addr:   '10.0.0.5'
		},
		NetIface{
			index4: 9
			index6: 9
			name:   'wg0'
		},
	]
}

fn test_an_interface_is_found_by_name_or_by_an_address_it_holds() {
	f := sample_ifaces()
	assert join_index(f, 'eth1', false)! == 2
	assert join_index(f, '192.168.0.191', false)! == 2
	assert join_index(f, '192.168.0.191', true)! == 2, 'an address names the interface, not the family'
	assert join_index(f, 'fe80::1e36:cc8d:9811:d04d', true)! == 2
	assert join_index(f, 'fe80::1e36:cc8d:9811:d04d%eth1', true)! == 2
	assert join_index(f, 'Ethernet 2', false)! == 7
	assert join_index(f, '{4D36E972-E325-11CE-BFC1-08002BE10318}', false)! == 7
	assert join_index(f, 'wg0', true)! == 9, 'an interface with no address is joined by name'
}

fn test_an_interface_the_host_does_not_have_is_refused_naming_those_it_has() {
	join_index(sample_ifaces(), 'eth9', false) or {
		assert err.msg() == 'no network interface "eth9" on this host (by name or address; it has lo, eth1, tap1, tap2, Ethernet 2, wg0)'
		return
	}
	assert false, 'an unknown interface was joined on'
}

fn test_an_address_two_interfaces_hold_is_refused() {
	join_index(sample_ifaces(), '192.168.62.3', false) or {
		assert err.msg().contains('several interfaces (tap1, tap2)'), err.msg()
		return
	}
	assert false, 'an ambiguous address was joined on'
}

fn test_an_interface_without_the_groups_family_is_refused() {
	join_index(sample_ifaces(), 'Ethernet 2', true) or {
		assert err.msg() == 'interface "Ethernet 2" has no IPv6 on this host'
		return
	}
	assert false, 'an IPv6 group joined on an interface with no IPv6 index'
}

fn test_the_shims_lines_are_read() {
	got := parse_netifaces('1\t1\tlo\t\t127.0.0.1\n7\t0\tEthernet 2\t{G}\t10.0.0.5\n2\t2\teth0\t\t\nbroken\n')
	assert got.len == 3
	assert got[1] == NetIface{
		index4: 7
		index6: 0
		name:   'Ethernet 2'
		alias:  '{G}'
		addr:   '10.0.0.5'
	}
	assert got[2].addr == ''
}

fn test_the_host_lists_its_loopback() {
	f := local_netifaces()!
	assert f.any(it.addr == '127.0.0.1'), '${f}'
}

fn test_an_interface_without_a_group_is_refused() {
	udp_bind('0.0.0.0:0', '', 'lo') or {
		assert err.msg().contains('needs a multicast group'), err.msg()
		return
	}
	assert false, 'an interface with no group was accepted'
}

fn test_a_group_on_an_unknown_interface_is_refused_by_name() {
	udp_bind('0.0.0.0:0', '239.14.0.1', 'nosuch0') or {
		assert err.msg().starts_with('cannot join 239.14.0.1 on nosuch0: no network interface "nosuch0" on this host'), err.msg()
		return
	}
	assert false, 'a group joined on an interface the host does not have'
}

fn test_a_unicast_address_is_not_a_group() {
	udp_bind('0.0.0.0:0', '10.1.2.3', 'lo') or {
		assert err.msg().contains('10.1.2.3 is not a multicast address'), err.msg()
		return
	}
	assert false, 'a unicast address joined as a group'
}

// a loopback group of this process's own: the port the OS gave the listener keeps other runs out
fn loop_group(second int) string {
	pid := os.getpid()
	return '239.${second}.${(pid >> 8) & 0xFF}.${1 + pid % 254}'
}

// send_to_group sends `data` to group:port out of the loopback interface.
fn send_to_group(group string, port int, data []u8) ! {
	mut s := net.dial_udp('${group}:${port}')!
	defer {
		s.close() or {}
	}
	s.set_multicast_interface('127.0.0.1')!
	s.set_multicast_loop(true)!
	s.write(data)!
}

fn bound_port(mut c net.UdpConn) int {
	return int(net.addr_from_socket_handle(c.sock.handle).port() or { 0 })
}

// Linux joins a group on `lo` (by name or by its address) and delivers what is sent out of it;
// a group joined on another interface hears none of it.
fn test_a_group_joined_on_loopback_hears_what_loopback_carries() ! {
	$if !linux {
		return
	}
	for i, spec in ['lo', '127.0.0.1'] {
		group := loop_group(14 + i)
		mut c := udp_bind('0.0.0.0:0', group, spec)!
		port := bound_port(mut c)
		send_to_group(group, port, 'hi'.bytes())!
		d := udp_read(mut c, 1000) or {
			c.close() or {}
			assert false, 'nothing heard on ${group}:${port} joined on ${spec}'
			return
		}
		c.close() or {}
		assert d.data == 'hi'.bytes()
	}
	// another interface with an IPv4 address, where this host has one
	other := local_netifaces()!.filter(it.name != 'lo' && it.addr.count('.') == 3)
	if other.len == 0 {
		return
	}
	group := loop_group(16)
	mut c := udp_bind('0.0.0.0:0', group, other[0].name)!
	defer {
		c.close() or {}
	}
	port := bound_port(mut c)
	send_to_group(group, port, 'hi'.bytes())!
	if d := udp_read(mut c, 300) {
		assert false, 'a group joined on ${other[0].name} heard loopback: ${d.data}'
	}
}

// an IPv6 group is joined on an interface by name (its index) as an IPv4 one is
fn test_an_ipv6_group_is_joined_on_loopback_by_name() {
	$if !linux {
		return
	}
	mut c := udp_bind('[::]:0', 'ff12::1:7701', 'lo') or {
		if err.msg().contains('cannot listen') {
			return // no IPv6 on this host
		}
		assert false, err.msg()
		return
	}
	c.close() or {}
}
