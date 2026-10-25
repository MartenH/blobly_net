module uds

struct CorrCase {
	name  string
	req   []u8
	resp  []u8
	sizes map[u16]int
	want  Verdict
}

fn test_the_correlator_per_service() {
	sz := {
		u16(0xF190): 2
		0xF191:      1
		0xF192:      3
	}
	cases := [
		// 0x22: records in the request's order, sized by the table
		CorrCase{'rdbi two DIDs', [u8(0x22), 0xF1, 0x90, 0xF1, 0x91], [u8(0x62), 0xF1, 0x90, 1,
			2, 0xF1, 0x91, 3], sz, .answers},
		CorrCase{'rdbi second DID of another request', [u8(0x22), 0xF1, 0x90, 0xF1, 0x92], [u8(0x62),
			0xF1, 0x90, 1, 2, 0xF1, 0x91, 3], sz, .another},
		CorrCase{'rdbi an unserved DID left out', [u8(0x22), 0xF1, 0x90, 0xF1, 0x91], [u8(0x62),
			0xF1, 0x91, 3], sz, .answers},
		CorrCase{'rdbi out of order', [u8(0x22), 0xF1, 0x90, 0xF1, 0x91], [u8(0x62), 0xF1, 0x91,
			3, 0xF1, 0x90, 1, 2], sz, .another},
		CorrCase{'rdbi first DID not asked', [u8(0x22), 0xF1, 0x90], [u8(0x62), 0xF1, 0x89, 0x41], map[u16]int{}, .another},
		CorrCase{'rdbi unknown size stops the walk', [u8(0x22), 0xF1, 0x90, 0xF1, 0x92], [u8(0x62),
			0xF1, 0x90, 1, 2, 0xF1, 0x91, 3], map[u16]int{}, .answers},
		CorrCase{'rdbi a record past the end', [u8(0x22), 0xF1, 0x90, 0xF1, 0x91], [u8(0x62), 0xF1,
			0x90, 1], sz, .undecidable},
		CorrCase{'rdbi a byte left over', [u8(0x22), 0xF1, 0x90, 0xF1, 0x91], [u8(0x62), 0xF1,
			0x90, 1, 2, 0xF1], sz, .undecidable},
		CorrCase{'rdbi too short to read', [u8(0x22), 0xF1, 0x90], [u8(0x62), 0xF1], sz, .undecidable},
		// 0x23: exactly memorySize bytes
		CorrCase{'rmba its size', [u8(0x23), 0x12, 0x20, 0x00, 0x03], [u8(0x63), 1, 2, 3], sz, .answers},
		CorrCase{'rmba another size', [u8(0x23), 0x12, 0x20, 0x00, 0x03], [u8(0x63), 1, 2], sz, .another},
		CorrCase{'rmba a format it cannot read', [u8(0x23), 0x00], [u8(0x63), 1], sz, .undecidable},
		// 0x2A: the bare answer, or data naming a listed identifier
		CorrCase{'periodic the answer', [u8(0x2A), 0x03, 0x01, 0x02], [u8(0x6A)], sz, .answers},
		CorrCase{'periodic a listed identifier', [u8(0x2A), 0x03, 0x01, 0x02], [u8(0x6A), 0x02,
			9], sz, .answers},
		CorrCase{'periodic another identifier', [u8(0x2A), 0x03, 0x01, 0x02], [u8(0x6A), 0x05,
			9], sz, .another},
		CorrCase{'periodic data after a stop of all', [u8(0x2A), 0x04], [u8(0x6A), 0x01, 9], sz, .another},
		// every other service is the echo table's
		CorrCase{'other services', [u8(0x10), 0x03], [u8(0x50), 0x03], sz, .undecidable},
	]
	for c in cases {
		assert correlate(c.req, c.resp, c.sizes) == c.want, c.name
	}
}

// the correlator's verdict is answer_to's, and what it cannot decide keeps today's outcome
fn test_answer_to_asks_the_correlator_first() {
	sz := {
		u16(0xF190): 2
	}
	req := [u8(0x22), 0xF1, 0x90, 0xF1, 0x91]
	assert answer_to_sized(req, [u8(0x62), 0xF1, 0x90, 1, 2, 0xF1, 0x92, 0], sz) == .stale
	assert answer_to_sized(req, [u8(0x62), 0xF1, 0x90, 1, 2, 0xF1, 0x91, 0], sz) == .positive
	assert answer_to(req, [u8(0x62), 0xF1, 0x91, 7]) == .positive // F190 left out by the server
	assert answer_to(req, [u8(0x62), 0xF1]) == .malformed
	assert answer_to([u8(0x23), 0x11, 0x20, 0x02], [u8(0x63), 1]) == .stale
}
