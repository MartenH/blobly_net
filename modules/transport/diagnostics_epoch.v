module transport

// A shared driver's counters belong to its physical open, not to a subscriber.
// Zero means this bus has independent counters. The identity survives a logical
// handle's close and changes when the physical driver is replaced.
pub fn diagnostics_epoch(bus Bus) u64 {
	if bus is SilentBus {
		return diagnostics_epoch(bus.inner)
	}
	if bus is SharedHandle {
		return bus.entry.diagnostic_epoch
	}
	return 0
}
