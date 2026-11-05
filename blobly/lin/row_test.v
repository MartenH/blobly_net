module lin

import sync.stdatomic
import blobly.lindb
import blobly.transport

const demo_ldf = @VMODROOT + '/dbc/lin_demo.ldf'

// RowClock is synthetic time: a sleep moves it, so a schedule runs as fast as the bus takes it.
struct RowClock {
mut:
	ns i64
}

fn (c &RowClock) now_ns() i64 {
	return stdatomic.load_i64(&c.ns)
}

fn (c &RowClock) sleep_ns(ns i64) {
	stdatomic.add_i64(&c.ns, int(ns))
}

fn demo() lindb.Ldf {
	return lindb.load_ldf(demo_ldf) or { panic(err) }
}

fn test_a_schedule_keeps_the_delay_of_what_it_does_not_send() {
	l := demo()
	n := schedule_of(&l, 'NormalTable')!
	// the event-triggered slot's 10 ms join the slot before it
	assert n.slots.map(it.id) == [u8(0x01), 0x02, 0x12, 0x22]
	assert n.slots.map(it.delay_ms) == [10.0, 10, 10, 25]
	assert n.notes.len == 1 && n.notes[0].contains('Node_Status_Event')
	f := schedule_of(&l, 'FastTable')!
	assert f.slots.map(it.id) == [u8(0x02), 0x21, 0x11, 0x13, 0x23]
	assert f.slots.map(it.delay_ms) == [5.0, 5, 5, 10, 65]
	assert f.notes.len == 3
	// a table with no unconditional frame sends nothing, so it is refused
	schedule_of(&l, 'ConfigTable') or {
		assert err.msg().contains('no unconditional frame')
		schedule_of(&l, 'Nope') or {
			assert err.msg().contains('NormalTable')
			return
		}
	}
	assert false
}

fn test_expectations_and_entries_come_from_the_ldf() {
	l := demo()
	exp := expects_of(&l)
	assert exp[0x22] == Expect{
		len:   4
		model: .enhanced
	}
	// RSM says LIN 2.1, LSM 2.2: both enhanced; the diagnostic frames classic
	assert exp[0x3C].model == .classic && exp[0x3D].model == .classic
	es := publish_entries(&l, 'LSM')!
	assert es.map(it.id) == [u8(0x11), 0x12, 0x13]
	lsm3 := l.frame('LSM_Frm3') or { panic('no LSM_Frm3') }
	assert es[2].data == l.template(lsm3) && es[2].dir == .publish && es[2].len == 4
}

fn test_a_simulated_cluster_runs_its_schedule() {
	clk := &RowClock{}
	mut r := start_row(RowSpec{
		name:     'BODY'
		address:  'inproc:row-cluster'
		ldf:      demo_ldf
		role:     .master
		simulate: ['CEM', 'LSM', 'RSM']
		schedule: 'NormalTable'
	}, RowOpts{
		clock:   clk
		sleeper: clk
	})!
	defer {
		r.stop()
	}
	mut t := r.tap()!
	l := demo()
	mut seen := map[u8]int{}
	for _ in 0 .. 40 {
		f := t.recv(2000)!
		assert f.errs == Errs.zero(), reading(f)
		assert origin_of(f) == 'TX-S'
		lf := l.frame_by_id(f.id) or { panic('id 0x${f.id:02X} is not in the LDF') }
		assert f.data == l.template(lf)
		seen[f.id]++
	}
	assert seen.keys().len == 4
	v := r.view()
	assert v.schedule == 'NormalTable' && v.frames.len == 4
	assert v.frames[0].name == 'CEM_Frm1' && v.frames[0].count >= 10
	// one cycle of the table, 10 + 10 + 10 + 25 ms, on the synthetic clock
	assert v.frames[1].cadence_ms == 55.0
	assert v.notes.any(it.contains('Node_Status_Event'))
}

fn test_a_value_set_on_a_simulated_slave_is_what_it_answers() {
	mut r := start_row(RowSpec{
		name:     'BODY'
		address:  'inproc:row-values'
		ldf:      demo_ldf
		role:     .slave
		simulate: ['LSM', 'RSM']
	}, RowOpts{})!
	defer {
		r.stop()
	}
	// the SUT is the master here
	mut m := open('inproc:row-values', Config{
		role: .master
	})!
	defer {
		m.close()
	}
	r.set_signal('LeftIntLightsSwitch', u64(0x5A))!
	m.header(0x11)!
	for {
		f := m.recv(2000)!
		if f.id == 0x11 {
			assert f.errs == Errs.zero()
			assert f.data[1] == 0x5A && f.src == .sim
			break
		}
	}
	r.set_signal('CabinTemp', u64(1)) or {
		assert err.msg().contains('does not simulate CEM')
		r.set_signal('NoSuchSignal', u64(1)) or {
			assert err.msg().contains('no signal `NoSuchSignal`')
			return
		}
	}
	assert false
}

