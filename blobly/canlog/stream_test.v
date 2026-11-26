module canlog

import os

// The line stream must hand out exactly what a replay loads (`parse_log(text).time_ordered()`):
// the same rows, in the same order, under the same label table — or count what it could not
// place, so the replay loads the file instead.

const stream_samples = ['samples/demo.log', 'samples/j1939-bam.log', 'projects/nm-demo/nm-demo.log']

fn stream_tmp(name string, text string) string {
	p := os.join_path(os.temp_dir(), 'canlog_stream_${os.getpid()}_${name}.log')
	os.write_file(p, text) or { panic(err) }
	return p
}

// streamed reads `path` through a stream reading `chunk` bytes at a time and holding `cap` rows.
fn streamed(path string, chunk int, cap int) (Log, &LineStream) {
	mut s := open_line_stream_with(path, chunk, cap) or { panic(err) }
	mut l := Log{}
	mut rows := []Row{}
	for {
		r := s.next(mut l) or { break }
		rows << r
	}
	s.close()
	l.rows = rows
	return l, s
}

fn assert_streams_as_loaded(name string, text string) {
	path := stream_tmp(name, text)
	defer {
		os.rm(path) or {}
	}
	want := parse_log(text).time_ordered()
	for chunk in [1, 2, 3, 7, 64, read_chunk] {
		got, s := streamed(path, chunk, readahead_rows)
		assert s.err == '' && s.out_of_order == 0, '${name} chunk=${chunk}'
		assert got.labels == want.labels, '${name} chunk=${chunk}'
		assert got.rows.len == want.rows.len, '${name} chunk=${chunk}'
		for i in 0 .. want.rows.len {
			assert got.rows[i] == want.rows[i], '${name} chunk=${chunk} row ${i}'
		}
	}
	sv := survey_file(path) or { panic(err) }
	assert sv.frames == u64(want.rows.len)
	assert sv.labels == want.labels
	for i, lbl in want.labels {
		mut n := 0
		for r in want.rows {
			if want.labels[r.bus] == lbl {
				n++
			}
		}
		assert sv.counts[i] == n, '${name} ${lbl}'
	}
	if want.rows.len > 0 {
		assert sv.t0 == want.rows[0].t_s && sv.end == want.rows[want.rows.len - 1].t_s
	}
}

fn test_the_samples_stream_as_they_load() {
	for name in stream_samples {
		text := os.read_file(@VMODROOT + '/' + name) or { panic(err) }
		assert parse_log(text).rows.len > 0, name
		assert_streams_as_loaded(os.base(name), text)
	}
}

fn test_every_line_form_streams_as_it_loads() {
	// directions, FD with its flags, remote frames, extended ids, an escaped label, comments,
	// blank and malformed lines, CRLF and a lone CR, ties across buses, no final newline
	text := '# a comment\n' + '(1.000000) can0 100#0102 R\n' + '(1.000000) can1 101#03 T\r\n' +
		'(1.000000) can0 102#\r' + '\n\n   \n' + '(1.500000) can0 123##1DEADBEEF0011223344\n' +
		'(1.500000) can1 18FEF100##3' + '00'.repeat(64) + '\n' + '(1.600000) can0 200#R8\n' +
		'(1.600000) can0 201#R\n' + '(1.700000) Powertrain%20CAN 300#AA\n' + 'garbage line\n' +
		'(1.800000) can0 1#ZZ\n' + '(1.900000) can0\n' + '(oops) can0 7FF#11\n' +
		'(2.000000)\tcan1\t7FF#1122'
	assert_streams_as_loaded('forms', text)
}

fn test_disorder_within_the_look_ahead_streams_in_the_loaders_order() {
	mut text := ''
	for k in 0 .. 400 {
		// each frame written up to 1.5 s late, and every fifth a tie with its neighbour
		t := f64(k) * 0.01 + if k % 3 == 0 { 1.5 } else { 0.0 }
		bus := if k % 2 == 0 { 'can0' } else { 'can1' }
		text += '(${t:.6f}) ${bus} ${k % 5 + 0x100:03X}#${k % 256:02X}\n'
		if k % 5 == 0 {
			text += '(${t:.6f}) can2 ${k % 7 + 0x200:03X}#\n'
		}
	}
	assert parse_log(text).time_ordered().rows != parse_log(text).rows, 'the file is out of order'
	assert_streams_as_loaded('within', text)
}

