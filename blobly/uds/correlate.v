module uds

// correlate.v — per-service correlation of a positive response with the request in flight, asked
// before the echo table (`echo_of`) for the services whose answer names more of the request than
// a fixed prefix of it.

// Verdict is what a per-service correlator decides about a positive response.
pub enum Verdict {
	answers     // it answers this request
	another     // it answers some other request
	undecidable // the correlator cannot tell: the echo table decides
}

// correlate decides whether the positive response `resp` (its SID already checked against `req`)
// answers `req`, taking `sizes` as the data length of each DID in it:
//
//   0x22 with several DIDs — the records (a DID, then its data) name requested DIDs in the
//   request's order, the first record the first DID (as the echo table asks of any 0x22); after
//   it a server may leave out a DID it does not serve, so the rest are a subsequence of the
//   request's. A record's end is known only from `sizes`, so the walk stops at the first DID of
//   unknown size, and an answer whose records named requested DIDs as far as the walk went
//   answers. A size that is wrong for this ECU misaligns the walk, which then reads the answer as
//   another request's.
//   0x2A — a periodic data message names one of the periodic identifiers the request lists.
//
// A one-DID 0x22, and what a correlator cannot read (too short, a record running past the end),
// is undecidable: the echo table decides, as it did before there was a correlator.
pub fn correlate(req []u8, resp []u8, sizes map[u16]int) Verdict {
	if req.len == 0 || resp.len == 0 {
		return .undecidable
	}
	return match req[0] {
		0x22 { correlate_rdbi(req, resp, sizes) }
		0x2A { correlate_periodic(req, resp) }
		else { .undecidable }
	}
}

// correlate_rdbi walks a multi-DID ReadDataByIdentifier answer's records against the DIDs
// requested (req[1..] in pairs).
fn correlate_rdbi(req []u8, resp []u8, sizes map[u16]int) Verdict {
	if req.len < 5 || (req.len - 1) % 2 != 0 || resp.len < 3 {
		return .undecidable
	}
	if resp[1] != req[1] || resp[2] != req[2] {
		return .another
	}
	mut pos := 1
	mut next := 1 // where in req the DIDs a record may still name begin
	for pos < resp.len {
		if resp.len - pos < 2 {
			return .undecidable // a byte left over: not a record
		}
		mut at := -1
		for k := next; k + 1 < req.len; k += 2 {
			if req[k] == resp[pos] && req[k + 1] == resp[pos + 1] {
				at = k
				break
			}
		}
		if at < 0 {
			// the walk is aligned (every record before this one had a known size), so a DID this
			// request did not ask for, or one out of its order, is another request's answer
			return .another
		}
		next = at + 2
		size := sizes[u16(resp[pos]) << 8 | u16(resp[pos + 1])] or { return .answers }
		if size < 0 {
			return .undecidable
		}
		pos += 2 + size
	}
	return if pos == resp.len { Verdict.answers } else { Verdict.undecidable }
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

// read_sizes: the DID sizes a 0x22 answer to `req` is correlated by — those learned by reading the
// DID or put on the client from a description, never one stated with set_did_size, which may be a
// variable DID's captured snapshot size rather than its value's now. Empty for any other request.
fn (c &Client) read_sizes(req []u8) map[u16]int {
	if req.len < 5 || req[0] != 0x22 {
		return map[u16]int{}
	}
	if c.stated_did_lens.len == 0 {
		return c.did_lens
	}
	mut sizes := map[u16]int{}
	for id, n in c.did_lens {
		if id !in c.stated_did_lens {
			sizes[id] = n
		}
	}
	return sizes
}
