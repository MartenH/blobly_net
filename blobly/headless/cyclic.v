module headless

import blobly.cyclic

// start_cyclic starts a background sender (cyclic.Sender) to `to` on the run's wire there, which
// sends it beside the generators and other senders on that wire and ends with the run's stop;
// returned once the wire's handle is open. Refused once the run is stopping, or when the wire
// cannot be opened.
pub fn (mut r Run) start_cyclic(to cyclic.Target, spec cyclic.Spec) !&cyclic.Sender {
	mut s := cyclic.new_sender(spec, to.iface, to.row)!
	r.mu.lock()
	if r.stopping {
		r.mu.unlock()
		return error('the run is stopped: nothing is sent')
	}
	mut w := r.wire_for(to.iface)
	s.join(mut w) or {
		r.mu.unlock()
		return err
	}
	r.mu.unlock()
	w.wait_opened() or {
		s.ask_stop()
		return if r.is_stopping() { error('the run is stopped: nothing is sent') } else { err }
	}
	return s
}
