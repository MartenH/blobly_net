module genhome

// Two channels on ONE wire, which is the arrangement every defect in this path needed.
// NOT `shared()`: `shared` is a V keyword, and v fmt rewrote every call to it as `()`.
fn shared_rows() []Row {
	return [
		Row{
			name: 'Powertrain'
			iface: 'inproc:CAN1'
		},
		Row{
			name: 'Chassis'
			iface: 'inproc:CAN1'
		},
		Row{
			name: 'Body'
			iface: 'inproc:CAN2'
		},
	]
}

fn gen(own string, idx int, iface string) Gen {
	return Gen{
		own: own
		own_idx: idx
		iface: iface
	}
}

fn test_each_generator_goes_to_exactly_one_row() {
	rows := shared_rows()
	gens := [
		gen('Powertrain', 0, 'inproc:CAN1'),
		gen('Chassis', 1, 'inproc:CAN1'),
		gen('Body', 2, 'inproc:CAN2'),
	]
	assert homes(gens, rows) == [0, 1, 2]
}

// FINDING 1: grouping by INTERFACE asked each row for the generators whose iface matched, and two
// rows sharing a wire both matched every one — so a Save wrote each generator into BOTH lists and
// the next load came back with two of each.
fn test_a_shared_wire_does_not_duplicate_a_generator() {
	rows := shared_rows()
	gens := [gen('Chassis', 1, 'inproc:CAN1')]
	h := homes(gens, rows)
	assert h == [1], 'the row it is nested under, not every row on the wire'
	mut claimed := 0
	for ri in 0 .. rows.len {
		for x in h {
			if x == ri {
				claimed++
			}
		}
	}
	assert claimed == 1, 'one generator, one home'
}

// FINDING 2: matching by NAME has the same defect one step removed — nothing enforces unique
// channel names, so two indistinguishable rows meant the first absorbed the second's generators
// and the second lost them on reload. Only the index separates them.
fn test_two_indistinguishable_rows_keep_their_own_generators() {
	rows := [
		Row{
			name: 'CAN'
			iface: 'inproc:X'
		},
		Row{
			name: 'CAN'
			iface: 'inproc:X'
		},
	]
	gens := [
		gen('CAN', 0, 'inproc:X'),
		gen('CAN', 1, 'inproc:X'),
	]
	assert homes(gens, rows) == [0, 1]
}

// FINDING 3: a generator matching no row was re-homed onto row 0, so deleting an `inproc:` row
// could start its cyclic generator transmitting on whatever real bus happened to be listed first,
// with nothing on screen saying it moved. It is dropped, which is what deleting a bus has always
// done to its generators.
fn test_a_generator_with_no_row_is_dropped_not_rehomed() {
	rows := [
		Row{
			name: 'RealHardware'
			iface: 'pcan:PCAN_USBBUS1'
		},
	]
	gens := [gen('Deleted', 0, 'inproc:GONE')]
	assert homes(gens, rows) == [dropped]
}

// A stale index must not hand a generator to an unrelated row: the name and interface are asked
// too, and the second pass finds the row that really is its home.
fn test_a_stale_index_falls_back_to_the_row_that_matches() {
	rows := shared_rows()
	gens := [gen('Body', 0, 'inproc:CAN2')] // index says row 0, everything else says row 2
	assert homes(gens, rows) == [2]
}

fn test_a_stale_index_never_claims_an_unrelated_row() {
	rows := shared_rows()
	gens := [gen('Nobody', 0, 'inproc:NOPE')]
	assert homes(gens, rows) == [dropped], 'row 0 is not its home merely because the index says so'
}

// FINDING 5 (P1, and caused by the fix for finding 2): an address edit rebound EVERY generator on
// the old wire, so retargeting one alias left the sibling's generators carrying an interface their
// own row does not have — and the consistency check then DELETED them on the next Save.
fn test_retargeting_one_alias_does_not_touch_the_other() {
	// Row 0 is being moved from inproc:CAN1 to inproc:CAN9; row 1 stays.
	g_moved := gen('Powertrain', 0, 'inproc:CAN1')
	g_stays := gen('Chassis', 1, 'inproc:CAN1')
	assert moves_with_row(g_moved, 0)
	assert !moves_with_row(g_stays, 0), 'a sibling on the same wire is not part of this edit'
	// …and after the edit both still find their homes.
	rows := [
		Row{
			name: 'Powertrain'
			iface: 'inproc:CAN9'
		},
		Row{
			name: 'Chassis'
			iface: 'inproc:CAN1'
		},
	]
	after := [gen('Powertrain', 0, 'inproc:CAN9'), g_stays]
	assert homes(after, rows) == [0, 1], 'the sibling was deleted from the project before this'
}

// Deleting a row takes its generators and restacks the ones behind it, so the index stays the
// identity it looks like.
fn test_removing_a_row_takes_its_generators_and_restacks_the_rest() {
	gens := [
		gen('A', 0, 'inproc:A'),
		gen('B', 1, 'inproc:B'),
		gen('C', 2, 'inproc:C'),
	]
	assert restack(gens, 1) == [0, dropped, 1]
	assert restack(gens, 0) == [dropped, 0, 1]
	assert restack(gens, 2) == [0, 1, dropped]
}
