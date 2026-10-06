module uds

import transport

// Captured from blobly_emb's own fault memory and diagnostic server (comm/fault + comm/uds of
// blobly_emb PR #372, at 660a40f), configured as its examples/overspeed declares the engine faults
// — P0219-00 with the snapshot [0xF1A0 speed (2 B), 0xF190 ECU id (19 B)], priority 1; P0506-00
// with [0xF1A0]; ONE snapshot entry — and driven in process: the idle fault fails at 12 km/h and
// takes the entry; the over-rev fails in the same cycle (it may not displace this cycle's
// evidence), and in the next cycle, at 88 km/h, displaces it.
const emb_19_03_idle = [u8(0x59), 0x03, 0x05, 0x06, 0x00, 0x01]
const emb_19_04_idle = [u8(0x59), 0x04, 0x05, 0x06, 0x00, 0x2F, 0x01, 0x01, 0xF1, 0xA0, 0x00, 0x0C]
const emb_19_03 = [u8(0x59), 0x03, 0x02, 0x19, 0x00, 0x01]
const emb_19_04_all = [u8(0x59), 0x04, 0x02, 0x19, 0x00, 0x2F, 0x01, 0x02, 0xF1, 0xA0, 0x00, 0x58,
	0xF1, 0x90, 0x42, 0x4C, 0x4F, 0x42, 0x4C, 0x59, 0x2D, 0x4F, 0x56, 0x45, 0x52, 0x53, 0x50, 0x45,
	0x45, 0x44, 0x2D, 0x30, 0x31]
const emb_19_04_displaced = [u8(0x59), 0x04, 0x05, 0x06, 0x00, 0x2C]
const emb_19_06_all = [u8(0x59), 0x06, 0x02, 0x19, 0x00, 0x2F, 0x01, 0x00, 0x02, 0x02, 0x00, 0x03,
	0x02]
const emb_19_06_aging = [u8(0x59), 0x06, 0x02, 0x19, 0x00, 0x2F, 0x02, 0x00]

fn test_blobly_emb_snapshot_answers_decode() {
	idle_ids := decode_snapshot_ids(emb_19_03_idle) or { panic(err) }
	assert idle_ids.len == 1 && idle_ids[0].name() == 'P0506-00' && idle_ids[0].record == 1
	ids := decode_snapshot_ids(emb_19_03) or { panic(err) }
	assert ids.map(it.name()) == ['P0219-00']
	lens := {
		u16(0xF1A0): 2
		0xF190:      19
	}
	idle := decode_snapshot(emb_19_04_idle, lens) or { panic(err) }
	assert idle.dtc.name() == 'P0506-00' && idle.dtc.status == 0x2F
	assert idle.records.len == 1 && idle.records[0].number == 1
	assert idle.records[0].find(0xF1A0) or { panic('no speed') } == [u8(0x00), 0x0C]
	s := decode_snapshot(emb_19_04_all, lens) or { panic(err) }
	assert s.dtc.code == 0x021900 && s.dtc.has(dtc_confirmed)
	assert s.records.len == 1
	assert s.records[0].dids.map(it.id) == [u16(0xF1A0), 0xF190]
	assert s.records[0].dids[0].data == [u8(0x00), 0x58] // 88 km/h at the failure
	assert s.records[0].dids[1].data.bytestr() == 'BLOBLY-OVERSPEED-01'
	// the displaced DTC: still known, its status kept, no record
	gone := decode_snapshot(emb_19_04_displaced, lens) or { panic(err) }
	assert gone.dtc.name() == 'P0506-00' && gone.dtc.status == 0x2C && gone.records.len == 0
	e := decode_extended(emb_19_06_all, blobly_ext_records) or { panic(err) }
	assert e.records.map(it.number) == [u8(1), 2, 3]
	assert (e.find(1) or { panic('') }).value() == 2 // occurrences
	assert (e.find(2) or { panic('') }).value() == 0 // aging
	assert (e.find(3) or { panic('') }).value() == 2 // failed cycles
	a := decode_extended(emb_19_06_aging, blobly_ext_records) or { panic(err) }
	assert a.records.len == 1 && a.records[0].data == [u8(0)]
}

// What the decoders refuse: another answer, a cut record, a DID or a record size not known.
fn test_malformed_record_answers_are_refused() {
	decode_snapshot_ids([u8(0x59), 0x03, 0x02, 0x19]) or {
		assert err.msg().contains('whole number')
		return
	}
	assert false
}

fn snap_err(resp []u8, lens map[u16]int) IError {
	decode_snapshot(resp, lens) or { return err }
	panic('decoded')
}

fn ext_err(resp []u8) IError {
	decode_extended(resp, blobly_ext_records) or { return err }
	panic('decoded')
}

