module headless

import blobly.cyclic
import blobly.transport

// start_cyclic starts a background sender (cyclic.Sender) on `bus` as one of the run's loops:
// counted, so the run's stop waits for it within its bound, and ended by that stop. Refused once
// the run is stopping, the bus closed.
pub fn (mut r Run) start_cyclic(bus transport.Bus, spec cyclic.Spec) !&cyclic.Sender {
	r.mu.lock()
	if r.stopping {
		r.mu.unlock()
		mut b := bus
		b.close()
		return error('the run is stopped: nothing is sent')
	}
	r.counted()
	r.mu.unlock()
	ctl := r.ctl
	return cyclic.start(bus, spec, cyclic.Life{
		running: fn [ctl] () bool {
			return ctl.running
		}
		ended:   fn [r] () {
			mut rr := unsafe { r }
			rr.done()
		}
	}) or {
		r.done()
		return err
	}
}
