module script

import uds

// session_lua.v — "Copy as Lua": what an operator did in the Diagnostics panel, as a script
// cmd/script runs. Each request of the exchange log (uds.LogEntry) becomes ONE test: the call the
// scripting API makes for it — the higher-level helper where the request is one
// (`diag:session(0x03)`, `diag:read_did(0xF190)`, `diag:clear_dtcs()`, …), `diag:raw` otherwise —
// with a check of the answer the operator saw: its data where the call returns some, or its NRC
// through `check.nrc`. A recorded session is then a regression test of the ECU it was recorded
// against. A request that was not answered is written as a comment, not replayed: a test that
// expects silence is not what the operator was doing.

// LuaTarget is how a script reaches one of the log's targets.
pub struct LuaTarget {
pub:
	key     string // uds.LogEntry.key
	label   string
	channel string // the project channel `uds.open` names; '' = none (its requests are left out)
	ids     bool   // a CAN target: `uds.open` is given its ids (DoIP: the channel alone)
	tx      u32    // the tester transmits on (the ECU's request id)
	rx      u32    // the ECU answers on
}

// LuaOpts is the script's context.
pub struct LuaOpts {
pub:
	project string // the project file, for `-- @project` ('' = none)
	targets []LuaTarget
}

// lua_from_log writes `entries` as a script.
pub fn lua_from_log(entries []uds.LogEntry, opts LuaOpts) string {
	mut reach := map[string]LuaTarget{} // target key -> how a script opens it
	mut missing := map[string]string{} // target key -> label, for keys no LuaTarget covers
	for e in entries {
		if !e.is_request() || e.key in reach || e.key in missing {
			continue
		}
		t := opts.targets.filter(it.key == e.key)[0] or {
			missing[e.key] = e.target
			continue
		}
		if t.channel == '' {
			missing[e.key] = t.label
			continue
		}
		reach[e.key] = t
	}
	n := entries.filter(it.is_request()).len
	mut out := []string{}
	out << '-- Recorded in the blobly_net Diagnostics panel: ${n} request(s).'
	out << '-- Each request is one test, checking the answer the operator saw.'
	if opts.project != '' {
		out << '-- @project ${opts.project}'
	} else {
		out << '-- (no project file: run it with --project <the .blobnet it was recorded under>)'
	}
	out << ''
	for _, label in missing {
		out << '-- ${one_line(label)}: no project channel reaches it; its requests are comments'
	}
	// ONE connection at a time, opened at a target's first request and let go when the requests
	// move to another: a DoIP entity serves one connection at a time, so a second open of its
	// endpoint waits on the first, and the panel itself holds one connection
	if reach.len > 0 {
		out << 'local diag  -- the connection the requests below go to'
		out << ''
	} else if missing.len > 0 {
		out << ''
	}
	h := 'diag'
	mut cur := ''
	mut i := 0
	for i < entries.len {
		e := entries[i]
		if !e.is_request() {
			out << '-- ${one_line(e.line())}'
			i++
			continue
		}
		t := reach[e.key] or { LuaTarget{} }
		if t.channel == '' || e.outcome !in [.positive, .negative] {
			why := if t.channel == '' { 'no channel reaches ${e.target}' } else { e.response_text() }
			out << '-- ${e.request_text()}: ${one_line(why)} — not replayed'
			i++
			continue
		}
		if e.key != cur {
			if cur != '' {
				out << '${h}:close()  -- the requests move to another target'
			}
			open := if t.ids {
				'uds.open(${lua_str(t.channel)}, { tx = 0x${t.tx:X}, rx = 0x${t.rx:X} })'
			} else {
				'uds.open(${lua_str(t.channel)})'
			}
			out << '${h} = ${open}' + if t.label != '' { '  -- ${one_line(t.label)}' } else { '' }
			out << ''
			cur = e.key
		}
		// a seed request and the key that followed it are one helper
		if pair := key_after(entries, i, e) {
			// (the key's own entry is the next one, which the loop steps over)
			lvl := e.req[1] & 0x7F
			call := '${h}:security_access(${lvl})'
			out << test_block('${e.seq}: ${e.request_text()} + key', if pair.outcome == .negative {
				'check.nrc(0x${pair.nrc:02X}, function() ${call} end)'
			} else {
				'${call}  -- the seed varies; the key is the reference algorithm (seed XOR FF)'
			}, e)
			i += 2
			continue
		}
		if e.req.len >= 2 && e.req[0] == 0x27 && e.req[1] & 0x7F != 0 {
			// a seed varies and a key answers one seed: neither is compared nor replayed alone
			if e.req[1] & 1 == 0 {
				out << '-- ${e.request_text()}: a key without the seed it answered — not replayed'
				i++
				continue
			}
			if e.outcome == .positive && e.resp.len > 2 && e.resp[2..].any(it != 0) {
				out << test_block('${e.seq}: ${e.request_text()}',
					'${h}:raw(fromhex("${uds.bytes_hex(e.req, 0)}"))  -- the seed varies: not compared',
					e)
				i++
				continue
			}
		}
		out << test_block('${e.seq}: ${e.request_text()}', body_of(h, e), e)
		i++
	}
	return out.join('\n') + '\n'
}

