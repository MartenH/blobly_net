// canlog — parse and format candump `.log` files (the `candump -l` line format).
//
// Format (one frame per line):
//   (<timestamp>) <iface> <id>#<hexdata>
// e.g.  (1764507600.123456) vcan0 100#AABBCCDD
//       (12.345678) can0 18FEF100#0102030405060708
//       (2.000000) vcan0 700#            (empty payload)
//       (3.000000) vcan0 200#R           (remote-transmission request)
//
// The id field is hex: <= 3 chars = standard (11-bit), > 3 chars = extended
// (29-bit) — matching candump and sut/mf4_bridge.py output. Blank lines and
// `#`-comments are skipped.
//
// Pure V, no OS-specific code (os.read_file is portable), so this module builds
// on every target — see the platform-seam note in CLAUDE.md. It reuses
// transport.CanFrame so parsed frames feed straight into the bus/trace.
module canlog

import os
import transport

// LogEntry is one parsed candump line: the frame plus its recorded timestamp
// (seconds, as written — candump uses an absolute or relative epoch) and the
// originating interface name.
pub struct LogEntry {
pub:
	t_s   f64
	iface string
	frame transport.CanFrame
}

// parse_line parses a single candump `.log` line. Returns none for blank lines,
// `#`-comments and anything that doesn't match the format.
pub fn parse_line(line string) ?LogEntry {
	s := line.trim_space()
	if s.len == 0 || s.starts_with('#') || !s.starts_with('(') {
		return none
	}
	close := s.index(')') or { return none }
	t_s := s[1..close].trim_space().f64()
	rest := s[close + 1..].trim_space()
	parts := rest.split(' ')
	if parts.len < 2 {
		return none
	}
	iface := parts[0]
	payload := parts[1]
	hash := payload.index('#') or { return none }
	idhex := payload[..hash]
	datahex := payload[hash + 1..]
	id := hex_u32(idhex) or { return none }
	extended := idhex.len > 3
	mut rtr := false
	mut data := []u8{}
	if datahex.len > 0 && (datahex[0] == `R` || datahex[0] == `r`) {
		rtr = true
	} else {
		data = hex_bytes(datahex) or { return none }
	}
	return LogEntry{
		t_s:   t_s
		iface: iface_from_token(iface) // reverses the writer's escaping; a plain name is unchanged
		frame: transport.CanFrame{
			id:       id
			extended: extended
			rtr:      rtr
			data:     data
		}
	}
}

// parse parses a whole candump `.log` text, skipping unparseable lines.
pub fn parse(text string) []LogEntry {
	mut out := []LogEntry{}
	for line in text.split_into_lines() {
		if e := parse_line(line) {
			out << e
		}
	}
	return out
}

// load_file reads and parses a candump `.log` file.
pub fn load_file(path string) ![]LogEntry {
	return parse(os.read_file(path)!)
}

// format_line renders an entry back to candump `.log` form. Inverse of
// parse_line (modulo timestamp precision and id zero-padding).
pub fn format_line(e LogEntry) string {
	idhex := if e.frame.extended { '${e.frame.id:08X}' } else { '${e.frame.id:03X}' }
	body := if e.frame.rtr { 'R' } else { bytes_hex(e.frame.data) }
	return '(${e.t_s:.6f}) ${iface_token(e.iface)} ${idhex}#${body}'
}

// iface_token makes a candump-safe interface field, REVERSIBLY. The format is whitespace-
// delimited with the payload after a '#', so a label carrying either breaks the LINE, not just
// its own field: a channel named "Powertrain CAN" writes `(t) Powertrain CAN 100#…`, which
// parse_line reads as interface "Powertrain", token "CAN" — no '#', so it drops the line
// silently. The recorder stores a LOGICAL channel name (two channels can share one interface)
// and the project editor accepts any name, so the writer has to guarantee this.
//
// Percent-encoded rather than substituted. Replacing the space with '_' kept the file parseable
// but threw the identity away: reopening gives "Powertrain_CAN", which matches no configured
// channel, so the channel filter hides its own rows and the verifier cannot place them — and
// "Powertrain CAN" and "Powertrain_CAN" become the same channel. parse_line decodes, so a
// round trip returns exactly the name that went in.
pub fn iface_token(s string) string {
	mut out := ''
	for c in s {
		out += match c {
			` `, `\t`, `#`, `(`, `)`, `%` { '%${c:02X}' }
			else { c.ascii_str() }
		}
	}
	return if out == '' { 'can' } else { out }
}

// iface_from_token reverses iface_token. A label with no escapes — every ordinary interface name
// — comes back unchanged, so foreign candump files are unaffected.
pub fn iface_from_token(s string) string {
	if !s.contains('%') {
		return s
	}
	mut out := []u8{cap: s.len}
	mut i := 0
	for i < s.len {
		if s[i] == `%` && i + 2 < s.len {
			hi := hex_nibble(s[i + 1]) or {
				out << s[i]
				i++
				continue
			}
			lo := hex_nibble(s[i + 2]) or {
				out << s[i]
				i++
				continue
			}
			c := u8(hi * 16 + lo)
			// ONLY the characters iface_token escapes. A foreign candump file may legally hold
			// `CAN%31`, and decoding that to `CAN1` would silently rename somebody else's
			// channel — while `%20` cannot appear in a real interface name, because the token
			// it decodes to (a space) is not allowed in one.
			if c !in [u8(` `), `\t`, `#`, `(`, `)`, `%`] {
				out << s[i]
				i++
				continue
			}
			out << c
			i += 3
			continue
		}
		out << s[i]
		i++
	}
	return out.bytestr()
}


fn bytes_hex(data []u8) string {
	mut s := ''
	for b in data {
		s += '${b:02X}'
	}
	return s
}

fn hex_nibble(c u8) ?u8 {
	return match c {
		`0`...`9` { c - `0` }
		`a`...`f` { c - `a` + 10 }
		`A`...`F` { c - `A` + 10 }
		else { none }
	}
}

fn hex_u32(s string) ?u32 {
	if s.len == 0 || s.len > 8 {
		return none
	}
	mut v := u32(0)
	for c in s {
		n := hex_nibble(c) or { return none }
		v = v * 16 + u32(n)
	}
	return v
}

fn hex_bytes(s string) ?[]u8 {
	if s.len % 2 != 0 {
		return none
	}
	mut out := []u8{cap: s.len / 2}
	for i := 0; i < s.len; i += 2 {
		hi := hex_nibble(s[i]) or { return none }
		lo := hex_nibble(s[i + 1]) or { return none }
		out << u8(hi) * 16 + u8(lo)
	}
	return out
}