fn test_an_unknown_did_size_is_its_own_error() {
	e := snap_err(emb_19_04_all, {
		u16(0xF1A0): 2
	})
	assert e is UnknownDidLength && (e as UnknownDidLength).did == 0xF190
	assert snap_err(emb_19_04_all#[..-3], {
		u16(0xF1A0): 2
		0xF190:      19
	}).msg().contains('runs past the answer')
	assert snap_err(emb_19_06_all, {}).msg().contains('not a 0x19 04 answer')
	assert ext_err([u8(0x59), 0x06, 0x02, 0x19, 0x00, 0x2F, 0x09, 0x00]).msg().contains('record 0x09: its length is not known')
	assert ext_err([u8(0x59), 0x06, 0x02, 0x19, 0x00, 0x2F, 0x01, 0x00]).msg().contains('runs past the answer')
}

// RecChannel answers each request from a table of canned answers.
struct RecChannel {
pub:
	iface string = 'mock'
	tx_id u32
	rx_id u32
mut:
	answers map[string][]u8
	asked   []string
	queue   [][]u8
	late    []u8 // arrives after the next request, ahead of its answer (a retransmitted earlier one)
}

fn (mut m RecChannel) send(data []u8) ! {
	m.asked << data.hex()
	if m.late.len > 0 {
		m.queue << m.late
		m.late = []u8{}
	}
	m.queue << m.answers[data.hex()] or { [u8(0x7F), data[0], 0x31] }
}

fn (mut m RecChannel) recv(timeout_ms int) ![]u8 {
	if timeout_ms == 0 || m.queue.len == 0 {
		return error('timeout')
	}
	r := m.queue[0]
	m.queue.delete(0)
	return r
}

fn (mut m RecChannel) close() {}

fn (mut m RecChannel) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

// The client learns a snapshot DID's size by reading it once (0x22) and keeps it, so the next
// snapshot asks nothing more; extended data is sized by blobly_emb's records.
fn test_the_client_learns_a_did_size_by_reading_it() {
	mut m := &RecChannel{
		answers: {
			'1904021900ff': emb_19_04_all
			'22f1a0':       [u8(0x62), 0xF1, 0xA0, 0x00, 0x30]
			'22f190':       '\x62\xF1\x90BLOBLY-OVERSPEED-01'.bytes()
			'1906021900ff': emb_19_06_all
			'1903':         emb_19_03
		}
	}
	mut c := new_client(m)
	s := c.snapshot(0x021900, 0xFF) or { panic(err) }
	assert s.records[0].dids[1].data.bytestr() == 'BLOBLY-OVERSPEED-01'
	assert m.asked == ['1904021900ff', '22f1a0', '22f190']
	c.snapshot(0x021900, 0xFF) or { panic(err) }
	assert m.asked.len == 4, 'the sizes were read again'
	e := c.extended(0x021900, 0xFF) or { panic(err) }
	assert (e.find(1) or { panic('') }).value() == 2
	assert (c.snapshot_ids() or { panic(err) })[0].code == 0x021900
}

// A late answer about ANOTHER DTC (its frame retransmitted after the request for this one went out)
// is not this request's answer: the DTC is part of what a 0x19 04 / 06 answer echoes.
fn test_an_answer_about_another_dtc_is_not_taken() {
	mut m := &RecChannel{
		answers: {
			'1904050600ff': emb_19_04_displaced
			'1906021900ff': emb_19_06_all
		}
		late:    emb_19_04_all.clone()
	}
	mut c := new_client(m)
	s := c.snapshot(0x050600, 0xFF) or { panic(err) }
	assert s.dtc.code == 0x050600 && s.records.len == 0
	m.late = emb_19_04_displaced.clone()
	e := c.extended(0x021900, 0xFF) or { panic(err) }
	assert e.dtc.code == 0x021900
}

// A DID count of 0 is "not stated": the DIDs run to the end of the answer.
fn test_an_unstated_did_count_runs_to_the_end() {
	mut r := emb_19_04_all.clone()
	r[7] = 0
	s := decode_snapshot(r, {
		u16(0xF1A0): 2
		0xF190:      19
	}) or { panic(err) }
	assert s.records.len == 1 && s.records[0].dids.len == 2
}

// A size the tester cannot learn (the DID is not readable) is given instead.
fn test_a_size_can_be_given() {
	mut m := &RecChannel{
		answers: {
			'1904021900ff': emb_19_04_all
		}
	}
	mut c := new_client(m)
	c.snapshot(0x021900, 0xFF) or {
		assert err.msg().contains('snapshot DID 0xF1A0: its size is not known, and reading it (0x22) to learn it failed')
		c.set_did_size(0xF1A0, 2)
		c.set_did_size(0xF190, 19)
		s := c.snapshot(0x021900, 0xFF) or { panic(err) }
		assert s.records[0].dids.len == 2
		return
	}
	assert false
}

