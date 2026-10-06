module foldrule

fn test_can_aliases_of_one_wire_fold_together() {
	// two rows spelling one wire share its one reader, so they share its state
	assert key('inproc:CAN1', false, 0) == key('inproc:CAN1', false, 3)
}

fn test_distinct_can_wires_do_not_fold() {
	assert key('inproc:CAN1', false, 0) != key('inproc:CAN2', false, 1)
}

fn test_ethernet_rows_on_one_endpoint_do_not_fold() {
	// the #336 case: two SOME/IP rows on one endpoint, one refused by the claim — the refused
	// row must not draw the other's receive state
	a := 'someip:0.0.0.0:30491'
	assert key(a, true, 0) != key(a, true, 1)
	d := 'doip:127.0.0.1:13400'
	assert key(d, true, 2) != key(d, true, 5)
}

fn test_an_ethernet_row_keeps_its_own_key() {
	// stable across frames: the panel looks a row up under the key the fold filed it under
	assert key('someip:0.0.0.0:30491', true, 4) == key('someip:0.0.0.0:30491', true, 4)
}

fn test_an_ethernet_key_is_never_a_can_wire() {
	// a CAN row's destination keeps its interface, so no CAN row lands on an Ethernet row's key
	for row in 0 .. 4 {
		ek := key('someip:0.0.0.0:30491', true, row)
		assert ek != key('someip:0.0.0.0:30491', false, row)
		assert ek != key('inproc:${ek}', false, row)
	}
}
