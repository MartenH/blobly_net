// ldf_dump — blobly/lindb's reading of an LDF as `Ldf.dump()` lines and its notes, then
// `Ldf.query`'s answer to each request on stdin, for sut/ldf_oracle.py to diff against
// ldfparser's.
//
//   v -enable-globals run sut/ldf_dump.v dbc/lin_demo.ldf < requests
module main

import os
import blobly.lindb

fn main() {
	if os.args.len != 2 {
		eprintln('usage: ldf_dump <file.ldf> < requests')
		exit(2)
	}
	l := lindb.load_ldf(os.args[1]) or {
		eprintln(err.msg())
		exit(1)
	}
	print(l.dump())
	for note in l.notes {
		println('note ${note}')
	}
	for line in os.get_raw_lines() {
		req := line.trim_right('\r\n')
		if req != '' {
			println(l.query(req))
		}
	}
}
