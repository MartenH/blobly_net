module project

// Two rows this project calls different wires and the hardware calls one (#167).
//
// alias_conflicts is deliberately separate from the resolver that feeds it, and these tests are
// why: `transport.physical_wire_key` answers none on every machine without the XL driver, so a
// check that asked it inline could not be exercised where the tests run. The map is the seam —
// what a Windows bench would report, handed in.

fn vec_row(name string, iface string, enabled bool) Channel {
	return Channel{
		name:    name
		adapter: 'vector'
		iface:   iface
		enabled: enabled
	}
}

// THE BUG ITSELF: two application channels, one transceiver, and every other check in this file
// comparing them as separate wires.
fn test_two_application_channels_on_one_physical_channel_are_refused() {
	rows := [
		vec_row('CAN1', 'vector:1', true),
		vec_row('CAN2', 'vector:2', true),
	]
	phys := {
		'vector:1': 'vector-hw:1:0:0'
		'vector:2': 'vector-hw:1:0:0'
	}
	problems := alias_conflicts(rows, phys)
	assert problems.len == 1, 'expected one conflict, got ${problems}'
	assert problems[0].contains('CAN2'), problems[0]
	assert problems[0].contains('CAN1'), problems[0]
}

// AND THE CASE THAT MUST NOT FIRE. `vector:1` and `vector:ch1` share a physical channel because
// they ARE one wire — destination_key already says so, and reporting that as a conflict would
// refuse every project that spells one channel two ways, which is a thing this app supports on
// purpose.
fn test_two_spellings_of_one_wire_are_not_a_conflict() {
	rows := [
		vec_row('CAN1', 'vector:1', true),
		vec_row('CAN1 alias', 'vector:ch1', true),
		vec_row('CAN1 again', 'vector:app01@250000', true),
	]
	phys := {
		'vector:1':            'vector-hw:1:0:0'
		'vector:ch1':          'vector-hw:1:0:0'
		'vector:app01@250000': 'vector-hw:1:0:0'
	}
	assert alias_conflicts(rows, phys) == []
}

fn test_separate_physical_channels_are_not_a_conflict() {
	rows := [
		vec_row('CAN1', 'vector:1', true),
		vec_row('CAN2', 'vector:2', true),
	]
	phys := {
		'vector:1': 'vector-hw:1:0:0'
		'vector:2': 'vector-hw:1:0:1'
	}
	assert alias_conflicts(rows, phys) == []
}

// A ROW NOBODY COULD RESOLVE IS LEFT ALONE. No driver, or an application channel with no
// hardware behind it, means the question was not answered — not that the answer was "different".
// Treating an absent entry as distinct would be a guess; treating it as shared would refuse
// projects on a machine that cannot see the bench at all.
fn test_an_unresolvable_row_is_not_compared() {
	rows := [
		vec_row('CAN1', 'vector:1', true),
		vec_row('CAN2', 'vector:2', true),
	]
	assert alias_conflicts(rows, map[string]string{}) == []
	assert alias_conflicts(rows, {
		'vector:1': 'vector-hw:1:0:0'
	}) == []
}

// DISABLED ROWS HAVE NO SAY, the rule every other check in destination_conflicts applies. A row
// that is not in the run cannot be sharing a transceiver with one that is.
fn test_a_disabled_row_is_not_a_conflict() {
	rows := [
		vec_row('CAN1', 'vector:1', true),
		vec_row('CAN2', 'vector:2', false),
	]
	phys := {
		'vector:1': 'vector-hw:1:0:0'
		'vector:2': 'vector-hw:1:0:0'
	}
	assert alias_conflicts(rows, phys) == []
}

// ONE MISTAKE, ONE LINE. Three rows aliased onto one channel is a single wrong assignment, and
// the earlier version of this said it twice — it dropped the claim after reporting, so the third
// row re-claimed the channel and a fourth would have reported it again.
fn test_a_channel_is_reported_once_however_many_rows_alias_onto_it() {
	rows := [
		vec_row('CAN1', 'vector:1', true),
		vec_row('CAN2', 'vector:2', true),
		vec_row('CAN3', 'vector:3', true),
		vec_row('CAN4', 'vector:4', true),
	]
	phys := {
		'vector:1': 'vector-hw:1:0:0'
		'vector:2': 'vector-hw:1:0:0'
		'vector:3': 'vector-hw:1:0:0'
		'vector:4': 'vector-hw:1:0:0'
	}
	problems := alias_conflicts(rows, phys)
	assert problems.len == 1, 'one wrong assignment reported ${problems.len} times: ${problems}'
}

