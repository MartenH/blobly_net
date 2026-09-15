module transport

import time

// final_health is for a receiver that has stopped forwarding frames and is
// about to close. Vector must consume its terminal chip-state reply; a normal
// health poll deliberately leaves that reply for the next receive.
pub fn final_health(mut bus Bus) !BusHealth {
	if mut bus is SilentBus {
		return final_health(mut bus.inner)
	}
	$if windows {
		if mut bus is VectorBus {
			return bus.final_health()
		}
	}
	return bus.health()
}

// Drain through the ordinary decoder, so final controller-error records still
// contribute to diagnostics. The budget covers the whole drain, including a
// wire carrying continuous traffic; only the terminal reader calls this.
fn drain_health_reply(mut bus Bus, budget_ms int) ! {
	deadline := time.ticks() + budget_ms
	for {
		remaining := deadline - time.ticks()
		if remaining <= 0 {
			return
		}
		bus.recv(int(remaining)) or {
			if err.msg().contains('timeout') {
				return
			}
			return err
		}
	}
}
