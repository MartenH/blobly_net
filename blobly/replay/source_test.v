module replay

import math
import os
import blobly.candb
import blobly.canlog
import blobly.player
import blobly.transport

const mf4_samples = ['two_buses.mf4', 'both_dirs.mf4', 'demo.mf4']

const src_repo = os.join_path(os.dir(@FILE), '..', '..')

fn sample(name string) string {
	return os.join_path(src_repo, 'samples', name)
}

fn src_dbc() candb.Database {
	return candb.load_dbc_file(os.join_path(src_repo, 'dbc', 'blobly_net.dbc')) or { panic(err) }
}

// frames_on counts what `b` receives until `quiet_ms` pass with nothing.
fn frames_on(mut b transport.Bus, quiet_ms int) int {
	mut n := 0
	for {
		b.recv(quiet_ms) or { break }
		n++
	}
	return n
}

fn test_the_switch_streams_an_mf4_from_the_threshold_and_never_a_log() {
	assert streams('a.mf4', 64 << 20, 64)
	assert streams('A.MF4', 65 << 20, 64)
	assert !streams('a.mf4', (64 << 20) - 1, 64)
	assert streams('a.mf4', 0, 0), '0 streams every .mf4'
	assert !streams('a.log', 1 << 40, 0), 'a candump .log always loads'
	assert stream_mb_of('') == stream_mb_default
	assert stream_mb_of(' 0 ') == 0
	assert stream_mb_of('128') == 128
	assert stream_mb_of('-1') == stream_mb_default
	assert stream_mb_of('lots') == stream_mb_default
}

fn test_a_streamed_scan_is_the_loaded_scan() {
	db := src_dbc()
	for name in mf4_samples {
		got_buses, got := scan_at(sample(name), db, 0) or { panic(err) }
		want_buses, want := scan_at(sample(name), db, 1 << 20) or { panic(err) }
		assert got_buses == want_buses, name
		assert got.keys() == want.keys(), name
		for k, c in want {
			assert got[k].str() == c.str(), '${name} ${k}'
			assert c.total > 0
		}
	}
}

fn specs_for(src &Source, exclude []string) []player.BusSpec {
	mut specs := []player.BusSpec{}
	for i, b in src.buses {
		specs << player.BusSpec{
			src:     b.iface
			dst:     'live${i}'
			db:      src_dbc()
			exclude: exclude
		}
	}
	return specs
}

// drive plays `p` the way a replay worker does — commands taken once a tick through control.v,
// then the due frames — through a seek, a pause, a paused seek, a speed change, loop off and on,
// and a restart from finished; and writes down everything it emitted and published.
fn drive(mut p player.Player) []string {
	mut out := []string{}
	d := p.duration_s()
	step := if d > 0 { d * 1000.0 / 31.0 } else { 1.0 }
	mut now := 0.0
	mut batch := []canlog.LogEntry{}
	p.play(now)
	for k in 0 .. 160 {
		mut c := player.no_request()
		match k {
			20 { c.seek = d * 0.6 }
			30 { c.state = .paused }
			31 { c.seek = d * 0.25 }
			33 { c.state = .playing }
			40 { c.speed = 2.0 }
			50 { c.repeat = 1 }
			90 { c.repeat = 0 }
			130 { c.state = .playing } // from finished: a restart
			else {}
		}
		p.apply_latched(c)
		st := p.status(now)
		applied := p.apply_timed(c, now)
		p.wait_ready() // the reader's timing is not the test's
		p.due_into(now, mut batch)
		for e in batch {
			out << '${k} ${p.due_at_ms(e):.6f} ${e.iface} ${e.frame.id} ${e.frame.data}'
		}
		out << '${k} ${st.state} ${st.pos_s:.6f} ${st.speed} ${st.loops} ${st.repeat} ${applied.restarted} ${applied.revived}'
		now += step
	}
	return out
}

fn test_a_streamed_replay_decides_and_plays_as_the_loaded_one() {
	mut withheld := 0
	for name in mf4_samples {
		mem := open_recording_at(sample(name), 1 << 20) or { panic(err) }
		str := open_recording_at(sample(name), 0) or { panic(err) }
		assert !mem.streamed && str.streamed && str.log.len() == 0
		assert str.buses == mem.buses
		for exclude in [[]string{}, ['SUT']] {
			mut a := mem.prepare(specs_for(&mem, exclude)) or { panic(err) }
			mut b := str.prepare(specs_for(&str, exclude)) or { panic(err) }
			assert b.streamed && !a.streamed
			assert b.buses == a.buses, '${name} ${exclude}'
			assert b.t0_s == a.t0_s && b.end_s == a.end_s
			for bp in a.buses {
				withheld += bp.report.withheld_excluded
			}
			mut pa := a.player(1.0, false)
			mut pb := b.player(1.0, false)
			want := drive(mut pa)
			got := drive(mut pb)
			assert b.read_error() == ''
			b.close()
			a.close()
			if a.buses.any(it.report.kept > 0) {
				assert want.len > 160, name // frames were played, not only states
			}
			for i in 0 .. want.len {
				assert i < got.len && got[i] == want[i], '${name} ${exclude} line ${i}'
			}
			assert got.len == want.len
		}
	}
	assert withheld > 0, 'the samples have excluded senders'
}