// key_after: the entry after `i`, when `e` is a seed request answered positively with a seed that
// is not all zero (an unlocked level sends no key) and that entry sends its key on the same target
// AS THE NEXT ENTRY OF THE LOG — numbered right after it, not merely next in a selection that may
// have skipped what came between.
fn key_after(entries []uds.LogEntry, i int, e uds.LogEntry) ?uds.LogEntry {
	if e.req.len != 2 || e.req[0] != 0x27 || e.req[1] & 1 == 0 || e.outcome != .positive
		|| e.resp.len < 3 || e.resp[2..].all(it == 0) || i + 1 >= entries.len {
		return none
	}
	k := entries[i + 1]
	if k.seq != e.seq + 1 || k.key != e.key || k.req.len < 2 || k.req[0] != 0x27 || k.req[1] != e.req[1] + 1
		|| k.outcome !in [.positive, .negative] {
		return none
	}
	return k
}

fn test_block(name string, body string, e uds.LogEntry) string {
	mut lines := ['test(${lua_str(name)}, function()']
	if e.pending > 0 {
		lines << '  -- answered after ${e.pending_text()} of responsePending (0x78)'
	}
	if e.note != '' {
		lines << '  -- ${one_line(e.note)}'
	}
	lines << '  ${body}'
	lines << 'end)'
	return lines.join('\n') + '\n'
}

// body_of is the test's one statement: the call and the check of what came back.
fn body_of(h string, e uds.LogEntry) string {
	call, value := call_of(h, e)
	if e.outcome == .negative {
		bare := if call.starts_with('tohex(') { call[6..call.len - 1] } else { call }
		return 'check.nrc(0x${e.nrc:02X}, function() ${bare} end)'
	}
	return if value != '' { 'check.equal(${call}, ${value})' } else { call }
}

// call_of is the call for `e`'s request, and the Lua value its return is to equal ('' = it returns
// nothing to compare). The value is taken from the answer the operator saw.
fn call_of(h string, e uds.LogEntry) (string, string) {
	req := e.req
	resp := e.resp
	sid := req[0]
	sub := if req.len > 1 { req[1] } else { u8(0) }
	suppressed := req.len > 1 && sid in [u8(0x10), 0x11, 0x19, 0x27, 0x28, 0x31, 0x3E, 0x85]
		&& sub & uds.suppress_positive != 0
	if suppressed {
		mut plain := req.clone()
		plain[1] &= 0x7F
		// whether a positive answer came anyway (one owed after a 0x78 does not count), as seen
		came := e.resp.len > 0 && e.pending == 0
		return '${h}:raw_suppressed(fromhex("${uds.bytes_hex(plain, 0)}"))', '${came}'
	}
	after := fn [resp] (n int) []u8 {
		return if resp.len > n { resp[n..] } else { []u8{} }
	}
	match sid {
		0x10 {
			if req.len == 2 {
				return 'tohex(${h}:session(0x${sub:02X}))', hex_value(after(1))
			}
		}
		0x11 {
			if req.len == 2 {
				return 'tohex(${h}:reset(0x${sub:02X}))', hex_value(after(1))
			}
		}
		0x14 {
			if req.len == 4 {
				group := u32(req[1]) << 16 | u32(req[2]) << 8 | u32(req[3])
				arg := if group == 0xFFFFFF { '' } else { '0x${group:06X}' }
				return '${h}:clear_dtcs(${arg})', ''
			}
		}
		0x19 {
			if req.len == 3 && sub == 0x02 {
				return 'tohex(${h}:read_dtcs(0x${req[2]:02X}))', hex_value(after(2))
			}
			if req.len == 3 && sub == 0x01 && resp.len == 6 {
				return '${h}:dtc_count(0x${req[2]:02X})', '${int(u16(resp[4]) << 8 | u16(resp[5]))}'
			}
		}
		0x22 {
			if req.len == 3 {
				did := u16(req[1]) << 8 | u16(req[2])
				data := after(3)
				if data.len > 0 && data.all(it >= 0x20 && it < 0x7F) {
					return '${h}:read_did(0x${did:04X})', lua_str(data.bytestr())
				}
				return 'tohex(${h}:read_did(0x${did:04X}))', hex_value(data)
			}
		}
		0x2E {
			if req.len >= 3 {
				did := u16(req[1]) << 8 | u16(req[2])
				return '${h}:write_did(0x${did:04X}, fromhex("${uds.bytes_hex(req[3..], 0)}"))', ''
			}
		}
		0x28 {
			if req.len == 3 {
				return '${h}:comm_control(${sub}, ${req[2]})', ''
			}
		}
		0x3E {
			if req.len == 2 && sub == 0 {
				return '${h}:tester_present()', ''
			}
		}
		0x85 {
			if req.len == 2 && (sub == 1 || sub == 2) {
				return '${h}:dtc_setting(${sub == 1})', ''
			}
		}
		else {}
	}
	return 'tohex(${h}:raw(fromhex("${uds.bytes_hex(req, 0)}")))', hex_value(resp)
}

fn hex_value(b []u8) string {
	return '"${uds.bytes_hex(b, 0)}"'
}

// lua_str is `s` as a Lua string literal.
fn lua_str(s string) string {
	mut b := []u8{cap: s.len + 2}
	b << `"`
	for c in s.bytes() {
		match c {
			`\\` { b << '\\\\'.bytes() }
			`"` { b << '\\"'.bytes() }
			`\n` { b << '\\n'.bytes() }
			else {
				if c < 0x20 || c == 0x7F {
					b << '\\${int(c):03}'.bytes()
				} else {
					b << c
				}
			}
		}
	}
	b << `"`
	return b.bytestr()
}

// one_line keeps a comment on its line.
fn one_line(s string) string {
	return s.replace('\n', ' ').replace('\r', ' ')
}
