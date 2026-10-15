// canbridge — offer this host's CAN interfaces to a blobly_net running elsewhere (#451).
//
//   canbridge --connect 127.0.0.1:<port> --token <token> [--name <name>] [iface ...]
//
// It dials the app, offers the named interfaces (every CAN and vcan interface `ip link` lists,
// when none are named), and carries frames both ways until the app closes the connection; then it
// exits. The app starts it with the port and token of its listener — the Windows build runs it in
// WSL through `wsl.exe` — so nothing here is configured by hand. The name is what the channels are
// called on the app's side, `bridge:<name>/vcan0`: the WSL distribution by default, else the host.
module main

import net
import os
import time
import blobly.transport

const usage = 'usage: canbridge --connect <host:port> --token <token> [--name <name>] [iface ...]'

// How long to keep trying to reach the app: it is listening before it starts a bridge, but a
// cold WSL start can take a moment to bring networking up.
const connect_budget = 10 * time.second

fn main() {
	mut addr := ''
	mut token := ''
	mut name := ''
	mut ifaces := []string{}
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		match a {
			'--connect', '--token', '--name' {
				if i + 1 >= os.args.len {
					fail('${a} needs a value\n${usage}')
				}
				v := os.args[i + 1]
				match a {
					'--connect' { addr = v }
					'--token' { token = v }
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
	// Every CAN interface the host has, when none were named.
	if ifaces.len == 0 {
		found := transport.list_interfaces() or { []transport.Iface{} }
		ifaces = found.filter(it.kind in ['can', 'vcan']).map(it.iface)
	}
	if ifaces.len == 0 {
		fail('no CAN interface to offer: none named, and `ip link` lists no can or vcan interface')
	}
	mut c := dial(addr) or { fail('cannot reach ${addr}: ${err}') }
	eprintln('canbridge: ${name} offers ${ifaces.join(', ')} to ${addr}')
	transport.bridge_serve(mut c, transport.BridgeServeCfg{
		token:    token
		name:     name
		channels: ifaces
	}) or { fail('connection to ${addr} failed: ${err}') }
	c.close() or {}
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
