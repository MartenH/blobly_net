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
	// REFUSED BEFORE ANY WRITE: an output path that is the SOURCE replaces the system description
	// — the one file this tool exists to leave alone — with its own output, and two outputs on
	// one path leave only the second after reporting both written (codex on #273 round 22).
	// Compared as real paths, so `./x.arxml` and `x.arxml` are one file.
	for out in [dbc_out, toml_out] {
		if out != '' && out != '-' && canon(out) == canon(src) {
			eprintln('arxml2dbc: ${out} is the input ARXML; refusing to overwrite the source')
			exit(2)
		}
	}
	both_files := dbc_out != '' && dbc_out != '-' && toml_out != '' && toml_out != '-'
	if both_files && canon(dbc_out) == canon(toml_out) {
		eprintln('arxml2dbc: --dbc and --toml name the same file (${dbc_out}); only one would survive')
		exit(2)
	}
	// AND THE ECU, before the first write: an empty fragment written with a success line is a
	// typo turned into an ECU that sends and receives nothing — and refused after the DBC was
	// already written, a typo left a regenerated DBC beside a stale TOML for the next build to
	// consume as a pair (round 26)
	if toml_out != '' && ecu != '' && ecu !in c.ecus() {
		eprintln('arxml2dbc: no ECU "${ecu}" in cluster ${c.bus} (have ${c.ecus().join(', ')})')
		exit(1)
	}
	// stdout carries ONE file: the DBC by default, the fragment when `--toml -` asks for it
	toml_to_stdout := toml_out == '-'
	dbc_to_file := dbc_out != '' && dbc_out != '-'
	frag := if toml_out != '' { c.frame_toml(ecu) } else { '' }
	if !dbc_to_file && !toml_to_stdout {
		print(dbc)
	}
	if toml_to_stdout {
		print(frag)
	}
	// STAGED, THEN MOVED INTO PLACE (round 33): both artifacts are written beside their
	// destinations first and renamed only once every write succeeded — a TOML write failing
	// (unwritable parent, full disk) after the DBC was already replaced left a regenerated DBC
	// beside the previous fragment, the inconsistent pair the ECU check above exists to prevent
	// ONE PUBLISHER AT A TIME per destination pair (round 35): two exports racing could still
	// interleave their two moves and leave one's DBC beside the other's fragment, each reporting
	// success. A directory is the portable atomic create; a stale one names the way out.
	// EVERY file destination, in one order (round 36): two exports sharing only the fragment
	// (`a.dbc`+`shared.toml`, `b.dbc`+`shared.toml`) each held their own DBC's lock and both
	// replaced the fragment. Sorted, so two exports of one pair cannot deadlock on each other
	mut dests := []string{}
	if dbc_to_file {
		dests << canon(dbc_out)
	}
	if toml_out != '' && !toml_to_stdout {
		dests << canon(toml_out)
	}
	dests.sort()
	mut locks := []string{}
	for d in dests {
		lock_dir := d + '.arxml2dbc.lock'
		os.mkdir(lock_dir) or {
			for held in locks {
				os.rmdir(held) or {}
			}
			eprintln('arxml2dbc: another export is publishing to ${d} (${lock_dir} exists); wait for it, or remove that directory if it is stale')
			exit(3)
		}
		locks << lock_dir
	}
	defer {
		for held in locks {
			os.rmdir(held) or {}
		}
	}
	mut staged := [][]string{} // [temporary, destination, what was written]
	// exit() does not run the defer above, so every failing path unlocks by hand (round 37)
	if dbc_to_file {
		staged << stage(dbc_out, dbc, staged) or { unlock_and_exit(locks, 1) }
		staged[staged.len - 1] << '${dbc_out} (${c.db.messages.len} messages)'
	}
	if toml_out != '' && !toml_to_stdout {
		staged << stage(toml_out, frag, staged) or { unlock_and_exit(locks, 1) }
		staged[staged.len - 1] << toml_out
	}
	// PUBLISHED WITH A WAY BACK (round 39): each destination that exists is set aside before its
	// replacement moves in, and a later move failing puts every earlier one back — so a reported
	// failure never leaves a regenerated DBC beside the previous fragment. The set-aside copies
	// go only once every move succeeded.
	mut set_aside := [][]string{} // [destination, its previous content's temporary]
	for st in staged {
		prev := st[1] + '.arxml2dbc.${os.getpid()}.prev'
		if os.exists(st[1]) {
			os.mv(st[1], prev) or {
				eprintln('arxml2dbc: ${st[1]}: cannot set the previous file aside: ${err}')
				roll_back(set_aside)
				unlock_and_exit(locks, 1)
			}
			set_aside << [st[1], prev]
		}
		os.mv(st[0], st[1]) or {
			eprintln('arxml2dbc: ${st[1]}: ${err}')
			roll_back(set_aside)
			unlock_and_exit(locks, 1)
		}
		eprintln('arxml2dbc: wrote ${st[2]}')
	}
	for sa in set_aside {
		os.rm(sa[1]) or {}
	}
}

