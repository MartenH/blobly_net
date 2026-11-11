module candb

const send_dbc = 'VERSION ""
BU_: Body Gw
BO_ 256 Door: 8 Body
 SG_ Door_Status : 0|2@1+ (1,0) [0|3] "" Gw
 SG_ Temp : 8|8@1- (0.5,-40) [-40|87.5] "C" Gw
 SG_ Plain : 16|8@1+ (1,0) [0|255] "" Gw
BO_ 257 Event: 4 Body
 SG_ Level : 0|8@1+ (1,0) [0|255] "" Gw
BO_ 258 Quiet: 2 Body
 SG_ Mode : 0|4@1+ (1,0) [0|15] "" Gw
BO_ 2147484160 Ext: 8 Gw
 SG_ Wide : 0|16@1+ (1,0) [0|65535] "" Body
BA_DEF_ BO_ "GenMsgCycleTime" INT 0 65535;
BA_DEF_ BO_ "GenMsgSendType" ENUM "Spontaneous","Cyclic","NoMsgSendType","CyclicAndSpontaneous";
BA_DEF_ SG_ "GenSigStartValue" INT -1000 100000;
BA_DEF_DEF_ "GenMsgCycleTime" 200;
BA_DEF_DEF_ "GenMsgSendType" "Cyclic";
BA_DEF_DEF_ "GenMsgNrOfRepetition" 0;
BA_DEF_DEF_ "GenSigStartValue" 0;
BA_ "GenMsgCycleTime" BO_ 256 100;
BA_ "GenMsgCycleTime" BO_ 257 0;
BA_ "GenMsgSendType" BO_ 257 0;
BA_ "GenMsgSendType" BO_ 258 2;
BA_ "GenMsgSendType" BO_ 256 "CyclicAndSpontaneous";
BA_ "GenMsgCycleTimeFast" BO_ 256 20;
BA_ "GenMsgNrOfRepetition" BO_ 257 3;
BA_ "GenMsgDelayTime" BO_ 257 15;
BA_ "GenMsgStartDelayTime" BO_ 256 50;
BA_ "GenSigStartValue" SG_ 256 Door_Status 3;
BA_ "GenSigStartValue" SG_ 256 Temp -2;
BA_ "GenSigStartValue" SG_ 257 Level 7.0;
'

fn test_send_attributes_read_against_the_files_own_enum() {
	db := parse_dbc(send_dbc)!
	door := db.message_named('Door')?
	assert door.cycle_ms == 100
	assert door.send_type_name == 'CyclicAndSpontaneous'
	assert door.send_type == .mixed
	assert door.cycle_fast_ms == 20
	assert door.start_delay_ms == 50
	assert door.cyclic_period() == 100
	ev := db.message_named('Event')?
	// index 0 of THIS file's enum is Spontaneous, which in Vector's ordering would read cyclic
	assert ev.send_type_name == 'Spontaneous'
	assert ev.send_type == .event
	assert ev.repetitions == 3
	assert ev.delay_ms == 15
	assert ev.cyclic_period() == 0
	assert ev.on_change()
	quiet := db.message_named('Quiet')?
	assert quiet.send_type == .not_sent
	// the BA_DEF_DEF_ cycle fills a message that states none, and is not sent when it is NoMsgSendType
	assert quiet.cycle_ms == 200
	assert quiet.cyclic_period() == 0
	ext := db.message_named('Ext')?
	assert ext.cycle_ms == 200
	assert ext.send_type_name == 'Cyclic' // the default
	assert ext.cyclic_period() == 200
	assert db.read_notes == []
}

fn test_start_values_per_signal() {
	db := parse_dbc(send_dbc)!
	door := db.message_named('Door')?
	st := door.signal_named('Door_Status')?
	assert st.has_start && st.start_raw == 3
	assert st.start()? == 3.0
	temp := door.signal_named('Temp')?
	assert temp.has_start && temp.start_raw == 0xFE // -2 in 8 bits
	assert temp.start()? == -41.0
	plain := door.signal_named('Plain')?
	assert plain.has_start && plain.start_raw == 0 // the file-wide default of 0
	assert plain.start()? == 0.0
	lvl := db.message_named('Event')?.signal_named('Level')?
	assert lvl.start_raw == 7
	assert door.initial(none) == [u8(3), 0xFE, 0, 0, 0, 0, 0, 0]
	// encode starts at raw 0 still
	assert door.template() == []u8{len: 8}
}

