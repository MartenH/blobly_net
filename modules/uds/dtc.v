module uds

// dtc.v — ReadDTCInformation (0x19) answers as a model: a DTC's code and display name, its
// status byte with each bit named (ISO 14229-1 D.2), and the decoders for the sub-functions a
// blobly_emb server serves (01, 02, 0A — docs/diagnostics.md, D6). Pinned by bytes captured from
// blobly_emb's own fault memory, so the two sides agree by test and not by reading.

// The DTC status bits (ISO 14229-1 D.2), low to high.
pub const dtc_test_failed = u8(0x01)
pub const dtc_test_failed_this_cycle = u8(0x02)
pub const dtc_pending = u8(0x04)
pub const dtc_confirmed = u8(0x08)
pub const dtc_not_completed_since_clear = u8(0x10)
pub const dtc_failed_since_clear = u8(0x20)
pub const dtc_not_completed_this_cycle = u8(0x40)
pub const dtc_warning_indicator = u8(0x80)

// dtc_status_bits: each status bit and its ISO 14229-1 name, low to high — the one list a report,
// a Lua table and an assertion all name bits by.
pub const dtc_status_bits = [
	DtcBit{dtc_test_failed, 'testFailed'},
	DtcBit{dtc_test_failed_this_cycle, 'testFailedThisOperationCycle'},
	DtcBit{dtc_pending, 'pendingDTC'},
	DtcBit{dtc_confirmed, 'confirmedDTC'},
	DtcBit{dtc_not_completed_since_clear, 'testNotCompletedSinceLastClear'},
	DtcBit{dtc_failed_since_clear, 'testFailedSinceLastClear'},
	DtcBit{dtc_not_completed_this_cycle, 'testNotCompletedThisOperationCycle'},
	DtcBit{dtc_warning_indicator, 'warningIndicatorRequested'},
]

pub struct DtcBit {
pub:
	mask u8
	name string
}

// DtcRecord is one DTC as a server reported it: its 3-byte code and its status byte.
pub struct DtcRecord {
pub:
	code   u32 // 24 bits: the 2-byte DTC and its failure-type byte
	status u8
}

// has: the status carries every bit of `mask`.
pub fn (r DtcRecord) has(mask u8) bool {
	return r.status & mask == mask
}

// name is the SAE J2012 display of the code: the system letter (P/C/B/U) from its top two bits,
// four hex digits, and the failure-type byte — 0xC12100 is U0121-00.
pub fn (r DtcRecord) name() string {
	return dtc_name(r.code)
}

pub fn dtc_name(code u32) string {
	letter := [`P`, `C`, `B`, `U`][int((code >> 22) & 0x3)]
	return '${letter.str()}${(code >> 8) & 0x3FFF:04X}-${code & 0xFF:02X}'
}

// dtc_code parses a display name back (`U0121-00`, or `U0121` for failure type 00); none for
// anything else.
pub fn dtc_code(name string) ?u32 {
	if name.len != 5 && name.len != 8 {
		return none
	}
	sys := match name[0] {
		`P` { u32(0) }
		`C` { u32(1) }
		`B` { u32(2) }
		`U` { u32(3) }
		else { return none }
	}
	digits := name[1..5]
	if !digits.bytes().all(it.is_hex_digit()) || digits[0] > `3` {
		return none
	}
	mut ftb := u32(0)
	if name.len == 8 {
		if name[5] != `-` || !name[6..].bytes().all(it.is_hex_digit()) {
			return none
		}
		ftb = u32(('0x' + name[6..]).u64())
	}
	return sys << 22 | u32(('0x' + digits).u64()) << 8 | ftb
}

// status_names: the names of the bits set in `status`, low to high.
pub fn status_names(status u8) []string {
	return dtc_status_bits.filter(status & it.mask != 0).map(it.name)
}

pub fn (r DtcRecord) str() string {
	return '${r.name()} 0x${r.status:02X} [${status_names(r.status).join(', ')}]'
}

// DtcReport is a 0x19 02 or 0A answer: which status bits the server supports, and its DTCs.
pub struct DtcReport {
pub:
	availability u8
	records      []DtcRecord
}

// find is the record for `code`, if the report carries it.
pub fn (r DtcReport) find(code u32) ?DtcRecord {
	for rec in r.records {
		if rec.code == code {
			return rec
		}
	}
	return none
}

// DtcCount is a 0x19 01 answer.
pub struct DtcCount {
pub:
	availability u8
	format       u8 // DTCFormatIdentifier: 0x01 = ISO 14229-1
	count        int
}

// decode_dtc_list reads a positive 0x19 02 or 0x19 0A answer (59 <sub> <availability>
// {DTC high, middle, low, status}*).
pub fn decode_dtc_list(resp []u8) !DtcReport {
	if resp.len < 3 || resp[0] != 0x59 || (resp[1] != 0x02 && resp[1] != 0x0A) {
		return error('not a 0x19 02 / 0A answer: ${resp.hex()}')
	}
	if (resp.len - 3) % 4 != 0 {
		return error('0x19 ${resp[1]:02X} answer of ${resp.len} bytes is not a whole number of DTC records')
	}
	mut recs := []DtcRecord{cap: (resp.len - 3) / 4}
	for i := 3; i < resp.len; i += 4 {
		recs << DtcRecord{
			code:   u32(resp[i]) << 16 | u32(resp[i + 1]) << 8 | u32(resp[i + 2])
			status: resp[i + 3]
		}
	}
	return DtcReport{
		availability: resp[2]
		records:      recs
	}
}

// decode_dtc_count reads a positive 0x19 01 answer (59 01 <availability> <format> <count hi lo>).
pub fn decode_dtc_count(resp []u8) !DtcCount {
	if resp.len != 6 || resp[0] != 0x59 || resp[1] != 0x01 {
		return error('not a 0x19 01 answer: ${resp.hex()}')
	}
	return DtcCount{
		availability: resp[2]
		format:       resp[3]
		count:        int(u16(resp[4]) << 8 | u16(resp[5]))
	}
}

// dtc_count (0x19 01): how many DTCs have any of `mask`'s status bits.
pub fn (mut c Client) dtc_count(mask u8) !DtcCount {
	return decode_dtc_count(c.raw([sid_read_dtc_information, 0x01, mask])!)!
}

// dtcs (0x19 02): the DTCs with any of `mask`'s status bits.
pub fn (mut c Client) dtcs(mask u8) !DtcReport {
	return decode_dtc_list(c.raw([sid_read_dtc_information, 0x02, mask])!)!
}

// supported_dtcs (0x19 0A): every DTC the server supports, each with its whole status.
pub fn (mut c Client) supported_dtcs() !DtcReport {
	return decode_dtc_list(c.raw([sid_read_dtc_information, 0x0A])!)!
}