// Two separate mistakes are two lines, though — they are two assignments to correct.
fn test_two_aliased_channels_are_two_lines() {
	rows := [
		vec_row('A1', 'vector:1', true),
		vec_row('A2', 'vector:2', true),
		vec_row('B1', 'vector:5', true),
		vec_row('B2', 'vector:6', true),
	]
	phys := {
		'vector:1': 'vector-hw:1:0:0'
		'vector:2': 'vector-hw:1:0:0'
		'vector:5': 'vector-hw:1:0:3'
		'vector:6': 'vector-hw:1:0:3'
	}
	assert alias_conflicts(rows, phys).len == 2
}

// The resolver is the only thing that decides which adapters can alias, and on this machine it
// decides nothing — so destination_conflicts as a whole must be unchanged for every project that
// names no Vector hardware, which is every project the tests and CI run.
fn test_the_ordinary_project_is_unaffected() {
	rows := [
		Channel{
			name:    'CAN1'
			adapter: 'virtual'
			iface:   'inproc:CAN1'
			enabled: true
		},
		Channel{
			name:    'CAN2'
			adapter: 'virtual'
			iface:   'inproc:CAN2'
			enabled: true
		},
	]
	assert destination_conflicts(rows) == []
}

// ---- rows the resolver could not read (#194) -------------------------------------------------
//
// The alias check compares the rows it CAN resolve and silently skips the rest, which is right for
// a row that reaches no hardware and wrong for one the driver would not describe: that one may be
// sharing a transceiver and nothing here can tell. It cannot refuse the project for it — a bench
// with the XL library mid-upgrade would have every project rejected for an unanswered question —
// so it warns, and these pin the wording rather than the resolver.
fn test_no_unreadable_rows_says_nothing() {
	assert alias_unreadable_lines([]) == [], 'silence is the answer when nothing was unreadable'
}

fn test_one_unreadable_row_is_named_and_reads_as_singular() {
	lines := alias_unreadable_lines(['CAN1 (vector:1)'])
	assert lines.len == 1, 'one line for the set, not one per row'
	assert lines[0].contains('CAN1 (vector:1)'), 'the row must be named: ${lines[0]}'
	assert lines[0].contains('reaches'), 'singular: ${lines[0]}'
	assert lines[0].contains('cover it'), 'singular: ${lines[0]}'
}

// ONE LINE FOR THE SET. The condition is a property of the driver at this moment, not of any row,
// so repeating it per row would say the same thing three times — the reasoning alias_conflicts
// already applies with `said`.
fn test_several_unreadable_rows_share_one_line() {
	lines := alias_unreadable_lines(['CAN1 (vector:1)', 'CAN2 (vector:2)', 'CAN3 (vector:3)'])
	assert lines.len == 1, 'three rows must not produce three lines'
	for want in ['CAN1 (vector:1)', 'CAN2 (vector:2)', 'CAN3 (vector:3)'] {
		assert lines[0].contains(want), '${want} missing from: ${lines[0]}'
	}
	assert lines[0].contains('reach'), 'plural: ${lines[0]}'
	assert lines[0].contains('cover them'), 'plural: ${lines[0]}'
}

// A WARNING, NEVER A REFUSAL. Whatever this says must not reach destination_conflicts, whose
// entries all stop a project — that is the distinction the split exists for.
fn test_unreadable_rows_never_refuse_a_project() {
	rows := [
		Channel{
			name:    'CAN1'
			adapter: 'vector'
			iface:   'vector:1'
			enabled: true
		},
	]
	// The property being pinned is that they are SEPARATE channels, and that the warning path
	// cannot contribute to the refusal path WHATEVER THE DRIVER SAYS — so the assertion must hold
	// for every answer the driver can give, not only for the one this machine happens to give.
	// On Linux physical_wire answers `.nothing` for everything and the warnings are empty; on a
	// Windows bench with the XL library installed it is asked for real, and `vector:1` may well
	// be unreadable there, or absent from the driver's table, which is a WARNING about this row
	// — the case the split exists for, and the case the old `== []` assertion failed on (#252).
	// A single row cannot conflict with anything, so the refusal side is empty on every
	// platform. The warning's WORDING is not re-pinned here (the pure alias_unreadable_lines
	// test does that, on every platform); a warning that does arrive must be about this row.
	assert destination_conflicts(rows) == []
	for w in alias_unreadable_warnings(rows) {
		assert w.contains('CAN1 (vector:1)'), w
	}
	$if !windows {
		// and where no driver can answer, nothing is said either
		assert alias_unreadable_warnings(rows) == []
	}
}