fn test_a_script_replay_streams_a_large_mf4() {
	os.setenv('BLOBLY_MF4_STREAM_MB', '0', true)
	defer {
		os.unsetenv('BLOBLY_MF4_STREAM_MB')
	}
	src := sample('two_buses.mf4')
	rec := open_recording(src) or { panic(err) }
	assert rec.streamed
	mem := open_recording_at(src, 1 << 20) or { panic(err) }
	mut plan := mem.prepare(specs_for(&mem, [])) or { panic(err) }
	want := plan.buses.map(it.report.kept)
	plan.close()
	assert want.all(it > 0)
	mut rxs := []transport.Bus{}
	mut targets := []Target{}
	for i, b in rec.buses {
		rxs << transport.open('inproc:RPS${i}') or { panic(err) }
		targets << Target{
			name:  'S${i}'
			iface: 'inproc:RPS${i}'
			bus:   b.iface
			db:    src_dbc()
		}
	}
	mut s := start(src, targets, speed: 50) or { panic(err) }
	assert s.wait_done(10000)
	st := s.stop()
	mut total := 0
	for i, mut rx in rxs {
		n := frames_on(mut rx, 50)
		assert n == want[i]
		total += n
		rx.close()
	}
	assert st.sent == u64(total) && st.failed == 0 && st.error == '' && st.passes == 1
}

// Img assembles an MDF4 image: blocks appended in order, links patched afterwards.
struct Img {
mut:
	b []u8
}

fn le(v u64, k int) []u8 {
	mut o := []u8{cap: k}
	for i in 0 .. k {
		o << u8(v >> (8 * i))
	}
	return o
}

fn (mut m Img) block(id string, nlinks int, data []u8) u64 {
	off := u64(m.b.len)
	m.b << id.bytes()
	m.b << []u8{len: 4}
	m.b << le(u64(24 + 8 * nlinks + data.len), 8)
	m.b << le(u64(nlinks), 8)
	m.b << []u8{len: 8 * nlinks}
	m.b << data
	for m.b.len % 8 != 0 {
		m.b << 0
	}
	return off
}

fn (mut m Img) link(blk u64, i int, target u64) {
	for k, x in le(target, 8) {
		m.b[int(blk) + 24 + 8 * i + k] = x
	}
}

fn cn_data(cn_type u8, dtype u8, off u32, bits u32) []u8 {
	mut d := []u8{len: 72}
	d[0] = cn_type
	d[2] = dtype
	for i, x in le(off, 4) {
		d[4 + i] = x
	}
	for i, x in le(bits, 4) {
		d[8 + i] = x
	}
	return d
}

// Pat is one frame of the pattern write_mf4 cycles through.
struct Pat {
	id   u32
	ext  bool
	data []u8
}

// big_mf4 writes `n` frames over two buses, cycling through ids the test database gives to SUT
// and to other nodes.
fn big_mf4(path string, n int) {
	mut pats := []Pat{}
	for id in [u32(0x100), 0x200, 0x101, 0x300, 0x555, 0x102, 0x400] {
		pats << Pat{
			id:   id
			data: []u8{len: 8, init: u8(index)}
		}
	}
	write_mf4(path, n, pats, 2, 0.0005)
}

