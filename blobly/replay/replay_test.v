module replay

import os
import time
import blobly.candb
import blobly.canlog
import blobly.transport

const repo = os.join_path(os.dir(@FILE), '..', '..')
const demo = os.join_path(repo, 'samples', 'demo.log')

fn dbc() candb.Database {
	return candb.load_dbc_file(os.join_path(repo, 'dbc', 'blobly_net.dbc')) or { panic(err) }
}

// drain counts what `b` receives until `quiet_ms` pass with nothing, by id.
fn drain(mut b transport.Bus, quiet_ms int) map[u32]int {
	mut got := map[u32]int{}
	for {
		f := b.recv(quiet_ms) or { break }
		got[f.id]++
	}
	return got
}

fn test_a_replay_plays_the_recording_onto_its_bus_and_finishes() {
	mut rx := transport.open('inproc:RPT1') or { panic(err) }
	defer {
		rx.close()
	}
	mut s := start(demo, [Target{
		name:  'R1'
		iface: 'inproc:RPT1'
		db:    dbc()
	}], speed: 20) or { panic(err) }
	assert s.wait_done(5000)
	got := drain(mut rx, 50)
	assert got[0x100] == 30 && got[0x700] == 30
	st := s.stop()
	assert st.sent == 60 && st.failed == 0 && st.passes == 1 && st.ended
	assert st.dur_s > 2.8 && st.dur_s < 3.0
	assert s.notes == ['R1: 60 frames, 0 withheld']
	s.pause() or {
		assert err.msg().contains('stopped')
		return
	}
	assert false, 'a stopped replay takes no command'
}

fn test_the_ecu_under_test_is_subtracted() {
	path := os.join_path(os.temp_dir(), 'replay_sub_${os.getpid()}.log')
	os.write_file(path, '(1.000000) can0 100#0102030405060708\n(1.010000) can0 200#0102030405060708\n(1.020000) can0 100#0102030405060708\n') or {
		panic(err)
	}
	defer {
		os.rm(path) or {}
	}
	mut rx := transport.open('inproc:RPT2') or { panic(err) }
	defer {
		rx.close()
	}
	mut s := start(path, [Target{
		name:    'R2'
		iface:   'inproc:RPT2'
		db:      dbc()
		exclude: ['SUT']
	}]) or { panic(err) }
	assert s.wait_done(2000)
	s.stop()
	assert drain(mut rx, 50) == {
		u32(0x200): 1
	}
	assert s.notes == ['R2: 1 frames, 2 withheld']
}

fn test_a_file_whose_times_fall_back_plays_in_time_order() {
	path := os.join_path(os.temp_dir(), 'replay_order_${os.getpid()}.log')
	os.write_file(path, '(1.000000) can0 200#01\n(1.400000) can0 200#03\n(1.100000) can0 200#02\n(1.100000) can0 200#04\n') or {
		panic(err)
	}
	defer {
		os.rm(path) or {}
	}
	log, _ := load(path) or { panic(err) }
	assert log.entries().map(it.frame.data[0]) == [u8(1), 2, 4, 3]
}

fn test_pause_seek_speed_and_loop_are_applied_before_they_return() {
	mut rx := transport.open('inproc:RPT3') or { panic(err) }
	defer {
		rx.close()
	}
	mut s := start(demo, [Target{
		name:  'R3'
		iface: 'inproc:RPT3'
		db:    dbc()
	}], paused: true) or { panic(err) }
	defer {
		s.stop()
	}
	assert s.status().state == .paused
	assert drain(mut rx, 60).len == 0
	s.seek(2.0) or { panic(err) }
	assert s.status().pos_s == 2.0
	s.set_speed(10) or { panic(err) }
	s.set_loop(true) or { panic(err) }
	st := s.status()
	assert st.speed == 10 && st.repeat && st.state == .paused
	s.resume() or { panic(err) }
	assert s.status().state == .playing
	assert !s.wait_done(400), 'a looping replay does not finish'
	s.pause() or { panic(err) }
	held := s.status()
	assert held.state == .paused && held.passes >= 1
	time.sleep(60 * time.millisecond)
	assert s.status().pos_s == held.pos_s
	s.set_speed(0) or {
		assert err.msg().contains('speed')
		return
	}
	assert false, 'a rate of 0 is refused'
}

