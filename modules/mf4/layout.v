module mf4

import canlog
import encoding.binary
import math

// CgLayout is what one channel group's records look like: where each field sits, which kind
// of group it is, how its master time converts. Resolved ONCE per group and then applied per
// record by decode_row — the same body the in-memory loader and the stream decode with, so the
// two cannot disagree about a record.
struct CgLayout {
	remote       bool
	c_id         Chan
	c_db         Chan
	c_len        Chan
	len_is_bytes bool
	c_t          Chan
	c_ide        Chan
	c_bus        Chan
	c_dir        Chan
	c_edl        Chan
	c_brs        Chan
	c_esi        Chan
	data_bytes   int
	inval_bytes  int
	stride       int
	declared     u64 // cg_cycle_count: a cap when the file is finalized, stale when it is not
	is_vlsd      bool
	vlsd_link    u64 // cn_data of the DataBytes channel: an SD chain, or a VLSD group in an unsorted DG
	t_off        f64
	t_factor     f64
}

// resolve_layout reads a channel group's layout, or none when the group is not a CAN frame group
// this reader decodes (every reason parse_cg used to return early on).
fn resolve_layout(mut src ByteSource, cg u64) ?CgLayout {
	cgl := block_links(mut src, cg)
	cg_d := data_off(mut src, cg)
	declared := u64_at(mut src, cg_d + 8)
	data_bytes := int(u32_at(mut src, cg_d + 24))
	inval_bytes := int(u32_at(mut src, cg_d + 28))
	cn_first := if cgl.len > 1 { cgl[1] } else { u64(0) }

	// Collect leaf channels (recursing struct compositions like CAN_DataFrame).
	mut chans := []Chan{}
	collect_channels(mut src, cn_first, mut chans)
	// WHICH KIND of group. A recording carries CAN_RemoteFrame groups beside its CAN_DataFrame
	// ones, and every channel in them is named under that prefix instead — so the DataFrame
	// lookups all missed and the group was skipped in silence, taking its frames with it (#131).
	// Absent, not mislabelled: the trace's request/response split could never appear for an MF4
	// import while identical traffic from a candump showed it.
	//
	// One parser, parameterised, rather than a second one beside it: the identity, timing,
	// bus-channel, direction and invalidation handling are the same work, and a copy of that
	// much record striding is a copy that drifts.
	mut prefix := 'CAN_DataFrame'
	if _ := find_chan(chans, 'CAN_DataFrame.ID') {
		prefix = 'CAN_DataFrame'
	} else if _ := find_chan(chans, 'CAN_RemoteFrame.ID') {
		prefix = 'CAN_RemoteFrame'
	} else {
		return none
	}
	remote := prefix == 'CAN_RemoteFrame'
	c_id := find_chan(chans, '${prefix}.ID') or { return none }
	// A remote frame REQUESTS data and carries none, so it has no DataBytes channel and there is
	// nothing to require. Left empty rather than looked up: an absent Chan reads bit_count 0 and
	// byte_off 0, which the payload branches below must never be allowed to treat as a field —
	// see the `remote` branch, which never reaches them.
	c_db := if remote {
		Chan{}
	} else {
		find_chan(chans, 'CAN_DataFrame.DataBytes') or { return none }
	}
	// DLC FIRST on a remote group, and that order is the point. A remote frame states the length
	// it is ASKING for and carries no bytes, so a writer that emits both channels can perfectly
	// reasonably record DataLength as 0 — there is no payload for a byte count to describe —
	// while the requested length sits in DLC. Preferring DataLength there imports an `R8` as an
	// `R0` and replays it as one: a request for eight bytes turned into a request for none,
	// which the receiving ECU answers differently or not at all (codex #175 r1).
	//
	// The data path keeps the opposite preference for the opposite reason: there DataLength
	// states bytes outright while a DLC has to be decoded, and above 8 the two part company.
	c_len := if remote {
		find_chan(chans, 'CAN_RemoteFrame.DLC') or {
			find_chan(chans, 'CAN_RemoteFrame.DataLength') or { return none }
		}
	} else {
		find_chan(chans, 'CAN_DataFrame.DataLength') or {
			find_chan(chans, 'CAN_DataFrame.DLC') or { return none }
		}
	}
	// Whether that channel counts BYTES. DataLength does; DLC is the wire code, and above 8 the
	// two part company — a CAN-FD DLC of 15 means 64 bytes. Only the byte count can be compared
	// against a payload length, so a file carrying just DLC gets the ceiling check and not the
	// agreement check.
	len_is_bytes := c_len.name == '${prefix}.DataLength'
	// The time master is identified by cn_type==2, not its name (Vector calls it
	// 't', python-can 'time'); fall back to a 't' lookup just in case.
	c_t := find_master(chans) or { find_chan(chans, 't') or { Chan{} } }
	// Vector packs the IDE flag into ID bit 31; CANedge gives it its own 1-bit
	// channel (the 29-bit ID is masked to its declared bit count, so bit 31 is 0).
	c_ide := find_chan(chans, '${prefix}.IDE') or { Chan{} }
	// WHICH BUS. A recording carries several buses — each CAN_DataFrame group is one, and the
	// standard BusChannel field names it per record. Labelling every frame 'can' merged them:
	// 0x100 from CAN1 and 0x100 from CAN3 became one interleaved stream, and one row in the
	// grouped view whose count was two different messages added together.
	c_bus := find_chan(chans, '${prefix}.BusChannel') or { Chan{} }
	// DIRECTION, as the recording states it: 0 = the device received the frame, 1 = it
	// transmitted. It says what the RECORDER did, not what we would have done — in a foreign
	// capture a `tx` frame is that recorder's own traffic. Dropped until now; it is the only
	// provenance a file can carry, and a candump has none at all.
	c_dir := find_chan(chans, '${prefix}.Dir') or { Chan{} }
	// EDL — the CAN-FD flag, present only on groups that record FD. It is what makes a DLC above
	// 8 mean anything: without it, 9..15 could be 12..64 bytes or could be plain 8.
	c_edl := find_chan(chans, 'CAN_DataFrame.EDL') or { Chan{} }
	// BRS — the data phase ran at the faster rate. Recorded per frame alongside EDL.
	c_brs := find_chan(chans, 'CAN_DataFrame.BRS') or { Chan{} }
	// ESI — the transmitter was error-passive. A capture that recorded a degrading bus must not
	// replay as a healthy one, which is the whole reason the flag is carried at all.
	c_esi := find_chan(chans, 'CAN_DataFrame.ESI') or { Chan{} }

	stride := data_bytes + inval_bytes
	if stride <= 0 {
		return none
	}
	// Master-time scale: raw value (usually integer nanoseconds) -> seconds via a
	// linear CCBLOCK (t = off + factor*raw); identity if no conversion.
	t_off, t_factor := cc_linear(mut src, c_t.cc_link)
	return CgLayout{
		remote:       remote
		c_id:         c_id
		c_db:         c_db
		c_len:        c_len
		len_is_bytes: len_is_bytes
		c_t:          c_t
		c_ide:        c_ide
		c_bus:        c_bus
		c_dir:        c_dir
		c_edl:        c_edl
		c_brs:        c_brs
		c_esi:        c_esi
		data_bytes:   data_bytes
		inval_bytes:  inval_bytes
		stride:       stride
		declared:     declared
		// CAN-FD groups store DataBytes as VLSD: a separate signal-data block holding
		// length-prefixed entries, with each record carrying the byte offset into it.
		// Classic groups use MLSD: the payload is inline in the record (length =
		// DataLength). cn_type 1 = VLSD, 5 = MLSD.
		is_vlsd:   c_db.cn_type == 1
		vlsd_link: c_db.data_link
		t_off:     t_off
		t_factor:  t_factor
	}
}

