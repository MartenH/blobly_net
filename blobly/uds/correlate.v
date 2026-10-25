module uds

// correlate.v — per-service correlation of a positive response with the request in flight, asked
// before the echo table (`echo_of`) for the services whose answer names more than a fixed prefix
// of the request can say.

// Verdict is what a per-service correlator decides about a positive response.
pub enum Verdict {
	answers     // it answers this request
	another     // it answers some other request
	undecidable // the correlator cannot tell: the echo table decides
}

// correlate decides whether the positive response `resp` (its SID already checked against `req`)
// answers `req`, knowing the data length of every DID in `sizes`:
//
//   0x22 — the records (a DID, then its data) name requested DIDs in the request's order; a server
//   leaves out a DID it does not serve, so they are a subsequence of the request's. A record's end
//   is known only from `sizes`, so the walk stops at the first DID of unknown size, and a response
//   whose records all named requested DIDs, as far as the walk went, answers.
//   0x23 — the data is exactly the memorySize the request asked for.
//   0x2A — a periodic data message names one of the periodic identifiers the request lists; the
//   answer to the request itself is the bare SID.
//
// What a correlator cannot read (too short, a record running past the end) is undecidable, so a
// real answer it cannot decode falls back to the echo table and is never rejected here.
pub fn correlate(req []u8, resp []u8, sizes map[u16]int) Verdict {
	if req.len == 0 || resp.len == 0 {
		return .undecidable
	}
	return match req[0] {
		0x22 { correlate_rdbi(req, resp, sizes) }
		0x23 { correlate_rmba(req, resp) }
		0x2A { correlate_periodic(req, resp) }
		else { .undecidable }
	}
}

// correlate_rdbi walks a ReadDataByIdentifier answer's records against the DIDs requested.
fn correlate_rdbi(req []u8, resp []u8, sizes map[u16]int) Verdict {
	if req.len < 3 || (req.len - 1) % 2 != 0 || resp.len < 3 {
		return .undecidable
	}
	mut asked := []u16{}
	for k := 1; k + 1 < req.len; k += 2 {
		asked << u16(req[k]) << 8 | u16(req[k + 1])
	}
	mut pos := 1
	mut next := 0 // the first requested DID a record may still name
	for pos < resp.len {
		if resp.len - pos < 2 {
			return .undecidable // a byte left over: not a record
		}
		did := u16(resp[pos]) << 8 | u16(resp[pos + 1])
		mut at := -1
		for i in next .. asked.len {
			if asked[i] == did {
				at = i
				break
			}
		}
		if at < 0 {
			// the walk is aligned (every record before this one had a known size), so a DID this
			// request did not ask for, or one out of its order, is another request's answer
			return .another
		}
		next = at + 1
		size := sizes[did] or { return .answers } // the rest cannot be walked
		pos += 2 + size
	}
	return if pos == resp.len { Verdict.answers } else { Verdict.undecidable }
}

// correlate_rmba: a ReadMemoryByAddress answer carries exactly the memorySize requested.
fn correlate_rmba(req []u8, resp []u8) Verdict {
	if req.len < 2 {
		return .undecidable
	}
	addr_len := int(req[1] & 0x0F)
	size_len := int(req[1] >> 4)
	if addr_len == 0 || size_len == 0 || size_len > 4 || req.len != 2 + addr_len + size_len {
		return .undecidable
	}
	mut size := u32(0)
	for i in 2 + addr_len .. req.len {
		size = size << 8 | u32(req[i])
	}
	return if u32(resp.len - 1) == size { Verdict.answers } else { Verdict.another }
}

// correlate_periodic: a periodic data message (6A, an identifier, its data) names an identifier
// the request lists; a stop of every identifier (mode 4 with none listed) lists none, so any data
// still arriving is the earlier request's.
fn correlate_periodic(req []u8, resp []u8) Verdict {
	if resp.len == 1 {
		return .answers
	}
	if req.len < 2 {
		return .undecidable
	}
	return if resp[1] in req[2..] { Verdict.answers } else { Verdict.another }
}
