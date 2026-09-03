// arxml2dbc — export an AUTOSAR system description for the two consumers that cannot read
// one (#272): blobly_emb's build (DBC + a `[[frame]]` fragment for ecu.toml) and a user who
// needs to edit. blobly_net itself reads the .arxml natively; this is the honest snapshot.
//
//   v -enable-globals -path "@vlib|@vmodules|modules" run cmd/arxml2dbc/ <file.arxml> [options]
//
//   --cluster <name>   which CAN cluster (required when the file has several)
//   --ecu <name>       the `[[frame]]` fragment for this ECU only (tx for what it sends, rx
//                      for what it receives); default: every frame, as sent
//   --dbc <path>       write the DBC here (default: stdout)
//   --toml <path>      write the fragment here (default: not written). `--toml -` sends it
//                      to stdout INSTEAD of the DBC — one stream carries one file
//   --list             print the clusters and stop
//   --dump             print the messages and signals as read (the oracle's diff format)
//
// The DBC's network comment carries the provenance: source file, SHA-256, reader version,
// cluster, and how much the reader dropped — so an export found later can say which ARXML it
// came from and whether anyone edited it since. The report (dangling references, ignored
// element kinds, partial reads) goes to stderr, always: an importer that quietly drops a PDU
// is worse than one that refuses.
module main

import candb
import crypto.sha256
import os
import v.vmod

fn main() {
	args := os.args[1..].clone()
	mut src := ''
	mut cluster := ''
	mut ecu := ''
	mut dbc_out := ''
	mut toml_out := ''
	mut list := false
	mut dump_mode := false
	mut i := 0
	for i < args.len {
		a := args[i]
		match a {
			'-h', '--help' {
				usage()
				exit(0)
			}
			'--cluster' {
				cluster = take(args, i, a)
				i++
			}
			'--ecu' {
				ecu = take(args, i, a)
				i++
			}
			'--dbc' {
				dbc_out = take(args, i, a)
				i++
			}
			'--toml' {
				toml_out = take(args, i, a)
				i++
			}
			'--list' {
				list = true
			}
			'--dump' {
				dump_mode = true
			}
			else {
				if a.starts_with('-') || src != '' {
					eprintln('arxml2dbc: unexpected argument ${a}')
					usage()
					exit(2)
				}
				src = a
			}
		}
		i++
	}
	if src == '' {
		usage()
		exit(2)
	}
	text := os.read_file(src) or {
		eprintln('arxml2dbc: ${src}: ${err}')
		exit(1)
	}
	a := candb.parse_arxml(text) or {
		eprintln('arxml2dbc: ${src}: ${err}')
		exit(1)
	}
	for l in a.report.lines() {
		eprintln('arxml2dbc: ${l}')
	}
	if list {
		names := a.cluster_names()
		for ci, c in a.clusters {
			fd := if c.fd_baudrate > 0 { ' fd ${c.fd_baudrate}' } else { '' }
			// the first column is what --cluster takes: the SHORT-NAME, or the path when two
			// packages share one
			println('${names[ci]}\t${c.baudrate}${fd}\t${c.db.messages.len} messages\t${c.db.nodes.len} nodes\t${c.path}')
		}
		return
	}
	c := a.cluster(cluster) or {
		eprintln('arxml2dbc: ${src}: ${err}')
		exit(1)
	}
	if dump_mode {
		print(dump_cluster(c))
		return
	}
	version := (vmod.decode(@VMOD_FILE) or { panic('v.mod unparsable: ${err}') }).version
	dbc := c.export_dbc(candb.ArxmlProvenance{
		source: os.base(src)
		sha256: sha256.hexhash(text)
		reader: 'blobly_net ${version}'
		cluster: c.bus
	}, a.report)
	// stdout carries ONE file: the DBC by default, the fragment when `--toml -` asks for it
	toml_to_stdout := toml_out == '-'
	if dbc_out == '' || dbc_out == '-' {
		if !toml_to_stdout {
			print(dbc)
		}
	} else {
		os.write_file(dbc_out, dbc) or {
			eprintln('arxml2dbc: ${dbc_out}: ${err}')
			exit(1)
		}
		eprintln('arxml2dbc: wrote ${dbc_out} (${c.db.messages.len} messages)')
	}
	if toml_out != '' {
		if ecu != '' && ecu !in c.ecus() {
			// an empty fragment written with a success line is a typo turned into an ECU
			// that sends and receives nothing
			eprintln('arxml2dbc: no ECU "${ecu}" in cluster ${c.bus} (have ${c.ecus().join(', ')})')
			exit(1)
		}
		frag := c.frame_toml(ecu)
		if toml_to_stdout {
			print(frag)
		} else {
			os.write_file(toml_out, frag) or {
				eprintln('arxml2dbc: ${toml_out}: ${err}')
				exit(1)
			}
			eprintln('arxml2dbc: wrote ${toml_out}')
		}
	}
}