fn test_start_default_fills_signals_that_state_none() {
	db := parse_dbc('BO_ 1 M: 2 N
 SG_ A : 0|4@1+ (1,0) [0|0] "" X
 SG_ B : 4|2@1+ (1,0) [0|0] "" X
 SG_ C : 8|8@1+ (1,0) [0|0] "" X
BA_DEF_DEF_ "GenSigStartValue" 5;
BA_ "GenSigStartValue" SG_ 1 C 9;
')!
	m := db.messages[0]
	assert m.signal_named('A')?.start_raw == 5
	assert !m.signal_named('B')?.has_start // 5 does not fit 2 bits
	assert m.signal_named('C')?.start_raw == 9
	assert db.read_notes.len == 1 && db.read_notes[0].contains('does not fit 1 signal')
}

fn test_values_that_are_not_ones_are_said() {
	db := parse_dbc('BO_ 1 M: 2 N
 SG_ A : 0|4@1+ (1,0) [0|0] "" X
 SG_ B : 4|4@1+ (1,0) [0|0] "" X
BA_ "GenSigStartValue" SG_ 1 A 16;
BA_ "GenSigStartValue" SG_ 1 B -1;
BA_ "GenMsgDelayTime" BO_ 1 abc;
BA_ "GenMsgSendType" BO_ 1 4;
')!
	m := db.messages[0]
	assert !m.signal_named('A')?.has_start
	assert !m.signal_named('B')?.has_start // negative, unsigned
	assert m.delay_ms == 0
	assert m.send_type == .unstated
	assert db.read_notes.len == 4
	assert db.read_notes.any(it.contains('M.A: GenSigStartValue 16 is not a raw value its 4 bits hold'))
	assert db.read_notes.any(it.contains('GenMsgSendType 4 is an index and the file declares no ENUM'))
}

fn test_send_attributes_and_start_values_survive_a_save() {
	db := parse_dbc(send_dbc)!
	text := db.to_dbc()
	again := parse_dbc(text)!
	assert again.to_dbc() == text
	for m in db.messages {
		r := again.message_index(m.id, m.ext)?
		n := again.messages[r]
		assert n.cycle_ms == m.cycle_ms
		assert n.send_type_name == m.send_type_name
		assert n.cycle_fast_ms == m.cycle_fast_ms
		assert n.repetitions == m.repetitions
		assert n.delay_ms == m.delay_ms
		assert n.start_delay_ms == m.start_delay_ms
		for s in m.signals {
			t := n.signal_named(s.name)?
			assert t.has_start == s.has_start && t.start_raw == s.start_raw
		}
	}
	assert text.contains('BA_ "GenSigStartValue" SG_ 256 Temp -2;')
}

fn test_an_unstated_send_type_saves_as_the_cyclic_default() {
	mut db := parse_dbc(send_dbc)!
	db.messages << Message{
		name:     'Added'
		id:       0x300
		dlc:      1
		cycle_ms: 10
	}
	again := parse_dbc(db.to_dbc())!
	added := again.message_named('Added')?
	assert added.send_type == .cyclic
	assert added.cyclic_period() == 10
}

fn test_send_type_of_reads_the_common_spellings() {
	assert send_type_of('cyclic') == .cyclic
	assert send_type_of('cyclicIfActive') == .cyclic
	assert send_type_of('IfActive') == .cyclic
	assert send_type_of('spontaneous') == .event
	assert send_type_of('spontaneousWithRepetition') == .event
	assert send_type_of('OnChange') == .event
	assert send_type_of('cyclicAndSpontaneousWithDelay') == .mixed
	assert send_type_of('Mixed') == .mixed
	assert send_type_of('POE') == .mixed
	assert send_type_of('Periodic') == .cyclic
	assert send_type_of('NoMsgSendType') == .not_sent
	assert send_type_of('NotUsed') == .other
	assert send_type_of('') == .unstated
}

fn test_records_laid_out_as_candb_plus_plus_writes_them() {
	db := parse_dbc('BU_: Body
BO_ 256 Door: 1 Body
 SG_ S : 0|8@1+ (1,0) [0|255] "" X
BO_ 257 Event: 1 Body
 SG_ E : 0|8@1+ (1,0) [0|255] "" X
BA_DEF_ BO_  "GenMsgSendType" ENUM  "Periodic","Event","Mixed","IfActive","POE","PA";
BA_DEF_ BO_  "GenMsgCycleTime" INT 0 65535;
BA_DEF_DEF_  "GenMsgSendType" "Periodic";
BA_DEF_DEF_  "GenMsgCycleTime" 10;
BA_DEF_DEF_  "GenSigStartValue" 2;
BA_ "GenMsgSendType" BO_ 257 2;
')!
	assert db.read_notes == []
	door := db.message_named('Door')?
	assert door.cycle_ms == 10
	assert door.send_type == .cyclic
	assert door.signal_named('S')?.start_raw == 2
	ev := db.message_named('Event')?
	assert ev.send_type_name == 'Mixed'
	assert ev.send_type == .mixed
	assert ev.cyclic_period() == 10
	// a quoted string keeps its own blanks
	assert attr_record('BA_  "X"  BO_ 1  "a  b";') == 'BA_ "X" BO_ 1 "a  b";'
}

fn test_a_start_default_of_zero_is_stated_and_saved_without_records() {
	db := parse_dbc('BO_ 1 M: 2 N
 SG_ A : 0|8@1+ (1,-40) [0|0] "" X
 SG_ B : 8|8@1+ (1,0) [0|0] "" X
BA_DEF_DEF_ "GenSigStartValue" 0;
BA_ "GenSigStartValue" SG_ 1 B 4;
')!
	a := db.messages[0].signal_named('A')?
	assert a.has_start && a.start()? == -40.0
	text := db.to_dbc()
	assert !text.contains('SG_ 1 A ')
	assert text.contains('BA_ "GenSigStartValue" SG_ 1 B 4;')
	again := parse_dbc(text)!
	assert again.messages[0].signal_named('A')?.has_start
	assert again.to_dbc() == text
}

fn test_initial_fills_the_branch_its_switch_selects() {
	db := parse_dbc('BO_ 1 M: 2 N
 SG_ Sw M : 0|4@1+ (1,0) [0|0] "" X
 SG_ A m1 : 8|8@1+ (1,0) [0|0] "" X
 SG_ B m2 : 8|8@1+ (1,0) [0|0] "" X
BA_ "GenSigStartValue" SG_ 1 Sw 2;
BA_ "GenSigStartValue" SG_ 1 A 17;
BA_ "GenSigStartValue" SG_ 1 B 34;
')!
	m := db.messages[0]
	assert m.initial(none) == [u8(2), 34]
	assert m.initial(u64(1)) == [u8(1), 17]
	assert m.initial(u64(3)) == [u8(3), 0]
}