fn test_disorder_past_the_look_ahead_is_counted() {
	text := '(10.0) can0 100#01\n(11.0) can0 100#02\n(13.5) can0 100#03\n(10.4) can0 100#04\n' +
		'(14.0) can0 100#05\n'
	path := stream_tmp('past', text)
	defer {
		os.rm(path) or {}
	}
	_, s := streamed(path, read_chunk, readahead_rows)
	assert s.out_of_order == 1, 'the 10.4 frame comes after 11.0 was handed out'
	assert s.max_disorder_s > lookahead_s
	sv := survey_file(path) or { panic(err) }
	assert sv.out_of_order == 1 && sv.frames == 5
}

fn test_a_time_that_is_no_number_is_counted() {
	path := stream_tmp('nan', '(1.0) can0 100#01\n(nan) can0 100#02\n(2.0) can0 100#03\n')
	defer {
		os.rm(path) or {}
	}
	got, s := streamed(path, read_chunk, readahead_rows)
	assert s.out_of_order == 1 && got.rows.len == 3
}

fn test_a_full_heap_hands_out_its_earliest_and_counts_it() {
	mut text := ''
	for k in 0 .. 50 {
		text += '(5.000000) can0 100#${k:02X}\n'
	}
	path := stream_tmp('cap', text)
	defer {
		os.rm(path) or {}
	}
	got, s := streamed(path, 16, 8)
	assert s.forced > 0 && s.out_of_order == 0 && s.max_queued == 8
	want := parse_log(text).time_ordered()
	assert got.rows == want.rows, 'one time throughout: file order, forced or not'
}

fn test_a_line_past_the_longest_is_skipped_and_counted() {
	text := '(1.0) can0 100#01\n' + 'x'.repeat(max_line + 1) + '\r\n(2.0) can0 100#02\n' +
		'y'.repeat(max_line) + '\n(3.0) can0 100#03\n' + 'z'.repeat(3 * max_line)
	path := stream_tmp('long', text)
	defer {
		os.rm(path) or {}
	}
	for chunk in [7, 4096, read_chunk] {
		got, s := streamed(path, chunk, readahead_rows)
		assert s.long_lines == 2 && s.carry.cap <= 2 * max_line + chunk, 'chunk=${chunk}'
		assert got.rows == parse_log(text).rows
	}
	sv := survey_file(path) or { panic(err) }
	assert sv.long_lines == 2 && sv.frames == 3
}

fn test_a_file_changed_after_it_was_opened_is_read_to_its_opened_size_only() {
	mut lines := []string{}
	for k in 0 .. 20_000 {
		lines << '(${f64(k) * 0.01:.6f}) can0 100#${k % 256:02X}\n'
	}
	text := lines.join('')
	path := stream_tmp('changed', text)
	defer {
		os.rm(path) or {}
	}
	// (20,000 lines, past what the C library buffers ahead of a read)
	// appended to after the open: the rows it had then, and no more
	mut s := open_line_stream_with(path, 64, readahead_rows) or { panic(err) }
	mut l := Log{}
	s.next(mut l) or { panic('a first row') }
	os.write_file(path, text + '(9.0) can0 100#FF\n') or { panic(err) }
	mut n := 1
	for {
		s.next(mut l) or { break }
		n++
	}
	s.close()
	assert s.err == '' && n == 20_000
	// cut short after the open: an error, not a clean end
	os.write_file(path, text) or { panic(err) }
	mut c := open_line_stream_with(path, 64, readahead_rows) or { panic(err) }
	c.next(mut l) or { panic('a first row') }
	os.write_file(path, text[..text.len / 2]) or { panic(err) }
	for {
		c.next(mut l) or { break }
	}
	c.close()
	assert c.err.contains('of the ${text.len} it had when opened'), c.err
}

fn test_a_missing_file_is_an_error() {
	if _ := open_line_stream('/nonexistent/x.log') {
		assert false
	}
	if _ := survey_file('/nonexistent/x.log') {
		assert false
	}
}