fn take(args []string, i int, flag string) string {
	if i + 1 >= args.len {
		eprintln('arxml2dbc: ${flag} needs a value')
		exit(2)
	}
	return args[i + 1]
}

fn usage() {
	eprintln('usage: arxml2dbc <file.arxml> [--cluster <name>] [--ecu <name>] [--dbc <out.dbc>] [--toml <out.toml>|-] [--list] [--dump]')
}

// dump_cluster prints the database in the line-per-fact form sut/arxml_oracle.py also
// produces from cantools, so the two can be diffed by `diff` alone.
fn dump_cluster(c candb.ArxmlCluster) string {
	mut b := []string{}
	b << 'cluster ${c.bus} baudrate=${c.baudrate} fd_baudrate=${c.fd_baudrate}'
	mut nodes := c.db.nodes.clone()
	nodes.sort()
	b << 'nodes ${nodes.join(',')}'
	mut msgs := c.db.messages.clone()
	msgs.sort_with_compare(candb.message_order)
	for m in msgs {
		f := c.frame_of(m) or { candb.ArxmlFrame{} }
		mut senders := m.senders()
		senders.sort()
		mut rx := f.receivers.clone()
		rx.sort()
		b << 'message ${m.name} id=0x${m.id:X} ext=${m.ext} len=${m.dlc} fd=${f.fd} cycle_ms=${m.cycle_ms} senders=${senders.join(',')} receivers=${rx.join(',')}'
		mut sigs := m.signals.clone()
		sigs.sort_with_compare(fn (x &candb.Signal, y &candb.Signal) int {
			return x.name.compare(y.name)
		})
		for s in sigs {
			order := if s.byte_order == .little_endian { 'little' } else { 'big' }
			mut keys := s.values.keys()
			keys.sort()
			mut ch := []string{}
			for k in keys {
				ch << '${k}=${s.values[k]}'
			}
			b << 'signal ${m.name}.${s.name} start=${s.start_bit} len=${s.length} order=${order} signed=${s.is_signed} factor=${candb.fmt_num(s.factor)} offset=${candb.fmt_num(s.offset)} unit=${s.unit} choices=${ch.join(';')}'
		}
		if e := f.e2e {
			// two lines: what cantools also models, and the layout only this reader carries —
			// CRC/counter bytes where the profile declares them, the header offset where it
			// declares that instead (a zero-valued default is not a position)
			b << 'e2e ${m.name} profile=${e.profile} data_id=${e.data_id}'
			if e.has_crc_counter {
				b << 'e2e-layout ${m.name} crc_byte=${e.crc_byte()} counter_byte=${e.counter_byte()}'
			} else {
				b << 'e2e-header ${m.name} offset_bit=${e.pdu_offset + e.data_offset + e.offset}'
			}
		}
		if s := f.secoc {
			b << 'secoc ${m.name} data_id=${s.data_id} payload_len=${s.authentic_len}'
		}
	}
	return b.join('\n') + '\n'
}
