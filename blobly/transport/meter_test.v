module transport

import time

const sec = i64(time.second)

fn std8() CanFrame {
	return CanFrame{
		id:   0x100
		data: []u8{len: 8}
	}
}

// 100 standard 8-byte frames a second at 500 kbit/s: 100 x 135 bit-times = 2.7 %.
fn test_a_known_frame_rate_reads_as_its_load() {
	mut m := new_load_meter(500000, 0, 0)
	early := m.read(sec / 2)
	assert early.percent == -1 && early.average == -1, 'no whole second yet'
	for s in 0 .. 3 {
		for i in 0 .. 100 {
			m.note(std8(), i64(s) * sec + i64(i) * sec / 100)
		}
	}
	r := m.read(3 * sec)
	assert r.frames == 300
	assert r.bits == 300 * 135.0
	assert r.nominal == 500000
	assert f64(r.percent) > 2.699 && f64(r.percent) < 2.701
	assert f64(r.average) > 2.699 && f64(r.average) < 2.701
}

// a second with nothing in it closes at 0, however it was skipped
fn test_a_quiet_second_reads_zero() {
	mut m := new_load_meter(500000, 0, 0)
	m.note(std8(), sec / 2)
	assert m.read(sec + 1).percent > 0
	assert m.read(2 * sec + 1).percent == 0, 'the second after it carried nothing'
	m.note(std8(), 2 * sec + 2)
	assert m.read(5 * sec).percent == 0, 'two seconds skipped: the last whole one was quiet'
	assert m.read(5 * sec).frames == 2
}

// a BRS frame's data phase is priced at the data rate (frame_bits)
fn test_the_data_rate_prices_a_brs_frame() {
	f := CanFrame{
		id:   0x100
		fd:   true
		brs:  true
		data: []u8{len: 64}
	}
	mut m := new_load_meter(500000, 2000000, 0)
	m.note(f, 0)
	assert m.read(0).bits == frame_bits(f, 500000, 2000000)
	mut flat := new_load_meter(500000, 0, 0)
	flat.note(f, 0)
	assert flat.read(0).bits == frame_bits(f, 500000, 500000), 'no data rate: the nominal one'
}

// both directions through a metered handle, each once: its sends, and what another handle sent
fn test_a_metered_bus_counts_its_sends_and_receives_once() {
	name := 'inproc:meter_test'
	mut other := open(name)!
	mut b := metered(open(name)!, name, 500000, 0)
	defer {
		b.close()
		other.close()
	}
	b.send(std8())!
	other.send(std8())!
	b.recv(1000)!
	if _ := b.recv(0) {
		assert false, 'its own send came back'
	}
	l := b.load()
	assert l.frames == 2
	assert l.bits == 270.0
	assert b.diagnostics().is_empty()
}

// a send is priced as it goes out: an FD payload padded to a length a DLC expresses
fn test_a_send_is_priced_as_the_wire_carries_it() {
	name := 'inproc:meter_pad'
	mut b := metered(open(name)!, name, 500000, 0)
	defer {
		b.close()
	}
	f := CanFrame{
		id:   0x100
		fd:   true
		data: []u8{len: 9}
	}
	b.send(f)!
	assert b.load().bits == frame_bits(CanFrame{ ...f, data: []u8{len: 12} }, 500000, 500000)
}

// a verbatim bus keeps its caller's format through the meter
fn test_a_verbatim_bus_is_not_framed_by_the_meter() {
	name := 'inproc:meter_verbatim'
	mut raw := open(name)!
	mut b := metered(verbatim(mut raw), name, 500000, 0)
	mut other := open(name)!
	defer {
		b.close()
		other.close()
	}
	replace_wire_policy([], {
		name: Framing{
			fd: true
		}
	})
	defer {
		replace_wire_policy([], map[string]Framing{})
	}
	b.send(std8())!
	got := other.recv(1000)!
	assert !got.fd && !got.format_stated
	assert b.load().bits == 135.0
}

// on an FD wire a send is promoted and priced as FD, and a stated classic one stays classic
fn test_a_framed_wire_prices_what_it_sends() {
	name := 'inproc:meter_fd'
	mut b := metered(open(name)!, name, 500000, 0)
	mut other := open(name)!
	defer {
		b.close()
		other.close()
	}
	replace_wire_policy([], {
		name: Framing{
			fd: true
		}
	})
	defer {
		replace_wire_policy([], map[string]Framing{})
	}
	b.send(std8())!
	promoted := other.recv(1000)!
	assert promoted.fd && !promoted.format_stated
	assert b.load().bits == frame_bits(promoted, 500000, 500000)
	b.send(FrameFormat.classic.stamp(std8())!)!
	kept := other.recv(1000)!
	assert !kept.fd && !kept.format_stated
	assert b.load().bits == frame_bits(promoted, 500000, 500000) + 135.0
}

// a bus that frames nothing is priced as it was given the frame
fn test_a_raw_bus_is_priced_as_it_sends() {
	name := 'inproc:meter_raw'
	mut b := metered(open_inproc('meter_raw')!, name, 500000, 0)
	defer {
		b.close()
	}
	replace_wire_policy([], {
		name: Framing{
			fd: true
		}
	})
	defer {
		replace_wire_policy([], map[string]Framing{})
	}
	b.send(std8())!
	assert b.load().bits == 135.0
}
