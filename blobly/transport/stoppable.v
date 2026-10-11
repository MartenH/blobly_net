module transport

import time

// open_stopped_note is the error a stoppable open ends with when its stop was requested.
pub const open_stopped_note = 'open abandoned: stop requested'

// open_stop_poll_ms is how often a stoppable open asks its stop: the bound on how long it
// outlives one.
pub const open_stop_poll_ms = 20

// Opened is an open's outcome, carried back from the thread that made it.
struct Opened {
	bus ?Bus
	err string
}

// open_stoppable runs `opener` and returns its bus. Unstoppable (`stop` nil), it is the open
// itself. Stoppable, the open runs on its own thread — an open can block for seconds with no
// slice to ask a stop in (a CANsub open, or a wire's second opener waiting on the first, #211) —
// and the wait for it asks `stop` every `open_stop_poll_ms`; an open left behind CLOSES its bus
// when it lands, so a late success is not a leaked handle on a wire.
pub fn open_stoppable(opener fn () !Bus, stop fn () bool) !Bus {
	if stop == unsafe { nil } {
		return opener()
	}
	done := chan Opened{cap: 1}
	spawn fn [opener, done] () {
		b := opener() or {
			done <- Opened{
				err: err.str()
			}
			return
		}
		done <- Opened{
			bus: b
		}
	}()
	for {
		if stop() {
			spawn fn [done] () {
				o := <-done
				if b := o.bus {
					mut late := b
					late.close()
				}
			}()
			return error(open_stopped_note)
		}
		select {
			o := <-done {
				if b := o.bus {
					return b
				}
				return error(o.err)
			}
			open_stop_poll_ms * time.millisecond {}
		}
	}
	return error(open_stopped_note)
}
