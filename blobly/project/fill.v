module project

import blobly.candb
import yaml

// fill.v — the byte the bits of a payload no signal covers take (#671): a generator's `fill:`,
// else its row's, else the message's own (an ARXML PDU's UNUSED-BIT-PATTERN), else 0. The row's
// goes onto the database the row's frames are built from (row_db); candb.Message.fill_unused is
// the one rule that writes it.

// parse_fill reads a `fill:` value: a byte, in hex after 0x or decimal; refused otherwise.
fn parse_fill(v yaml.Any, who string) !u8 {
	text := v.str()
	n := parse_id_exact(text) or { return error('${who}: fill: "${text}" is not a byte (0x00 .. 0xFF)') }
	if n > 0xFF {
		return error('${who}: fill: ${text} is not a byte (0x00 .. 0xFF)')
	}
	return u8(n)
}

// fill_yaml is a fill as a project file writes it.
fn fill_yaml(f u8) string {
	return '"0x${f:02X}"'
}

// row_db is database `db` as row `ch` builds frames from it (with_fill of the row's fill).
pub fn (ch Channel) row_db(db candb.Database) candb.Database {
	return with_fill(db, ch.fill)
}

// with_fill is database `db` carrying a row's fill `fill`, which replaces each message's own
// (candb.Database.filled); `db` as it is where the row states none.
pub fn with_fill(db candb.Database, fill ?u8) candb.Database {
	f := fill or { return db }
	return candb.Database{
		...db
		fill: f
	}
}

// sent_message is message `m` of the row database `db` as generator `s` sends it: its fill the
// generator's where it states one, else the row's (row_db), else the message's own.
pub fn (s Sender) sent_message(db candb.Database, m candb.Message) candb.Message {
	f := s.fill or { return db.filled(m) }
	return candb.Message{
		...m
		fill: f
	}
}