// A request for ONE record is answered with that record's number after the DTC and its status: a
// late answer about another record of the same DTC is not this one's. All records (0xFF), and an
// answer carrying no record at all, are matched on the DTC alone.
fn test_an_answer_about_another_record_is_not_taken() {
	for sub in [u8(0x04), 0x06] {
		req := [u8(0x19), sub, 0x05, 0x06, 0x00, 0x01]
		assert answer_to(req, [u8(0x59), sub, 0x05, 0x06, 0x00, 0x2F, 0x01, 0xAA]) == .positive
		assert answer_to(req, [u8(0x59), sub, 0x05, 0x06, 0x00, 0x2F, 0x02, 0xAA]) == .stale
		assert answer_to(req, [u8(0x59), sub, 0x05, 0x06, 0x00, 0x2F]) == .positive // no record stored
		all := [u8(0x19), sub, 0x05, 0x06, 0x00, 0xFF]
		assert answer_to(all, [u8(0x59), sub, 0x05, 0x06, 0x00, 0x2F, 0x02, 0xAA]) == .positive
	}
}

// 0x19 06 0xFE asks for every OBD record: the answer carries their own numbers, so it is not stale
fn test_an_obd_group_extended_request_takes_any_record() {
	req := [u8(0x19), 0x06, 0x05, 0x06, 0x00, 0xFE]
	assert answer_to(req, [u8(0x59), 0x06, 0x05, 0x06, 0x00, 0x2F, 0x92, 0xAA]) == .positive
	// for 0x04, 0xFE is an ordinary record number
	r4 := [u8(0x19), 0x04, 0x05, 0x06, 0x00, 0xFE]
	assert answer_to(r4, [u8(0x59), 0x04, 0x05, 0x06, 0x00, 0x2F, 0x01, 0xAA]) == .stale
}

// a size stated as negative is an error, never a reversed slice
fn test_a_negative_configured_size_is_an_error() {
	if _ := decode_snapshot(emb_19_04_all, {
		u16(0xF1A0): -1
		0xF190:      19
	})
	{
		assert false, 'a negative DID size decoded'
	}
	if _ := decode_extended(emb_19_06_all, {
		u8(0x01): -2
		0x02:     1
		0x03:     1
	})
	{
		assert false, 'a negative record size decoded'
	}
}

// a configured size near max_int is compared with what remains of the answer, so it cannot overflow
// the bounds check into a slice past the end
fn test_a_huge_configured_size_is_an_error() {
	if _ := decode_snapshot(emb_19_04_all, {
		u16(0xF1A0): max_int
		0xF190:      19
	})
	{
		assert false, 'a max_int DID size decoded'
	}
	if _ := decode_extended(emb_19_06_all, {
		u8(0x01): max_int
		0x02:     1
		0x03:     1
	})
	{
		assert false, 'a max_int record size decoded'
	}
}

// a DTC wider than 24 bits is refused before anything is sent, as clear_dtc refuses a wide group
fn test_a_dtc_wider_than_24_bits_is_refused() {
	if _ := dtc_request(0x04, 0x01_050600, 0xFF) {
		assert false, 'a 32-bit DTC was truncated into a request for another DTC'
	}
	r := dtc_request(0x06, 0x050600, 0xFF) or { panic(err) }
	assert r == [u8(0x19), 0x06, 0x05, 0x06, 0x00, 0xFF]
}

// A positive answer that cannot be read is the ECU answering — an UndecodableAnswer, which a
// tester holding a connection keeps it through — while a silence stays an ordinary error.
fn test_an_undecodable_answer_is_told_from_a_silence() {
	mut m := &RecChannel{
		answers: {
			'1906021900ff': [u8(0x59), 0x06, 0x02, 0x19, 0x00, 0x2F, 0x04, 0x00] // record 0x04: no size
			'1902ff':       [u8(0x59), 0x02, 0xFF, 0x02, 0x19] // half a record
		}
	}
	mut c := new_client(m)
	if _ := c.extended(0x021900, 0xFF) {
		assert false
	} else {
		assert err is UndecodableAnswer
	}
	if _ := c.dtcs(0xFF) {
		assert false
	} else {
		assert err is UndecodableAnswer
	}
	if _ := c.extended(0x050600, 0xFF) { // not in the table: refused 0x31
		assert false
	} else {
		assert err is NegativeResponse
	}
}

fn test_blobly_counters_name_the_records() {
	e := decode_extended(emb_19_06_all, blobly_ext_records) or { panic(err) }
	k := e.blobly_counters()
	assert k.occurrences == (e.find(0x01) or { panic('') }).value()
	assert k.aging == (e.find(0x02) or { panic('') }).value()
	assert k.failed_cycles == (e.find(0x03) or { panic('') }).value()
	assert k.has == [u8(1), 2, 3]
	assert DtcExtended{}.blobly_counters().has == []
}
