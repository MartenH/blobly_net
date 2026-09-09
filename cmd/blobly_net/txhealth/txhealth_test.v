module txhealth

fn test_a_wire_with_a_reader_is_not_watched() {
	assert watched(['inproc:CAN1'], ['inproc:CAN1']) == []
}

// The case #142 is about: a generator's target with no row, so no reader, so nobody asking.
fn test_a_transmit_only_wire_is_watched() {
	assert watched(['pcan:PCAN_USBBUS1'], ['inproc:CAN1']) == ['pcan:PCAN_USBBUS1']
}

// A wire carries a NAMED tap per channel and a shared anonymous one, so the same bus arrives
// here several times. Narrated per tap, one transition would be reported two or three times.
fn test_a_wire_is_watched_once_however_many_taps_it_has() {
	assert watched(['vcan0', 'vcan0', 'vcan0'], []) == ['vcan0']
}

fn test_order_is_first_seen_so_narration_does_not_shuffle() {
	assert watched(['b', 'a', 'c', 'a'], []) == ['b', 'a', 'c']
}

fn test_nothing_to_watch_when_every_wire_is_read() {
	assert watched(['a', 'b'], ['b', 'a']) == []
}

fn test_empty_keys_are_not_wires() {
	assert watched(['', 'a', ''], ['']) == ['a']
}

fn test_no_taps_is_no_work() {
	assert watched([], ['a']) == []
}
