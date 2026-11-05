// lin_monitor — watch a LIN bus, or run one: every frame as a line, decoded through an LDF.
//
//   lin_monitor <address> [--ldf FILE] [--role monitor|master|slave] [--simulate NODE,...]
//               [--schedule TABLE] [--baud N] [--seconds N]
//   lin_monitor --dump-ldf FILE
//
// A whole simulated cluster in one process, the LDF's master running its schedule:
//
//   lin_monitor inproc:body --ldf dbc/lin_demo.ldf --role master --simulate CEM,LSM,RSM \
//       --schedule NormalTable --seconds 2
//
// The bus is brought up as a blobly/lin Row, so the rules (what is published, the schedule,
// how a frame is read) are the engine's; this file is arguments and printing.
module main

import math
import os
import strconv
import time
import blobly.lin
import blobly.lindb
import blobly.transport

const usage = 'usage: lin_monitor <address> [--ldf FILE] [--role monitor|master|slave] [--simulate NODE,...] [--schedule TABLE] [--baud N] [--seconds N]
       lin_monitor --dump-ldf FILE'

fn main() {
	mut address := ''
	mut ldf := ''
	mut role := lin.Role.monitor
	mut simulate := []string{}
	mut schedule := ''
	mut baud := 0
	mut seconds := 0.0
	mut i := 1
	for i < os.args.len {
		a := os.args[i]
		if a in ['-h', '--help'] {
			println(usage)
			return
		}
		if !a.starts_with('--') {
			if address != '' {
				fail('one address, not `${address}` and `${a}`')
			}
			address = a
			i++
			continue
		}
		if a !in ['--dump-ldf', '--ldf', '--role', '--simulate', '--schedule', '--baud', '--seconds'] {
			fail('unknown option ${a}')
		}
		if i + 1 >= os.args.len {
			fail('${a} needs a value')
		}
		v := os.args[i + 1]
		match a {
			'--dump-ldf' {
				dump_ldf(v)
				return
			}
			'--ldf' {
				ldf = v
			}
			'--role' {
				role = match v {
					'monitor' { lin.Role.monitor }
					'master' { lin.Role.master }
					'slave' { lin.Role.slave }
					else { fail('--role is monitor, master or slave, not `${v}`') }
				}
			}
			'--simulate' {
				simulate = v.split(',').map(it.trim_space()).filter(it != '')
			}
			'--schedule' {
				schedule = v
			}
			'--baud' {
				baud = v.int()
				if baud.str() != v {
					fail('--baud takes a number, not `${v}`')
				}
			}
			'--seconds' {
				seconds = strconv.atof64(v) or { 0 }
				if math.is_nan(seconds) || math.is_inf(seconds, 0) || seconds <= 0 {
					fail('--seconds takes a positive number, not `${v}`')
				}
			}
			else {}
		}
		i += 2
	}
	if address == '' {
		fail('no address')
	}
	t0 := lin.MonoClock{}.now_ns()
	mut r := lin.start_row(lin.RowSpec{
		name:     address
		address:  address
		baud:     baud
		ldf:      ldf
		role:     role
		simulate: simulate
		schedule: schedule
	}, lin.RowOpts{}) or { fail(err.msg()) }
	for n in r.notes() {
		eprintln('note: ${n}')
	}
	mut t := r.tap() or { fail(err.msg()) }
	l := r.ldf()
	start := time.now()
	for {
		mut wait := 100
		if seconds > 0 {
			left := seconds - time.since(start).seconds()
			if left <= 0 {
				break
			}
			wait = int(math.min(100.0, math.ceil(left * 1000)))
		}
		f := t.recv(wait) or {
			if err is transport.CarrierGone {
				break
			}
			continue
		}
		if seconds > 0 && time.since(start).seconds() >= seconds {
			break
		}
		println(line(f, l, t0))
	}
	v := r.view()
	r.stop()
	eprintln('${v.frames.len} ids, load ${v.load_percent:.1f}%, ${v.dropped} dropped')
}

// line is one frame as the monitor prints it: time, origin, reading, then the LDF's signals.
fn line(f lin.Frame, l ?lindb.Ldf, t0 i64) string {
	mut s := '${f64(f.t_ns - t0) / 1e6:10.3f} ${lin.origin_of(f):-4} ${lin.reading(f)}'
	if ldf := l {
		if lin.has_id(f) {
			if resp := ldf.response_for(f.id, f.data) {
				s += '  ${resp.name}'
				if lf := resp.frame {
					for sv in ldf.decode(lf, f.data) {
						s += ' ${sv}'
					}
				}
			}
		}
	}
	return s
}

fn dump_ldf(path string) {
	l := lindb.load_ldf(path) or { fail(err.msg()) }
	print(l.dump())
	for n in l.notes {
		println('note ${n}')
	}
}

@[noreturn]
fn fail(msg string) {
	eprintln('lin_monitor: ${msg}\n${usage}')
	exit(2)
}