// roll_back puts every destination that was set aside back where it was, newest first.
fn roll_back(set_aside [][]string) {
	for i := set_aside.len - 1; i >= 0; i-- {
		os.rm(set_aside[i][0]) or {}
		os.mv(set_aside[i][1], set_aside[i][0]) or {
			eprintln('arxml2dbc: could not restore ${set_aside[i][0]} from ${set_aside[i][1]}: ${err}')
		}
	}
}

// unlock_and_exit removes the publication locks and exits: a lock left by a failed export would
// refuse every later export to the same destination as "concurrent" until removed by hand.
@[noreturn]
fn unlock_and_exit(locks []string, code int) {
	for held in locks {
		os.rmdir(held) or {}
	}
	exit(code)
}

// stage writes `text` to a temporary beside `dst` and returns [temporary, dst]; on failure it
// removes every earlier staged temporary too, so nothing is left behind and nothing was replaced.
fn stage(dst string, text string, earlier [][]string) ![]string {
	// PER INVOCATION: two exports of one pair running at once wrote the same temporary and could
	// publish one's DBC with the other's TOML (round 34). Distinct temporaries end that; which of
	// two concurrent exports publishes last is still the caller's to order
	tmp := '${dst}.arxml2dbc.${os.getpid()}.tmp'
	os.write_file(tmp, text) or {
		eprintln('arxml2dbc: ${dst}: ${err}')
		for e in earlier {
			os.rm(e[0]) or {}
		}
		return err
	}
	return [tmp, dst]
}

// canon is a path spelling two names of one file agree on, whether or not the file exists yet:
// the parent's real path plus the base name. `os.real_path` of a leaf that does not exist yet
// returns its spelling unchanged, so `out` and `./out` compared unequal and the second write
// replaced the first (codex on #273 round 33).
fn canon(p string) string {
	if os.exists(p) {
		// an existing leaf resolves whole, symlink included: `link.arxml --dbc real.arxml`
		// compared two base names and overwrote the link's target (round 39)
		return os.real_path(p)
	}
	return os.join_path(os.real_path(os.dir(p)), os.base(p))
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
// signed_key is the integer a width-sized two's-complement pattern means.
fn signed_key(k u64, length int) i64 {
	if length <= 0 || length >= 64 {
		return i64(k)
	}
	if k & (u64(1) << (length - 1)) != 0 {
		return i64(k) - (i64(1) << length)
	}
	return i64(k)
}

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
			// a signed signal's negative choices are stored as width-sized two's-complement
			// patterns; shown as the integers they mean, sorted as such, which is what the
			// cantools oracle prints — `255=Invalid` for an 8-bit -1 was a false mismatch (round 26)
			mut ch := []string{}
			if s.is_signed {
				mut keys := s.values.keys().map(signed_key(it, s.length))
				keys.sort()
				mask := if s.length >= 64 { ~u64(0) } else { (u64(1) << s.length) - 1 }
				for k in keys {
					ch << '${k}=${s.values[u64(k) & mask]}'
				}
			} else {
				mut keys := s.values.keys()
				keys.sort()
				for k in keys {
					ch << '${k}=${s.values[k]}'
				}
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