// write_mf4 writes a sorted MDF4 image of `n` frames cycling through `pats`, frame k on bus
// 1 + k % buses, `step_s` seconds apart: record layout as mf4_test.v's build_mlsd_file_x (time, id,
// IDE, DataLength, 8 data bytes, bus channel).
fn write_mf4(path string, n int, pats []Pat, buses int, step_s f64) {
	mut m := Img{}
	m.b << 'MDF     4.10    blobly  '.bytes()
	m.b << []u8{len: 4}
	m.b << le(410, 2)
	m.b << []u8{len: 34}
	hd := m.block('##HD', 6, []u8{len: 32})
	dg := m.block('##DG', 4, []u8{len: 8})
	mut cg_d := []u8{len: 32}
	for i, x in le(u64(n), 8) {
		cg_d[8 + i] = x
	}
	cg_d[24] = 26
	cg := m.block('##CG', 6, cg_d)
	cns := [cn_data(2, 4, 0, 64), cn_data(0, 10, 8, 0), cn_data(0, 0, 8, 32),
		cn_data(0, 0, 12, 1), cn_data(0, 0, 13, 32), cn_data(5, 10, 17, 64),
		cn_data(0, 0, 25, 8)]
	names := ['time', 'CAN_DataFrame', 'CAN_DataFrame.ID', 'CAN_DataFrame.IDE',
		'CAN_DataFrame.DataLength', 'CAN_DataFrame.DataBytes', 'CAN_DataFrame.BusChannel']
	mut cn_at := []u64{}
	for d in cns {
		cn_at << m.block('##CN', 8, d)
	}
	mut tx_at := []u64{}
	for nm in names {
		mut d := nm.bytes()
		d << 0
		tx_at << m.block('##TX', 0, d)
	}
	mut recs := []u8{cap: 26 * n}
	for k in 0 .. n {
		pt := pats[k % pats.len]
		recs << le(math.f64_bits(step_s * f64(k + 1)), 8)
		recs << le(u64(pt.id), 4)
		recs << u8(if pt.ext { 1 } else { 0 })
		recs << le(u64(pt.data.len), 4)
		mut d := pt.data.clone()
		d << []u8{len: 8 - d.len}
		recs << d
		recs << u8(1 + k % buses)
	}
	dt := m.block('##DT', 0, recs)
	m.link(hd, 0, dg)
	m.link(dg, 1, cg)
	m.link(dg, 2, dt)
	m.link(cg, 1, cn_at[0])
	m.link(cn_at[0], 0, cn_at[1])
	m.link(cn_at[1], 1, cn_at[2])
	for i in 2 .. cn_at.len - 1 {
		m.link(cn_at[i], 0, cn_at[i + 1])
	}
	for i in 0 .. cn_at.len {
		m.link(cn_at[i], 2, tx_at[i])
	}
	os.write_file_array(path, m.b) or { panic(err) }
}

fn test_a_recording_larger_than_one_read_streams_whole() {
	path := os.join_path(os.temp_dir(), 'replay_big_${os.getpid()}.mf4')
	big_mf4(path, 80_000) // 2 MB: past the stream's first read of the file
	defer {
		os.rm(path) or {}
	}
	mem := open_recording_at(path, 1 << 20) or { panic(err) }
	str := open_recording_at(path, 0) or { panic(err) }
	assert str.streamed && str.buses == mem.buses && mem.buses.len == 2
	mut a := mem.prepare(specs_for(&mem, ['SUT'])) or { panic(err) }
	mut b := str.prepare(specs_for(&str, ['SUT'])) or { panic(err) }
	assert b.buses == a.buses
	assert a.buses.all(it.report.withheld_excluded > 0 && it.report.kept > 0)
	mut pa := a.player(1.0, false)
	mut pb := b.player(1.0, false)
	want := drive(mut pa)
	got := drive(mut pb)
	assert b.read_error() == ''
	b.close()
	assert got == want
	assert want.len > 160 + 40_000
}

// A J1939 bus: EEC1 from the engine at its own address and at another (matched by PGN), and a
// BAM transfer whose announcement names the body's PGN, repeated so transfers straddle chunk
// boundaries at every offset. Streamed, the subtraction by PGN and by announcement decides
// what it decides from memory.
fn test_a_streamed_j1939_bus_is_subtracted_as_the_loaded_one() {
	path := os.join_path(os.temp_dir(), 'replay_j1939_${os.getpid()}.mf4')
	mut pats := []Pat{}
	for line in os.read_lines(sample('j1939-bam.log')) or { panic(err) } {
		e := canlog.parse_line(line) or { continue }
		pats << Pat{
			id:   e.frame.id
			ext:  true
			data: e.frame.data
		}
	}
	assert pats.len == 8
	write_mf4(path, 8 * 2001, pats, 1, 0.01)
	defer {
		os.rm(path) or {}
	}
	db := candb.load_dbc_file(os.join_path(src_repo, 'dbc', 'j1939_demo.dbc')) or { panic(err) }
	mem := open_recording_at(path, 1 << 20) or { panic(err) }
	str := open_recording_at(path, 0) or { panic(err) }
	assert str.streamed && str.buses == mem.buses
	mut gone := 0
	mut pgn := 0
	mut tp := 0
	for exclude in [['Engine'], ['Body']] {
		specs := [
			player.BusSpec{
				src:     mem.buses[0].iface
				dst:     'live'
				db:      db
				exclude: exclude
			},
		]
		mut a := mem.prepare(specs) or { panic(err) }
		mut b := str.prepare(specs) or { panic(err) }
		assert b.buses == a.buses, '${exclude}'
		r := a.buses[0].report
		assert r.kept > 0
		gone += r.withheld_excluded
		pgn += r.pgn_matched
		tp += r.tp_attributed
		mut pa := a.player(1.0, false)
		mut pb := b.player(1.0, false)
		want := drive(mut pa)
		got := drive(mut pb)
		b.close()
		assert got == want, '${exclude}'
	}
	assert gone > 0 && pgn > 0 && tp > 0
}