// refusal is why start refused, or '' (and the replay stopped) when it did not.
fn refusal(source string, targets []Target, o Options) string {
	mut s := start(source, targets, o) or { return err.msg() }
	s.stop()
	return ''
}

fn test_what_would_play_something_else_is_refused() {
	t := Target{
		name:  'R4'
		iface: 'inproc:RPT4'
		db:    dbc()
	}
	assert refusal(demo, [Target{
		...t
		exclude: ['Nobody']
	}], Options{}).contains('declares Nobody')
	assert refusal(demo, [Target{
		...t
		exclude: ['SUT']
	}], Options{}).contains('nothing to play')
	assert refusal(demo, [t, Target{
		...t
		name: 'R5'
	}], Options{}).contains('mapped')
	assert refusal(demo, [Target{
		...t
		bus: 'can9'
	}], Options{}).contains('no bus "can9"')
	assert refusal(demo, [t], speed: 0).contains('speed')
	assert refusal('/nonexistent/x.log', [t], Options{}) != ''
}

fn test_a_recording_says_which_frames_were_ours() {
	path := os.join_path(os.temp_dir(), 'replay_rec_${os.getpid()}.log')
	defer {
		os.rm(path) or {}
	}
	mut r := record(path, [Target{
		name:  'Rec 1'
		iface: 'inproc:RPT6'
	}]) or { panic(err) }
	mut ours := transport.open('inproc:RPT6') or { panic(err) }
	// a raw in-process bus is not opened through transport.open, so nothing here saw it send
	mut theirs := transport.open_inproc('RPT6') or { panic(err) }
	ours.send(transport.CanFrame{ id: 0x101, data: [u8(1)] }) or { panic(err) }
	theirs.send(transport.CanFrame{ id: 0x102, data: [u8(2)] }) or { panic(err) }
	// 9 bytes go out padded to 12: noted as the wire carries it, so its echo is ours
	ours.send(transport.CanFrame{ id: 0x103, extended: true, fd: true, data: []u8{len: 9} }) or {
		panic(err)
	}
	c := r.stop() or { panic(err) }
	ours.close()
	theirs.close()
	assert c.frames == 3 && c.ours == 2 && c.theirs == 1 && c.missed == 0, c.str()
	es := canlog.load_file(path) or { panic(err) }
	assert es.map(it.frame.id) == [u32(0x101), 0x102, 0x103]
	assert es.map(it.dir) == [canlog.Dir.tx, .rx, .tx]
	assert es.all(it.iface == 'Rec 1')
	assert es[2].frame.fd && es[2].frame.extended && es[2].frame.data.len == 12
	assert es[1].t_s >= es[0].t_s && es[2].t_s >= es[1].t_s
}

fn test_a_burst_of_our_frames_is_ours_to_the_last() {
	path := os.join_path(os.temp_dir(), 'replay_burst_${os.getpid()}.log')
	defer {
		os.rm(path) or {}
	}
	mut r := record(path, [Target{
		name:  'B'
		iface: 'inproc:RPT14'
	}]) or { panic(err) }
	mut tx := transport.open('inproc:RPT14') or { panic(err) }
	for k in 0 .. 4000 {
		tx.send(transport.CanFrame{ id: 0x100, data: [u8(k), u8(k >> 8)] }) or { panic(err) }
	}
	tx.close()
	c := r.stop() or { panic(err) }
	assert c.frames == 4000 && c.ours == 4000 && c.missed == 0, c.str()
}

fn test_a_frame_no_candump_line_carries_is_said() {
	path := os.join_path(os.temp_dir(), 'replay_long_${os.getpid()}.log')
	defer {
		os.rm(path) or {}
	}
	mut r := record(path, [Target{
		name:  'L'
		iface: 'inproc:RPT15'
	}]) or { panic(err) }
	mut tx := transport.open('inproc:RPT15') or { panic(err) }
	tx.send(transport.CanFrame{ id: 0x123, data: []u8{len: 65} }) or { panic(err) }
	tx.close()
	r.stop() or {
		assert err.msg().contains('65 bytes')
		return
	}
	assert false, 'a frame the file cannot hold is not a clean recording'
}

