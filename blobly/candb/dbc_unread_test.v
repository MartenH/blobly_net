module candb

import os

const unread_dbc = 'VERSION "1.0"

NS_ :
	NS_DESC_
	CM_
	BA_DEF_
	SIG_VALTYPE_

BS_:

BU_: Body Gw
BO_ 256 Door: 8 Body
 SG_ Speed : 0|32@1- (1,0) [0|0] "" Gw
 SG_ Mode M : 32|8@1+ (1,0) [0|0] "" Gw
 SG_ A m1 : 40|8@1+ (1,0) [0|0] "" Gw
BO_ 257 Lamp: 8 Body
 SG_ Level : 0|8@1+ (1,0) [0|255] "" Gw
VAL_TABLE_ OnOff 1 "On" 0 "Off" ;
CM_ "a network comment";
CM_ BO_ 256 "the door
over two lines";
CM_ SG_ 256 Speed "read";
CM_ BU_ Body "a node";
CM_ EV_ Ignition "an env var";
BA_DEF_ SG_  "GenSigSendType" ENUM "Cyclic","OnWrite";
BA_DEF_ "BusType" STRING ;
BA_DEF_DEF_  "GenSigSendType" "Cyclic";
BA_DEF_DEF_ "BusType" "CAN";
BA_DEF_DEF_ "GenMsgCycleTime" 0;
BA_ "BusType" "CAN";
BA_ "GenSigSendType" SG_ 256 Speed 1;
BA_ "GenSigSendType" SG_ 257 Level 1;
BA_ "GenMsgCycleTime" BO_ 256 100;
SIG_VALTYPE_ 256 Speed : 1;
SIG_VALTYPE_ 257 Level : 1;
SG_MUL_VAL_ 256 A Mode 1-1;
'

fn test_unread_records_are_counted_by_kind_in_file_order() {
	db := parse_dbc(unread_dbc)!
	assert db.unread == ['VAL_TABLE_ × 1', 'attribute "GenSigSendType" × 3',
		'attribute "BusType" × 2', 'SIG_VALTYPE_ × 2', 'SG_MUL_VAL_ × 1'], '${db.unread}'
	assert db.messages[0].signals[0].desc == 'read'
}

// A file whose records the reader takes, comments on its messages and nodes besides, has none unread.
fn test_comments_are_not_unread() {
	db := parse_dbc(os.read_file(os.join_path(@VMODROOT, 'dbc', 'trace.dbc'))!)!
	assert db.unread == [], '${db.unread}'
}

// The NS_ list ends where its entries do, whatever the indentation of the records after it.
fn test_the_ns_list_ends_at_its_last_entry() {
	db := parse_dbc('NS_ :
CM_
	SIG_VALTYPE_
	CM_ SG_
	BS_:
  BS_:
  BU_: Body
  BO_ 256 Door: 8 Body
   SG_ Speed : 0|32@1- (1,0) [0|0] "" Body
  SIG_VALTYPE_ 256 Speed : 1;
')!
	assert db.messages.len == 1
	assert db.unread == ['SIG_VALTYPE_ × 1'], '${db.unread}'
}

fn test_open_database_says_the_unread_records_in_one_note() {
	dir := os.join_path(os.vtmp_dir(), 'unread_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	path := os.join_path(dir, 'u.dbc')
	os.write_file(path, unread_dbc)!
	l := open_database(path)!
	assert l.unread == ['u.dbc: not read: VAL_TABLE_ × 1, attribute "GenSigSendType" × 3, attribute "BusType" × 2, SIG_VALTYPE_ × 2, SG_MUL_VAL_ × 1']
	assert l.unread[0] in l.notes
	// and a Save from the editor says it drops them, once
	assert l.db.save_drops().any(it.starts_with('not read, so not saved: VAL_TABLE_ × 1'))
	mut saved := l.db
	saved.saved()
	assert saved.save_drops() == []
}

// What the writer emits, the reader reads: a database written and read back has nothing unread.
fn test_the_writer_emits_only_records_the_reader_reads() {
	for f in os.walk_ext('dbc', '.dbc') {
		db := load_dbc_file(f)!
		x := DbcExtras{
			comment: 'provenance'
		}
		back := parse_dbc(db.to_dbc_with(x))!
		assert back.unread == [], '${f}: ${back.unread}'
	}
}
