module main

// project_scaffold — fill a project .yml from what's discoverable, instead of hand-writing
// it. GUI-free; a thin consumer of modules/transport (and later modules/candb for the
// generator half). The eventual GUI "Bus Configuration" dialog calls the same module APIs.
//
//   project_scaffold scan         # discover bus interfaces -> a `channels:` block (stdout)
//
// Discovery summary goes to stderr so stdout can be redirected straight into a project file:
//   project_scaffold scan > projects/discovered.blobnet
import os
import transport

fn main() {
	cmd := if os.args.len > 1 { os.args[1] } else { 'scan' }
	match cmd {
		'scan' {
			ifaces := transport.list_interfaces() or {
				eprintln('discover failed: ${err}')
				exit(1)
			}
			eprintln('# discovered ${ifaces.len} interface(s):')
			for f in ifaces {
				br := if f.bitrate > 0 { ' @${f.bitrate}' } else { '' }
				tag := if f.virtual { ' (virtual)' } else { '' }
				eprintln('#   ${f.name}  [${f.kind}]${br}${tag}  ->  interface: ${f.iface}')
			}
			print(transport.channels_yaml(ifaces))
		}
		else {
			eprintln('usage: project_scaffold scan')
			exit(2)
		}
	}
}