fn test_a_spec_is_refused_before_anything_opens() {
	bad := [
		RowSpec{
			name:     'm'
			address:  'inproc:row-refused'
			ldf:      demo_ldf
			role:     .monitor
			simulate: ['LSM']
		},
		RowSpec{
			name:     's'
			address:  'inproc:row-refused'
			ldf:      demo_ldf
			role:     .slave
			schedule: 'NormalTable'
		},
		RowSpec{
			name:     'n'
			address:  'inproc:row-refused'
			ldf:      demo_ldf
			role:     .master
			simulate: ['XSM']
		},
		RowSpec{
			name:     'c'
			address:  'inproc:row-refused'
			ldf:      demo_ldf
			role:     .slave
			simulate: ['CEM']
		},
		RowSpec{
			name:     't'
			address:  'inproc:row-refused'
			ldf:      demo_ldf
			role:     .master
			schedule: 'Nope'
		},
		RowSpec{
			name:     'x'
			address:  'inproc:row-refused'
			role:     .master
			simulate: ['LSM']
		},
		RowSpec{
			name:     'd'
			address:  'inproc:row-refused'
			ldf:      demo_ldf
			role:     .slave
			simulate: ['LSM', 'LSM']
		},
	]
	wants := ['publishes nothing', 'only the master', 'no node `XSM`', 'LDF master',
		'no schedule table `Nope`', 'need an LDF', 'listed twice']
	for i, s in bad {
		start_row(s, RowOpts{}) or {
			assert err.msg().contains(wants[i]), err.msg()
			continue
		}
		assert false, s.name
	}
	// nothing was left holding the bus: a master opens on it
	mut m := open('inproc:row-refused', Config{
		role: .master
	})!
	m.close()
}

fn test_a_stopped_row_ends_its_taps_and_frees_the_bus() {
	clk := &RowClock{}
	mut r := start_row(RowSpec{
		name:     'BODY'
		address:  'inproc:row-stop'
		ldf:      demo_ldf
		role:     .master
		simulate: ['CEM']
		schedule: 'NormalTable'
	}, RowOpts{
		clock:   clk
		sleeper: clk
	})!
	mut t := r.tap()!
	t.recv(2000)!
	assert r.stop()
	for {
		t.recv(100) or {
			assert err is transport.CarrierGone
			break
		}
	}
	r.tap() or {
		assert err is transport.CarrierGone
		mut m := open('inproc:row-stop', Config{
			role: .master
		})!
		m.close()
		return
	}
	assert false
}

fn test_the_load_of_a_quiet_bus_falls_to_zero() {
	clk := &RowClock{}
	mut r := start_row(RowSpec{
		name:     'BODY'
		address:  'inproc:row-load'
		ldf:      demo_ldf
		role:     .master
		simulate: ['CEM', 'LSM', 'RSM']
		schedule: 'NormalTable'
	}, RowOpts{
		clock:   clk
		sleeper: clk
	})!
	defer {
		r.stop()
	}
	mut t := r.tap()!
	for {
		f := t.recv(2000)!
		if f.t_ns > 2_100_000_000 {
			break
		}
	}
	assert r.view().load_percent > 20
	assert r.stop_schedule()
	clk.sleep_ns(3_000_000_000)
	assert r.view().load_percent == 0
}

fn test_two_schedule_calls_at_once_leave_one_scheduler() {
	for _ in 0 .. 10 {
		clk := &RowClock{}
		mut r := start_row(RowSpec{
			name:     'BODY'
			address:  'inproc:row-race'
			ldf:      demo_ldf
			role:     .master
			simulate: ['CEM', 'LSM', 'RSM']
		}, RowOpts{
			clock:   clk
			sleeper: clk
		})!
		a := spawn fn (mut r Row) {
			r.schedule('NormalTable') or { panic(err) }
		}(mut r)
		b := spawn fn (mut r Row) {
			r.schedule('FastTable') or { panic(err) }
		}(mut r)
		a.wait()
		b.wait()
		mut t := r.tap()!
		assert r.stop_schedule()
		stopped_ns := clk.now_ns()
		// frames still queued were sent before the stop; an orphaned scheduler sends after it
		for {
			f := t.recv(50) or {
				assert err is Timeout
				break
			}
			assert f.t_ns <= stopped_ns, 'a header after the schedule stopped'
		}
		r.stop()
	}
}

fn test_a_stopped_row_refuses_a_schedule() {
	mut r := start_row(RowSpec{
		name:    'BODY'
		address: 'inproc:row-sched-stop'
		ldf:     demo_ldf
		role:    .master
	}, RowOpts{})!
	r.stop()
	r.schedule('NormalTable') or {
		assert err is transport.CarrierGone
		assert r.view().schedule == ''
		return
	}
	assert false
}

fn test_frames_a_tap_lost_stay_counted_after_it_goes() {
	clk := &RowClock{}
	mut r := start_row(RowSpec{
		name:     'BODY'
		address:  'inproc:row-drop'
		ldf:      demo_ldf
		role:     .master
		simulate: ['CEM', 'LSM', 'RSM']
		schedule: 'FastTable'
	}, RowOpts{
		clock:   clk
		sleeper: clk
		tap_cap: 1
	})!
	defer {
		r.stop()
	}
	t := r.tap()!
	for r.view().dropped < 5 {
	}
	r.untap(t)
	assert r.view().dropped >= 5
}

fn test_a_go_to_sleep_is_counted() {
	mut r := start_row(RowSpec{
		name:    'BODY'
		address: 'inproc:row-sleep'
		ldf:     demo_ldf
		role:    .master
	}, RowOpts{})!
	defer {
		r.stop()
	}
	mut t := r.tap()!
	r.sleep()!
	f := t.recv(2000)!
	assert f.event == .sleep
	v := r.view()
	assert v.frames.len == 1 && v.frames[0].id == master_req && v.frames[0].count == 1
	assert v.frames[0].name == 'MasterReq'
}

fn test_an_event_triggered_response_is_named_by_its_carried_frame() {
	l := demo()
	// LSM_Frm1 (0x11) carries its own protected id, 0x11, in byte 0
	r := l.response_for(0x3A, [u8(0x11), 0x07]) or { panic('no response') }
	assert r.name == 'Node_Status_Event LSM_Frm1'
	lf := r.frame or { panic('no frame') }
	assert lf.id == 0x11
	empty := l.response_for(0x3A, []) or { panic('no response') }
	assert empty.name == 'Node_Status_Event' && empty.frame == none
	assert l.response_for(0x30, [u8(1)]) == none
}