fn test_a_replay_is_recorded_as_ours() {
	path := os.join_path(os.temp_dir(), 'replay_rec2_${os.getpid()}.log')
	defer {
		os.rm(path) or {}
	}
	mut r := record(path, [Target{
		name:  'R7'
		iface: 'inproc:RPT7'
	}]) or { panic(err) }
	mut s := start(demo, [Target{
		name:  'R7'
		iface: 'inproc:RPT7'
		db:    dbc()
	}], speed: 50) or { panic(err) }
	assert s.wait_done(3000)
	s.stop()
	c := r.stop() or { panic(err) }
	assert c.frames == 60 && c.ours == 60
	// and the file replays: the same frames, in the same order
	back := canlog.load_file(path) or { panic(err) }
	src := canlog.load_file(demo) or { panic(err) }
	assert back.map(it.frame.id) == src.map(it.frame.id)
	assert back.map(it.frame.data) == src.map(it.frame.data)
}

fn test_a_start_that_fails_keeps_an_earlier_capture_and_names_must_differ() {
	path := os.join_path(os.temp_dir(), 'replay_keep_${os.getpid()}.log')
	os.write_file(path, '(1.000000) can0 100#01\n') or { panic(err) }
	defer {
		os.rm(path) or {}
	}
	record(path, [Target{
		name:  'A'
		iface: 'no_such_can0'
	}]) or { assert err.msg().contains('cannot open') }
	assert os.read_file(path) or { '' } == '(1.000000) can0 100#01\n'
	record(path, [Target{
		name:  'A'
		iface: 'inproc:RPT9'
	}, Target{
		name:  'A'
		iface: 'inproc:RPT10'
	}]) or {
		assert err.msg().contains('two channels written as A')
		return
	}
	assert false
}

fn test_one_file_takes_one_recorder_and_is_a_regular_file() {
	path := os.join_path(os.temp_dir(), 'replay_one_${os.getpid()}.log')
	defer {
		os.rm(path) or {}
	}
	mut r := record(path, [Target{
		name:  'A'
		iface: 'inproc:RPT11'
	}]) or { panic(err) }
	record(path, [Target{
		name:  'B'
		iface: 'inproc:RPT12'
	}]) or { assert err.msg().contains('being recorded to already') }
	r.stop() or { panic(err) }
	mut again := record(path, [Target{
		name:  'B'
		iface: 'inproc:RPT12'
	}]) or { panic('a stopped recording frees its file: ${err}') }
	r.stop() or { panic(err) } // a second stop frees nobody else's file
	record(path, [Target{
		name:  'C'
		iface: 'inproc:RPT13'
	}]) or { assert err.msg().contains('being recorded to already') }
	// a frame no controller could send is refused for certain: not a send that went missing
	mut tx := transport.open('inproc:RPT12') or { panic(err) }
	tx.send(transport.CanFrame{ id: 0x100, brs: true }) or {}
	tx.close()
	c := again.stop() or { panic(err) }
	assert c.missed == 0 && c.frames == 0
	record(path, [Target{
		name:  ''
		iface: 'inproc:RPT11'
	}, Target{
		name:  'can'
		iface: 'inproc:RPT12'
	}]) or { assert err.msg().contains('written as can') }
	$if linux {
		record('/dev/null', [Target{
			name:  'A'
			iface: 'inproc:RPT11'
		}]) or {
			assert err.msg().contains('not a regular file')
			return
		}
		assert false
	}
}

fn test_two_channels_on_one_wire_are_refused() {
	record(os.join_path(os.temp_dir(), 'never.log'), [Target{
		name:  'A'
		iface: 'inproc:RPT8'
	}, Target{
		name:  'B'
		iface: 'inproc:RPT8'
	}]) or {
		assert err.msg().contains('one wire')
		return
	}
	assert false
}
