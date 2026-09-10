module player

import canlog
import transport
import candb

fn sel_entry(iface string, id u32, t f64) canlog.LogEntry {
	return canlog.LogEntry{
		t_s:   t
		iface: iface
		frame: transport.CanFrame{
			id: id
		}
	}
}

// The production callers build a player over a SELECTION of the arena, never the identity: a
// plan or a bus filter chooses rows and hands their indices over. Every accessor the player
// has must go through sel, or the GUI and the CLI replay rows the filter removed.
fn test_a_player_over_a_selection_plays_only_and_exactly_the_selected_rows() {
	log := canlog.from_entries([sel_entry('a', 1, 0.0), sel_entry('b', 2, 0.5),
		sel_entry('a', 3, 1.0), sel_entry('b', 4, 1.5), sel_entry('a', 5, 2.0)])
	sel := sel_on_bus(&log, 'a')
	assert sel == [u32(0), 2, 4]
	mut p := new_player_log(log, sel, 1.0, false, 0.0, 2.0)
	assert p.len() == 3
	p.play(0.0)
	assert p.due(0.0).map(it.frame.id) == [u32(1)]
	assert p.next_due_ms() or { -1.0 } == 1000.0, 'the next entry is row 2, at 1 s'
	assert p.due(1000.0).map(it.frame.id) == [u32(3)]
	// seek lands on the selection's own rows
	p.seek(1.9, 1900.0)
	assert p.due(2000.0).map(it.frame.id) == [u32(5)]
	assert p.due(2500.0).len == 0
	assert p.finished()
}

fn test_subtract_and_census_over_a_sparse_selection() {
	db := candb.Database{
		nodes:    ['SUT', 'OTHER']
		messages: [
			candb.Message{
				id:     0x10
				name:   'FromSut'
				sender: 'SUT'
			},
			candb.Message{
				id:     0x20
				name:   'FromOther'
				sender: 'OTHER'
			},
		]
	}
	log := canlog.from_entries([sel_entry('a', 0x10, 0.0), sel_entry('b', 0x10, 0.1),
		sel_entry('a', 0x20, 0.2), sel_entry('a', 0x30, 0.3)])
	sel := sel_on_bus(&log, 'a')
	assert sel == [u32(0), 2, 3]
	kept, rep := subtract(&log, sel, db, ['SUT'], true)
	assert kept == [u32(2), 3], 'the SUT frame on bus a goes; bus b is not in the selection'
	assert rep.withheld_excluded == 1
	c := census_sel(&log, sel, db)
	assert c.nodes['SUT'] == 1 && c.nodes['OTHER'] == 1 && c.unknown == 1
}
