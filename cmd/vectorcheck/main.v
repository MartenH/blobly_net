// vectorcheck — bring up a Vector XL channel safely and prove it works, before any project or
// bench depends on it.
//
// SILENT BY DEFAULT. The channel is opened listen-only, so the transceiver never acknowledges
// and cannot disturb whatever is already on the wire. That matters most in exactly the case you
// reach for this tool: a VN channel wired to a running target, whose bitrate you believe you
// know. A node that goes on the bus at the wrong bitrate floods error frames and degrades the
// bus for everyone on it; a silent one that has the bitrate wrong simply reports nothing.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/vectorcheck/main.v --list
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/vectorcheck/main.v --channel 1
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/vectorcheck/main.v --channel 1 --transmit
//
// `-enable-globals` is not optional: modules/transport/inproc.v uses `__global`, and without it
// the build fails before anything Vector-specific is reached.
//
// From WSL, cross-compile and run the result on Windows — the XL library lives there:
//   v -os windows -enable-globals -path "@vlib|@vmodules|modules" -o vectorcheck.exe cmd/vectorcheck/main.v
module main

import os
import time
import transport

struct Opts {
	list     bool
	channel  int
	bitrate  int
	seconds  int
	transmit bool
}

fn usage() {
	eprintln('usage: vectorcheck --list')
	eprintln('       vectorcheck --channel <n> [--bitrate <bps>] [--seconds <n>] [--transmit]')
	eprintln('')
	eprintln('  --list      application channels with hardware assigned in Vector Hardware Config')
	eprintln('  --channel   application channel, as numbered in that dialog (from 1)')
	eprintln('  --bitrate   bits/s (default 500000)')
	eprintln('  --seconds   how long to listen (default 5)')
	eprintln('  --transmit  ALSO go on the bus able to acknowledge, and send one frame.')
	eprintln('              Leave it off against a live target until the bitrate is confirmed.')
}

fn parse(args []string) !Opts {
	mut o := Opts{
		bitrate: 500000
		seconds: 5
	}
	mut i := 0
	for i < args.len {
		match args[i] {
			'--list' {
				o = Opts{
					...o
					list: true
				}
			}
			'--transmit' {
				o = Opts{
					...o
					transmit: true
				}
			}
			'--channel' {
				i++
				o = Opts{
					...o
					channel: args[i] or { return error('--channel needs a value') }.int()
				}
			}
			'--bitrate' {
				i++
				o = Opts{
					...o
					bitrate: args[i] or { return error('--bitrate needs a value') }.int()
				}
			}
			'--seconds' {
				i++
				o = Opts{
					...o
					seconds: args[i] or { return error('--seconds needs a value') }.int()
				}
			}
			else {
				return error('unknown argument "${args[i]}"')
			}
		}

		i++
	}
	return o
}

fn main() {
	// Said HERE rather than by rejecting `vector:` in open_linux.v: on Linux the dispatcher
	// deliberately sends anything that is not a software bus to SocketCAN, so a channel someone
	// named with a vendor prefix keeps working. That contract is worth more than a tidy error,
	// but the operator running this on the wrong machine still deserves a straight answer.
	$if !windows {
		eprintln('vectorcheck: the Vector XL backend is Windows-only (vxlapi64.dll).')
		eprintln('Run this from Windows, not WSL — WSL has no access to the Vector driver.')
		eprintln('')
	}
	o := parse(os.args[1..]) or {
		eprintln('vectorcheck: ${err}')
		usage()
		exit(2)
	}
	if o.list {
		ifaces := transport.list_interfaces() or {
			eprintln('vectorcheck: ${err}')
			exit(1)
		}
		mut n := 0
		for f in ifaces {
			if f.iface.starts_with('vector:') {
				println('${f.iface}\t${f.name}')
				n++
			}
		}
		if n == 0 {
			// ASKED, not guessed. These two look identical from outside — nothing listed — and
			// they send you to completely different places, so the tool finds out which it is
			// instead of printing both possibilities and letting you choose.
			match transport.vector_driver_status() {
				0 {
					eprintln('The Vector driver is installed and working, but no application channel')
					eprintln('is assigned to hardware yet.')
					eprintln('')
					eprintln('Open Vector Hardware Configuration. The application "blobly_net" has just')
					eprintln('been registered there; assign a VN1630A channel to its channel 1.')
				}
				-1 {
					eprintln('vxlapi64.dll was not found.')
					eprintln('')
					eprintln('It is the Vector XL Driver Library, a SEPARATE download from the hardware')
					eprintln('drivers — the VN device, its kernel driver and Vector Hardware Manager can all')
					eprintln('be installed and working without it. Check Device Manager: if the VN adapter')
					eprintln('is listed and healthy, this library is the only thing missing.')
					eprintln('(On WSL this message is expected regardless: run the .exe from Windows.)')
				}
				-2 {
					eprintln('vxlapi64.dll loaded but is missing functions this backend needs.')
					eprintln('It is probably an old XL Driver Library; update the Vector Driver Setup.')
				}
				else {
					eprintln('vxlapi64.dll loaded, but xlOpenDriver failed (XL status ${-transport.vector_driver_status()}).')
					eprintln('Usually that means no Vector hardware is connected, or another')
					eprintln('application holds it exclusively.')
				}
			}

			exit(1)
		}
		return
	}
	if o.channel < 1 {
		usage()
		exit(2)
	}
	mode := if o.transmit { '' } else { ',silent' }
	spec := 'vector:${o.channel}@${o.bitrate}${mode}'
	println('opening ${spec}${if o.transmit {
		'  [CAN ACKNOWLEDGE]'
	} else {
		'  [silent: cannot disturb the bus]'
	}}')
	mut bus := transport.open(spec) or {
		eprintln('vectorcheck: ${err}')
		exit(1)
	}
	defer { bus.close() }

	if o.transmit {
		bus.send(transport.CanFrame{ id: 0x7FF, data: [u8(0xDE), 0xAD] }) or {
			eprintln('vectorcheck: transmit failed: ${err}')
		}
	}
	println('listening ${o.seconds}s…')
	deadline := time.now().add(o.seconds * time.second)
	mut seen := 0
	mut ids := map[u32]int{}
	for time.now() < deadline {
		f := bus.recv(200) or { continue }
		seen++
		ids[f.id]++
		if seen <= 10 {
			println('  ${f.id:08X}  [${f.data.len}]  ${f.data.hex()}')
		}
	}
	println('')
	println('${seen} frames on ${ids.len} distinct id(s) in ${o.seconds}s')
	if seen == 0 {
		// The two explanations look identical from here, and only one of them is a fault.
		eprintln('nothing arrived. Either the bus is idle, or the bitrate is not ${o.bitrate}.')
		eprintln('A silent channel with the wrong bitrate reports exactly this and disturbs nothing,')
		eprintln('so trying the other likely rates is safe.')
		exit(1)
	}
}
