module script

import rand
import time
import blobly.nm
import blobly.transport

// NmEv is one read of a model wait: a frame at `t`, or a read that found nothing at `t`.
struct NmEv {
	t     f64
	frame bool
	id    u32
	data  []u8
}

@[heap]
struct NmModel {
mut:
	evs      []NmEv
	i        int
	t        f64
	lis      &nm.Listener = unsafe { nil }
	ref      &nm.Listener = unsafe { nil } // fed the same events, outside the wait
	produced []string
	offered  []string
}

// nm_key is everything a predicate can see of a reading.
fn nm_key(v nm.View) string {
	mut s := '${v.state}|${v.keepers}|${v.woke}|${v.woke_active}|${v.repeaters}|${v.heard}|${v.frames}|${v.malformed}|${v.dropped}'
	for r in v.rows {
		s += '|${r.name}/${r.missing}/${r.unknown}/${r.stale}/${r.cbv}/${r.count}/${r.has_pn}/${r.pn}'
	}
	return s
}

fn nm_events(n int) []NmEv {
	ids := [u32(0x511), 0x513, 0x515, 0x522, 0x100]
	cbvs := [u8(0), nm.cbv_ready_to_sleep, nm.cbv_active_wakeup, nm.cbv_repeat_request, nm.cbv_pn_info]
	mut out := []NmEv{}
	mut t := 1000.0
	for _ in 0 .. n {
		t += rand.f64() * 6 // gaps around the timeouts drawn
		if rand.intn(4) or { 0 } == 0 {
			out << NmEv{
				t: t
			}
			continue
		}
		id := ids[rand.intn(ids.len) or { 0 }]
		mut data := [u8(id & 0xFF), cbvs[rand.intn(cbvs.len) or { 0 }], u8(rand.intn(8) or { 0 })]
		if rand.intn(10) or { 0 } == 0 {
			data = [u8(id & 0xFF)] // malformed
		}
		out << NmEv{
			t:     t
			frame: true
			id:    id
			data:  data
		}
	}
	return out
}

// Every reading a wait's listener makes — after each frame, and after each read that found
// nothing — is offered to the wait's predicate, whatever the timeout and however close the
// events: read_loop and nm_asks (what nm_read asks with) over synthetic events, the listener's
// readings against a reference listener fed the same events.
fn test_an_nm_wait_offers_every_reading_its_listener_makes() {
	for seed in 0 .. 400 {
		rand.seed([u32(seed), 0x4E4D])
		timeout := rand.int_in_range(1, 8) or { 1 }
		cfg := nm.explicit(0x500, 0x53F, false, timeout) or { panic(err) }
		mut m := &NmModel{
			evs: nm_events(rand.int_in_range(1, 80) or { 1 })
			lis: nm.new_listener(cfg)
			ref: nm.new_listener(cfg)
		}
		ops := ReadOps{
			recv:    fn [m] (ms int) !transport.CanFrame {
				mut x := unsafe { m }
				ev := x.evs[x.i]
				x.i++
				x.t = ev.t
				if ev.frame {
					x.ref.feed(ev.id, false, false, ev.data, ev.t)
				} else {
					x.ref.idle(ev.t)
				}
				x.produced << nm_key(x.ref.reading())
				if !ev.frame {
					return error('timeout')
				}
				return transport.CanFrame{
					id:   ev.id
					data: ev.data
				}
			}
			frame:   fn [m] (f transport.CanFrame) {
				mut x := unsafe { m }
				x.lis.feed(f.id, f.extended, f.rtr, f.data, x.t)
			}
			idle:    fn [m] () {
				mut x := unsafe { m }
				x.lis.idle(x.t)
			}
			expired: fn () bool {
				return false
			}
		}
		held := read_loop(ops, time.sys_mono_now() + u64(10 * time.second), true, 100, nm_asks(m.lis,
			fn [m] (v nm.View) bool {
			mut x := unsafe { m }
			x.offered << nm_key(v)
			return x.i >= x.evs.len // every event read: the wait is met
		})) or { panic(err) }
		assert held
		assert m.offered == m.produced, 'seed ${seed}, timeout ${timeout} ms: ${m.produced.len} readings made, ${m.offered.len} offered'
	}
}
