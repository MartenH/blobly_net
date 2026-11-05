module lin

import blobly.lindb

const edit_ldf = @VMODROOT + '/dbc/lin_demo.ldf'

fn test_a_typed_value_reads_as_a_decoded_one_is_shown() {
	l := lindb.load_ldf(edit_ldf)!
	assert value_of_text(l, 'x', 'raw:12')! == lindb.Value(u64(12))
	assert value_of_text(l, 'x', 'raw:0x1F')! == lindb.Value(u64(31))
	assert value_of_text(l, 'x', 'phys:1.5')! == lindb.Value(1.5)
	assert value_of_text(l, 'x', 'text:Open')! == lindb.Value('Open')
	assert value_of_text(l, 'x', 'bytes:01 ff')! == lindb.Value([u8(1), 0xFF])
	assert value_of_text(l, 'x', 'Closed')! == lindb.Value('Closed')
	assert value_of_text(l, 'x', '"123"')! == lindb.Value('123')
	// a bare number is physical where the signal has a physical range, else raw
	assert value_of_text(l, 'CabinTemp', '21.5')! == lindb.Value(21.5)
	assert value_of_text(none, 'x', '7')! == lindb.Value(u64(7))
	assert value_of_text(none, 'x', '0x10')! == lindb.Value(u64(16))
	for bad in ['', 'raw:-1', 'raw:x', 'phys:abc', 'bytes:123', 'bytes:zz'] {
		value_of_text(none, 'x', bad) or { continue }
		assert false, bad
	}
}

fn test_a_row_sets_the_frames_its_simulated_nodes_publish() {
	mut r := start_row(RowSpec{
		name:     'B'
		address:  'inproc:edit_sim'
		ldf:      edit_ldf
		role:     .master
		simulate: ['CEM', 'LSM']
	}, RowOpts{})!
	defer {
		r.stop()
	}
	l := r.ldf() or { panic('no ldf') }
	frames := r.simulated_frames()
	for f in l.frames.filter(it.kind == .unconditional) {
		assert (f.name in frames) == (f.publisher in ['CEM', 'LSM']), f.name
	}
	mut m := start_row(RowSpec{
		name:     'M'
		address:  'inproc:edit_mon'
		ldf:      edit_ldf
		role:     .monitor
	}, RowOpts{})!
	defer {
		m.stop()
	}
	assert m.simulated_frames() == []
}

fn test_a_signal_reads_in_one_cell_as_it_is_typed_back() {
	l := lindb.load_ldf(edit_ldf)!
	f := l.frame('CEM_Frm2') or { panic('no frame') }
	data := l.encode(f, {
		'CabinTemp': lindb.Value(21.5)
	})!
	mut shown := map[string]string{}
	for v in l.decode(f, data) {
		shown[v.name] = signal_text(v)
	}
	assert shown['CabinTemp'] == 'CabinTemp=21.5 degC', shown.str()
	assert value_of_text(l, 'CabinTemp', shown['CabinTemp'].all_after('='))! == lindb.Value(21.5)
	// hex is raw, wherever the signal has a physical range
	assert value_of_text(l, 'CabinTemp', '0x10')! == lindb.Value(u64(16))
	assert value_of_text(l, 'CabinTemp', 'nan')! == lindb.Value('nan')
	assert signal_text(lindb.SignalValue{ name: 'S', raw: 3 }) == 'S=3'
	assert signal_text(lindb.SignalValue{ name: 'S', raw: 0, text: 'off' }) == 'S=off'
	assert signal_text(lindb.SignalValue{ name: 'B', is_array: true, bytes: [u8(1), 0xAB] }) == 'B=01 AB'
	// a byte array's bytes are typed back as shown
	arr := l.signals.filter(it.is_array && it.encoding == '')
	if arr.len > 0 {
		assert value_of_text(l, arr[0].name, '01 AB')! == lindb.Value([u8(1), 0xAB])
	}
}
