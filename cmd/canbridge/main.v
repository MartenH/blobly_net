// canbridge — offer this host's CAN interfaces to a blobly_net running elsewhere (#451).
//
//   canbridge --connect 127.0.0.1:<port> --token <token> [--name <name>] [--vcan <n>] [iface ...]
//
// It dials the app, offers the named interfaces (every CAN and vcan interface `ip link` lists,
// when none are named), and carries frames both ways until the app closes the connection; then it
// exits. The port and token are those of the app's listener (`transport.bridge_listen`); the
// Windows build is to start this in WSL through `wsl.exe` with both (#451's next step). The name is
// what the channels are called on the app's side, `bridge:<name>/vcan0`: the WSL distribution by
// default, else the host. A bridge the app refuses exits 1 with the app's reason.
//
// `--vcan <n>` makes sure vcan0..vcan<n-1> exist and are up (at mtu 72, so they carry CAN-FD),
// creating the missing ones — it needs root, which is how the Windows build runs it. Anything that
// stops the bridge after it has reached the app is reported TO the app, in place of the channels,
// since a bridge the app started has no console anyone sees.
module main

import net
import os
import time
import blobly.transport

const usage = 'usage: canbridge --connect <host:port> --token <token> [--name <name>] [--vcan <n>] [iface ...]'

// How long to keep trying to reach the app: it is listening before it starts a bridge, but a
// cold WSL start can take a moment to bring networking up.
const connect_budget = 10 * time.second

fn main() {
	mut addr := ''
	mut token := ''
	mut name := ''
	mut vcans := 0
	mut ifaces := []string{}
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		match a {
			'--connect', '--token', '--name', '--vcan' {
				if i + 1 >= os.args.len {
					fail('${a} needs a value\n${usage}')
				}
				v := os.args[i + 1]
				match a {
					'--connect' { addr = v }
					'--token' { token = v }
					'--vcan' { vcans = v.int() }
					else { name = v }
				}
				i += 2
				continue
			}
			'-h', '--help' {
				println(usage)
				exit(0)
			}
			else {
				if a.starts_with('-') {
					fail('unknown option ${a}\n${usage}')
				}
				ifaces << a
			}
		}
		i++
	}
	if addr == '' || token == '' {
		fail(usage)
	}
	if name == '' {
		name = os.getenv('WSL_DISTRO_NAME')
	}
	if name == '' {
		name = os.hostname() or { 'bridge' }
	}
	mut c := dial(addr) or { fail('cannot reach ${addr}: ${err}') }
	ensure_vcans(vcans) or { give_up(mut c, token, name, err.msg()) }
	// Every CAN interface the host has, when none were named.
	if ifaces.len == 0 {
		found := transport.list_interfaces() or { []transport.Iface{} }
		ifaces = found.filter(it.kind in ['can', 'vcan']).map(it.iface)
	}
	if ifaces.len == 0 {
		give_up(mut c, token, name, 'no CAN interface to offer: none named, and `ip link` lists no can or vcan interface')
	}
	eprintln('canbridge: ${name} offers ${ifaces.join(', ')} to ${addr}')
	transport.bridge_serve(mut c, transport.BridgeServeCfg{
		token:    token
		name:     name
		channels: ifaces
	}) or { fail('connection to ${addr} failed: ${err}') }
	c.close() or {}
}

// ensure_vcans makes sure vcan0..vcan<n-1> exist and are up at mtu 72.
fn ensure_vcans(n int) ! {
	for k in 0 .. n {
		dev := 'vcan${k}'
		if !os.exists('/sys/class/net/${dev}') {
			mut r := os.exec(['ip', 'link', 'add', 'dev', dev, 'type', 'vcan'])
			if r.exit_code != 0 {
				// The module may only need loading.
				os.exec(['modprobe', 'vcan'])
				r = os.exec(['ip', 'link', 'add', 'dev', dev, 'type', 'vcan'])
			}
			if r.exit_code != 0 {
				return error('cannot create ${dev}: ${r.output.trim_space()} — this kernel has no vcan module loaded; run scripts/setup_vcan.sh in the distribution, which loads one built by scripts/build_vcan_module.sh')
			}
		}
		r := os.exec(['ip', 'link', 'set', dev, 'mtu', '72', 'up'])
		if r.exit_code != 0 {
			return error('cannot bring ${dev} up: ${r.output.trim_space()}')
		}
	}
}

// give_up tells the app why this bridge cannot start, and exits.
@[noreturn]
fn give_up(mut c net.TcpConn, token string, name string, why string) {
	transport.bridge_report_failure(mut c, token, name, why) or {}
	c.close() or {}
	fail(why)
}

fn dial(addr string) !&net.TcpConn {
	deadline := time.now().add(connect_budget)
	for {
		c := net.dial_tcp(addr) or {
			if time.now() > deadline {
				return err
			}
			time.sleep(200 * time.millisecond)
			continue
		}
		return c
	}
	return error('unreachable')
}

@[noreturn]
fn fail(msg string) {
	eprintln('canbridge: ${msg}')
	exit(1)
}
