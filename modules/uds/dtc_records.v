module uds

// DTC records (ISO 14229-1 0x19 03 / 04 / 06): which DTCs hold a snapshot, a DTC's snapshot
// records (its freeze frame: data identifiers with their values), and its extended data records.
//
// A snapshot record lists DIDs and their data back to back with no lengths: the tester must know
// each DID's size. The decoder takes them as a map; the client learns one it does not know by
// reading that DID (0x22) — the value's length is the DID's — so a script needs no description
// file for a server whose snapshot DIDs it may read. Extended data records are the same: a record
// number's size is the server's to define; `blobly_ext_records` are blobly_emb's (its fault
// memory's counters, docs/diagnostics.md in blobly_emb).

// blobly_ext_records: blobly_emb's extended data records and their sizes — 0x01 the occurrence
// counter (2 bytes, big-endian), 0x02 the aging counter, 0x03 the failed operation cycle counter.
pub const blobly_ext_records = {
	u8(0x01): 2
	u8(0x02): 1
	u8(0x03): 1
}

// SnapshotId is one entry of a 0x19 03 answer: a DTC and one of its snapshot record numbers.
pub struct SnapshotId {
pub:
	code   u32
	record u8
}

pub fn (s SnapshotId) name() string {
	return dtc_name(s.code)
}

// SnapshotDid is one data identifier of a snapshot record, with its value at capture.
pub struct SnapshotDid {
pub:
	id   u16
	data []u8
}

// SnapshotRecord is one snapshot record: its number and its DIDs, in the server's order.
pub struct SnapshotRecord {
pub:
	number u8
	dids   []SnapshotDid
}

// find is the value of `id` in this record, if it holds it.
pub fn (r SnapshotRecord) find(id u16) ?[]u8 {
	for d in r.dids {
		if d.id == id {
			return d.data
		}
	}
	return none
}

// DtcSnapshot is a 0x19 04 answer: the DTC with its status, and the snapshot records stored for
// it (none is a valid answer: a DTC with nothing stored).
pub struct DtcSnapshot {
pub:
	dtc     DtcRecord
	records []SnapshotRecord
}

// ExtRecord is one extended data record: its number and its bytes.
pub struct ExtRecord {
pub:
	number u8
	data   []u8
}

// value is the record read as a big-endian unsigned integer.
pub fn (r ExtRecord) value() u64 {
	mut v := u64(0)
	for b in r.data {
		v = v << 8 | u64(b)
	}
	return v
}

// DtcExtended is a 0x19 06 answer: the DTC with its status and its extended data records.
pub struct DtcExtended {
pub:
	dtc     DtcRecord
	records []ExtRecord
}

// find is record `number`, if the answer carries it.
pub fn (e DtcExtended) find(number u8) ?ExtRecord {
	for r in e.records {
		if r.number == number {
			return r
		}
	}
	return none
}

// UnknownDidLength is the snapshot decoder asking for a DID's size it was not given.
pub struct UnknownDidLength {
	Error
pub:
	did u16
}

pub fn (e UnknownDidLength) msg() string {
	return 'snapshot DID 0x${e.did:04X}: its size is not known'
}

// decode_snapshot_ids reads a positive 0x19 03 answer (59 03 {DTC high, middle, low, record}*).
pub fn decode_snapshot_ids(resp []u8) ![]SnapshotId {
	if resp.len < 2 || resp[0] != 0x59 || resp[1] != 0x03 {
		return error('not a 0x19 03 answer: ${resp.hex()}')
	}
	if (resp.len - 2) % 4 != 0 {
		return error('0x19 03 answer of ${resp.len} bytes is not a whole number of entries')
	}
	mut out := []SnapshotId{cap: (resp.len - 2) / 4}
	for i := 2; i < resp.len; i += 4 {
		out << SnapshotId{
			code:   u32(resp[i]) << 16 | u32(resp[i + 1]) << 8 | u32(resp[i + 2])
			record: resp[i + 3]
		}
	}
	return out
}

// dtc_header reads the `59 <sub> <DTC> <status>` every 0x19 04 / 06 answer begins with.
fn dtc_header(resp []u8, sub u8) !DtcRecord {
	if resp.len < 6 || resp[0] != 0x59 || resp[1] != sub {
		return error('not a 0x19 ${sub:02X} answer: ${resp.hex()}')
	}
	return DtcRecord{
		code:   u32(resp[2]) << 16 | u32(resp[3]) << 8 | u32(resp[4])
		status: resp[5]
	}
}

