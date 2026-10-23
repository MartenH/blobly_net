module diaghold

// did.v — the DIDs tab's rules: a DID typed by hand, the last check before a write, and what a
// Read all says in the log. What a write has to establish first is uds.write_plan's, which a
// script's write asks too.

// parse_did reads a DID typed by hand: one to four hex digits, `0x` optional. none for anything
// else — a typo must not become 0x0000, nor five digits a truncated other DID.
pub fn parse_did(t string) ?u16 {
	mut s := t.trim_space()
	if s.starts_with('0x') || s.starts_with('0X') {
		s = s[2..]
	}
	if s.len == 0 || s.len > 4 {
		return none
	}
	mut v := u16(0)
	for c in s {
		d := match c {
			`0`...`9` { c - `0` }
			`a`...`f` { c - `a` + 10 }
			`A`...`F` { c - `A` + 10 }
			else { return none }
		}
		v = v << 4 | u16(d)
	}
	return v
}

// write_still_current: the last check before a 0x2E goes out, asked by the holder for EVERY
// write, after the session switch and the unlock and immediately before the send: the description
// the write was made under (`req_ident`) must still be the loaded one (`now_ident`). A reload
// while the write was queued, or while an open, a session change or an unlock was slow, may have
// moved its layout or taken its write gate away — the bytes were encoded by the old one. '' = send.
pub fn write_still_current(req_ident string, now_ident string) string {
	if req_ident == now_ident {
		return ''
	}
	return 'not written: the description was reloaded since this write was made — open the dialog again'
}

// edit_room is an edit field's buffer size: a DID of `size` bytes as hex (three characters a
// byte) with room to type past it, so too long is said by encode rather than cut by the field —
// and never less than the text it starts with (`text_len`), which it must hold whole.
pub fn edit_room(size int, text_len int) int {
	mut n := if size > 0 { 3 * size + 16 } else { 0 }
	if n < 128 {
		n = 128
	}
	return if text_len + 1 + 16 > n { text_len + 1 + 16 } else { n }
}

// DidBatch is a Read all: every DID asked in turn. A refusal is that DID's (supported or not, in
// this session or not) and the batch goes on; only the connection failing ends it. Said in the log
// as ONE line — the count, the refusals by code, the summed time — since each DID's own answer and
// time is in the table: thirty lines a press would bury every other.
pub struct DidBatch {
pub mut:
	read    int
	refused int
	nrcs    map[u8]int // refusals by negative response code; 0 = answered but not readable
	failed  string
	t       Timing
}

pub fn (mut b DidBatch) answered(t Timing) {
	b.read++
	b.t = b.t.plus(t)
}

pub fn (mut b DidBatch) refusal(t Timing, nrc u8) {
	b.refused++
	b.nrcs[nrc] = (b.nrcs[nrc] or { 0 }) + 1
	b.t = b.t.plus(t)
}

pub fn (mut b DidBatch) failure(t Timing, why string) {
	b.failed = why
	b.t = b.t.plus(t)
}

pub fn (b DidBatch) going() bool {
	return b.failed == ''
}

// summary is the batch's line (after its timing column): `of` is how many DIDs it was to ask.
pub fn (b DidBatch) summary(of int) string {
	mut line := 'Read all, ${of} DID(s): ${b.read} read'
	if b.refused > 0 {
		mut codes := b.nrcs.keys()
		codes.sort()
		by := codes.map(if it == 0 {
			'unreadable ×${b.nrcs[it]}'
		} else {
			'0x${it:02X} ×${b.nrcs[it]}'
		})
		line += ', ${b.refused} refused (${by.join(', ')})'
	}
	if b.failed != '' {
		rest := of - b.read - b.refused - 1
		line += '; stopped: ${b.failed}'
		if rest > 0 {
			line += ' (${rest} not asked)'
		}
	}
	return line
}

// refused_words is a DID the ECU refused, as its row in the DIDs tab says it: the NRC and `name`,
// its ISO 14229-1 name (uds.nrc_name). The two session refusals say what they mean for a DID —
// served, but not in the session the connection is in — since a session change is exactly what
// the row's Read is kept for.
pub fn refused_words(nrc u8, name string) string {
	if nrc == 0x7F || nrc == 0x7E {
		return '0x${nrc:02X} not supported in this session'
	}
	return '0x${nrc:02X} ${name}'
}