// decode_row decodes the record at `base` in `raw` into a row, or none for a record this reader
// refuses (an undefined identity, a length it cannot trust, a bus the Log cannot name). ONE body
// for the in-memory loader and the stream. `vlsd` is the payload stream a VLSD group's records
// point into; `labels` and `log` name the bus.
fn decode_row(lay &CgLayout, raw []u8, base int, vlsd []u8, mut labels Labels, mut log canlog.Log) ?canlog.Row {
	c_id := lay.c_id
	c_db := lay.c_db
	c_len := lay.c_len
	c_t := lay.c_t
	c_ide := lay.c_ide
	c_bus := lay.c_bus
	c_dir := lay.c_dir
	c_edl := lay.c_edl
	c_brs := lay.c_brs
	c_esi := lay.c_esi
	data_bytes := lay.data_bytes
	inval_bytes := lay.inval_bytes
	remote := lay.remote
	len_is_bytes := lay.len_is_bytes
	is_vlsd := lay.is_vlsd
	if base + data_bytes > raw.len {
		return none
	}
	// IDENTITY FIRST, and a record whose identity is undefined is not a record. An MDF
	// invalidation flag — channel-wide or per record — says these bits mean nothing, and
	// reading them anyway produces a frame under a plausible id that the recording never
	// stated. Unlike an optional field, there is no degraded answer available: an id is not
	// something a frame can lack, and IDE decides whether the id is 11 or 29 bits, so an
	// undefined one changes which frame this is. Skipped rather than guessed, because these
	// entries are REPLAYED — a guess here puts traffic on a real bus that no recording ever
	// contained (codex #175 r2).
	//
	// Applies to data frames as much as to remote ones. The finding was raised against the
	// remote path this PR adds, but the read is shared, and the consequence — an invented
	// id, transmitted — does not become acceptable because the frame carries a payload.
	if chan_invalid(raw, base, data_bytes, inval_bytes, c_id) {
		return none
	}
	if c_ide.bit_count > 0 && chan_invalid(raw, base, data_bytes, inval_bytes, c_ide) {
		return none
	}
	rid := read_uint(raw, base + c_id.byte_off, int(c_id.bit_off), int(c_id.bit_count))
	ide := if c_ide.bit_count > 0 {
		read_uint(raw, base + c_ide.byte_off, int(c_ide.bit_off), int(c_ide.bit_count)) == 1
	} else {
		(rid >> 31) & 1 == 1
	}
	raw_t := if c_t.data_type == 4 || c_t.data_type == 5 {
		math.f64_from_bits(binary.little_endian_u64_at(raw, base + c_t.byte_off))
	} else if c_t.bit_count > 0 {
		f64(read_uint(raw, base + c_t.byte_off, int(c_t.bit_off), int(c_t.bit_count)))
	} else {
		0.0
	}
	ts := lay.t_off + lay.t_factor * raw_t
	mut data := []u8{}
	// Both payload lookups stay UNSIGNED. The offset and the two length fields are u32 on
	// the wire, and a corrupt one — 0xFFFFFFF0, or the unwritten filler an unfinalized
	// file's extended last block decodes as records — becomes NEGATIVE as a signed int.
	// The bounds tests then pass (a negative start is `<=` anything) and the slice runs off
	// the front of the array, which aborts the process instead of skipping one bad record.
	// A malformed file must cost its frame, not the measurement.
	if remote {
		// A remote frame carries NO bytes; it names the DLC it is requesting. The live
		// representation of that is a zero-filled payload of the requested length — what
		// SocketCAN hands a receiver, and exactly what modules/canlog builds from a
		// candump `200#R8`. Matching it is the point: the same traffic imported from the
		// two formats must produce the same frame, or the trace's request/response split
		// depends on which file it was read from.
		//
		// CLASSIC ONLY, so the DLC is decoded with fd=false. CAN-FD has no remote frames at
		// all — the RTR bit is what FD reused for its own signalling — so an FD reading of
		// codes 9..15 would invent a 64-byte request that cannot exist. A code that still
		// resolves above 8 is refused rather than clamped, on the same reasoning the two
		// payload branches below already apply to a length they cannot trust.
		// INVALIDATION FIRST. An MDF record can mark a channel's value undefined, and the
		// bits then hold whatever the writer left there. Read regardless, stale bits become
		// a plausible request length and the frame replays asking for bytes the recording
		// never said were asked for — the other optional fields in this parser all consult
		// chan_invalid for exactly this, and a length has more consequence than most
		// (codex #175 r1).
		// SKIPPED when the length is unknown, not emitted empty. For a data frame an absent
		// payload is a frame we can still place on the bus honestly; for a remote frame the
		// DLC IS the message — `R0` and `R8` are different requests, and an ECU answers them
		// differently or not at all. So leaving `data` empty here does not withhold a
		// doubtful detail, it states a specific request the recording never made, and these
		// entries are replayed onto real buses. The first version of this branch did exactly
		// that: it turned a stale R8 into an invented R0 and called it caution (codex
		// #175 r2).
		//
		// Three ways the length can be unknown, one answer: the record says the channel is
		// invalid, the code is not a four-bit DLC at all, or it resolves above 8 — which no
		// classic remote frame can request, and CAN-FD has none to reinterpret it as.
		if chan_invalid(raw, base, data_bytes, inval_bytes, c_len) {
			return none
		}
		stated := read_uint(raw, base + c_len.byte_off, int(c_len.bit_off), int(c_len.bit_count))
		// Whichever channel was chosen above: a DataLength states bytes outright, a DLC is a
		// code to decode. Deciding by name rather than assuming DLC keeps the fallback honest
		// for a writer that records only DataLength.
		resolved := if len_is_bytes { ?u64(stated) } else { dlc_bytes(stated, false) }
		n := resolved or { return none }
		if n > 8 {
			return none
		}
		data = []u8{len: int(n)}
	} else if is_vlsd {
		off := read_uint(raw, base + c_db.byte_off, int(c_db.bit_off), int(c_db.bit_count))
		// SUBTRACTION, never `off + 4`: the offset field's width is declared by the file, and
		// a 64-bit one holding 0xFFFF_FFFF_FFFF_FFFF makes `off + 4` wrap to 3. The bounds
		// test would pass on the wrapped value and int(off) would go negative — the same
		// abort as reading it signed, arrived at from the other end.
		if u64(vlsd.len) >= 4 && off <= u64(vlsd.len) - 4 {
			n := u64(binary.little_endian_u32_at(vlsd, int(off)))
			end := off + 4 + n // no overflow: off is within the block and n is a u32
			// The length prefix is checked against what the RECORD says, not just against
			// the block's bounds. A damaged prefix that still lands inside the block would
			// otherwise swallow the next entry's prefix and hand back a frame with bytes
			// that were never its own — inventing payload is worse than dropping it, because
			// nothing downstream can tell that it happened.
			stated := read_uint(raw, base + c_len.byte_off, int(c_len.bit_off),
				int(c_len.bit_count))
			// What the record says the length is — DataLength states it outright, a DLC has
			// to be decoded, and a DLC above 8 without EDL states nothing decidable at all.
			// `none` means the record cannot contradict the prefix, so only the ceiling and
			// the block's bounds apply. It is not a licence to accept anything.
			expect := if len_is_bytes {
				?u64(stated)
			} else {
				fd := c_edl.bit_count > 0
					&& read_uint(raw, base + c_edl.byte_off, int(c_edl.bit_off), int(c_edl.bit_count)) == 1
				dlc_bytes(stated, fd)
			}
			// `none` is NOT permission. It means the record states no resolvable length —
			// a DLC outside 0..15 — and accepting the prefix on that basis replays a
			// payload whose only corroboration is the damaged field itself. The inline
			// branch refuses the identical doubt; these two must not disagree.
			agrees := if want := expect { n == want } else { false }
			if n <= max_can_payload && end <= u64(vlsd.len) && agrees {
				data = vlsd[int(off) + 4..int(end)] // copied into the row below, never kept
			}
		}
	} else {
		stated := read_uint(raw, base + c_len.byte_off, int(c_len.bit_off), int(c_len.bit_count))
		// A DLC is a CODE. Without decoding it, a classic frame carrying DLC 9..15 (legal,
		// and meaning 8 bytes) reads as a length of 9..15, overruns the record's DataBytes
		// field and yields NO payload — a regression the byte-count path never sees because
		// DataLength already states bytes.
		fd_here := c_edl.bit_count > 0 && !chan_invalid(raw, base, data_bytes, inval_bytes, c_edl)
			&& read_uint(raw, base + c_edl.byte_off, int(c_edl.bit_off), int(c_edl.bit_count)) == 1
		// A DLC the format cannot resolve (out of range in a damaged record) means the
		// length is UNKNOWN. Falling back to 8 accepted the first eight bytes of the field
		// as a frame — inventing a payload from a record that says nothing trustworthy.
		// Refused instead, which is what the VLSD branch does with the same doubt.
		resolved := if len_is_bytes { ?u64(stated) } else { dlc_bytes(stated, fd_here) }
		n := resolved or { u64(0) }
		usable := resolved != none
		dstart := u64(base + c_db.byte_off)
		// The DataBytes FIELD, not the whole record: bounding by the record would let a
		// damaged length run into whatever channel is stored after the payload and return
		// those bytes as though a frame had carried them.
		field := if c_db.bit_count > 0 { u64(c_db.bit_count / 8) } else { u64(data_bytes) }
		mut limit := dstart + field
		if limit > u64(base + data_bytes) {
			limit = u64(base + data_bytes)
		}
		// REFUSED, not clamped. A length that overruns the record is a length we cannot
		// trust, and trimming it to the record boundary returns whatever the inline
		// DataBytes array was padded with — or the channel stored after it — as though a
		// frame had carried those bytes. A well-formed record never reaches this: its
		// payload fits by construction. Inventing bytes is worse than reporting none,
		// because only one of the two is visible downstream.
		if usable && n <= max_can_payload && dstart <= limit && n <= limit - dstart {
			data = raw[int(dstart)..int(dstart + n)] // copied into the row below, never kept
		}
	}
	bus_no := if c_bus.bit_count > 0 && !chan_invalid(raw, base, data_bytes, inval_bytes, c_bus) {
		int(read_uint(raw, base + c_bus.byte_off, int(c_bus.bit_off), int(c_bus.bit_count)))
	} else {
		-1 // absent, or this record says the field is not defined: fall back to the group
	}
	dir := if c_dir.bit_count > 0 && !chan_invalid(raw, base, data_bytes, inval_bytes, c_dir) {
		if read_uint(raw, base + c_dir.byte_off, int(c_dir.bit_off), int(c_dir.bit_count)) == 1 {
			canlog.Dir.tx
		} else {
			canlog.Dir.rx
		}
	} else {
		canlog.Dir.unknown // absent, or this record says the field is not defined
	}
	// CAN-FD, as the recording states it. EDL is the flag; a payload over 8 bytes is FD by
	// construction whatever the flag says, and trusting only the flag would hand a 64-byte
	// payload to a classic frame that cannot express it.
	// …and never on a remote group. CAN-FD has no remote frames — FD reused the RTR bit —
	// so an EDL channel cannot be present there, and a zero-filled request is at most 8
	// bytes by the branch above. Stated rather than left to those two facts holding: the
	// pair `fd` and `rtr` describes a frame that does not exist on any wire.
	is_fd := !remote && (data.len > 8 || (c_edl.bit_count > 0
		&& !chan_invalid(raw, base, data_bytes, inval_bytes, c_edl)
		&& read_uint(raw, base + c_edl.byte_off, int(c_edl.bit_off), int(c_edl.bit_count)) == 1))
	brs := is_fd && c_brs.bit_count > 0 && !chan_invalid(raw, base, data_bytes, inval_bytes, c_brs)
		&& read_uint(raw, base + c_brs.byte_off, int(c_brs.bit_off), int(c_brs.bit_count)) == 1
	esi := is_fd && c_esi.bit_count > 0 && !chan_invalid(raw, base, data_bytes, inval_bytes, c_esi)
		&& read_uint(raw, base + c_esi.byte_off, int(c_esi.bit_off), int(c_esi.bit_count)) == 1
	// The bus BEFORE anything is committed: a record whose bus the Log cannot name is refused
	// whole, and a refused record leaves no ordinal behind (the note on rec_idx in parse_cg).
	bus := labels.label(bus_no, mut log) or { return none }
	// Into the ARENA (canlog.Log): a pointer-free row per frame, the payload copied into
	// the row rather than cloned beside it, the bus named by index. This is where the
	// recording's memory is decided, and where a collection's LENGTH was decided with it.
	mut row := canlog.Row{
		t_s:   ts
		id:    u32(rid) & 0x1FFFFFFF
		len:   u8(data.len)
		flags: canlog.pack_flags(ide, remote, is_fd, brs, esi, dir)
		bus:   bus
	}
	if data.len > 0 {
		unsafe { vmemcpy(&row.data[0], data.data, data.len) }
	}
	return row
}