// decode_snapshot reads a positive 0x19 04 answer ({record number, DID count, {DID, data}*}* after
// the header), each DID's data `lens[id]` bytes long; a DID count of 0 (more than 255, or not
// stated) runs to the end of the answer. A DID whose length is not in `lens` is an
// UnknownDidLength error.
pub fn decode_snapshot(resp []u8, lens map[u16]int) !DtcSnapshot {
	dtc := dtc_header(resp, 0x04)!
	mut recs := []SnapshotRecord{}
	mut i := 6
	for i < resp.len {
		if i + 2 > resp.len {
			return error('0x19 04 answer ends inside a record header at byte ${i}')
		}
		number := resp[i]
		count := int(resp[i + 1])
		i += 2
		mut dids := []SnapshotDid{cap: count}
		// a count of 0 is ISO 14229-1's "not stated": the pairs run to the end of the answer
		for k := 0; (count == 0 && i < resp.len) || (count != 0 && k < count); k++ {
			if i + 2 > resp.len {
				return error('0x19 04 record 0x${number:02X} ends inside a DID at byte ${i}')
			}
			id := u16(resp[i]) << 8 | u16(resp[i + 1])
			n := lens[id] or { return UnknownDidLength{
				did: id
			} }
			if n < 0 {
				return error('0x19 04: DID 0x${id:04X} is configured with a negative size (${n})')
			}
			if i + 2 + n > resp.len {
				return error('0x19 04 record 0x${number:02X}: DID 0x${id:04X} of ${n} bytes runs past the answer')
			}
			dids << SnapshotDid{
				id:   id
				data: resp[i + 2..i + 2 + n].clone()
			}
			i += 2 + n
		}
		recs << SnapshotRecord{
			number: number
			dids:   dids
		}
	}
	return DtcSnapshot{
		dtc:     dtc
		records: recs
	}
}

// decode_extended reads a positive 0x19 06 answer ({record number, data}* after the header), each
// record `lens[number]` bytes long.
pub fn decode_extended(resp []u8, lens map[u8]int) !DtcExtended {
	dtc := dtc_header(resp, 0x06)!
	mut recs := []ExtRecord{}
	mut i := 6
	for i < resp.len {
		number := resp[i]
		n := lens[number] or {
			return error('0x19 06 extended data record 0x${number:02X}: its length is not known')
		}
		if n < 0 {
			return error('0x19 06 record 0x${number:02X} is configured with a negative size (${n})')
		}
		if i + 1 + n > resp.len {
			return error('0x19 06 record 0x${number:02X} of ${n} bytes runs past the answer')
		}
		recs << ExtRecord{
			number: number
			data:   resp[i + 1..i + 1 + n].clone()
		}
		i += 1 + n
	}
	return DtcExtended{
		dtc:     dtc
		records: recs
	}
}

fn dtc_request(sub u8, code u32, record u8) []u8 {
	return [sid_read_dtc_information, sub, u8(code >> 16), u8(code >> 8), u8(code), record]
}

// snapshot_ids (0x19 03): every DTC holding a snapshot record, with the record's number.
pub fn (mut c Client) snapshot_ids() ![]SnapshotId {
	return decode_snapshot_ids(c.raw([sid_read_dtc_information, 0x03])!)!
}

// snapshot (0x19 04): DTC `code`'s snapshot record `record` (0xFF = every one). A DID whose size
// the client does not know yet (`did_lens`, or set_did_size) is read once (0x22) to learn it — the
// size of its value NOW, which is the captured one's for a fixed-size DID; a DID whose size varies
// must be given.
pub fn (mut c Client) snapshot(code u32, record u8) !DtcSnapshot {
	resp := c.raw(dtc_request(0x04, code, record))!
	for {
		return decode_snapshot(resp, c.did_lens) or {
			if err is UnknownDidLength {
				did := err.did
				data := c.read_data_by_identifier(did) or {
					return error('snapshot DID 0x${did:04X}: its size is not known, and reading it (0x22) to learn it failed: ${err.msg()} — give it with set_did_size')
				}
				c.did_lens[did] = data.len
				continue
			}
			return err
		}
	}
	return error('unreachable') // each pass learns one DID the answer names, or returns
}

// set_did_size states snapshot DID `id`'s size, for one the client cannot read or whose size varies.
pub fn (mut c Client) set_did_size(id u16, n int) {
	c.did_lens[id] = n
}

// set_ext_record_size states extended data record `number`'s size (blobly_ext_records otherwise).
pub fn (mut c Client) set_ext_record_size(number u8, n int) {
	if c.ext_lens.len == 0 {
		c.ext_lens = blobly_ext_records.clone()
	}
	c.ext_lens[number] = n
}

// extended (0x19 06): DTC `code`'s extended data record `record` (0xFF = every one), sized by
// `ext_lens` (blobly_ext_records by default).
pub fn (mut c Client) extended(code u32, record u8) !DtcExtended {
	lens := if c.ext_lens.len == 0 { blobly_ext_records } else { c.ext_lens }
	return decode_extended(c.raw(dtc_request(0x06, code, record))!, lens)!
}
