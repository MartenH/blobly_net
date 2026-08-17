// Native-V reader for ASAM MDF4 (.mf4) CAN bus-logging files — no Python/asammdf.
//
// Targets the common automotive case: ASAM MDF exports (MDF 4.x),
// where each bus is a "CAN_DataFrame" channel group. Handles DZ-compressed data
// blocks (zlib deflate, incl. zip_type 1 byte-transposition), DL/HL data lists,
// and both payload layouts a CAN_DataFrame group can use:
//   * MLSD (Maximum Length Signal Data) — DataBytes live inline in each record,
//     their length given by DataLength; nothing else to chase.
//   * VLSD (Variable Length Signal Data) — the record holds only a byte OFFSET,
//     and the payloads live length-prefixed in a signal-data block (##SD, often
//     reached through an HL/DL list of DZ-compressed ones). This is what Vector
//     writes for CAN-FD, where the payload length genuinely varies per frame.
//
// Also reads **unfinalized** MDF ("UnFinMF " id, CANedge loggers power off
// without finalizing): the stale cg_cycle_count is ignored (counts derive from
// the data length) and a truncated/understated last DT block is clamped or
// extended to the end of the file. **Unsorted** data groups (several channel
// groups interleaved in one DT, each record prefixed by its record id — how
// CANedge mixes CAN_DataFrame with error/remote-frame groups) are demuxed
// before decoding; VLSD channel groups inside an unsorted DT are skipped while
// stepping (classic-CAN payloads are inline).
//
// GUI-free + pure V (see CLAUDE.md module convention). Returns canlog.LogEntry so
// it plugs straight into the existing log/replay path. Validated frame-for-frame
// against asammdf on a real 62k-frame J1939 recording.
//
// MDF4 block layout reference (all little-endian): every block starts with a
// common header — id[4] "##XX", reserved[4], u64 length, u64 link_count N,
// then N u64 links, then a type-specific data section.
module mf4

import os
import compress.zlib
import encoding.binary
import math
import transport
import canlog

// A CAN or CAN-FD frame carries at most 64 payload bytes, whatever a damaged length field in
// the file claims. The ceiling holds for every writer, so it applies even where there is nothing
// to cross-check the length against.
const max_can_payload = u64(64)

// dlc_bytes converts a CAN-FD DLC code to its payload length, or none when the code cannot be
// resolved to one number. Codes 0..8 are the length itself. Above 8 the answer depends on the
// frame: CAN-FD reads 9..15 as 12/16/20/24/32/48/64, while CLASSIC CAN allows the same codes and
// means 8 for every one of them. So a DLC over 8 is only decidable with the EDL flag in hand —
// and guessing FD there would reject perfectly good classic frames whose writer set DLC 15.
fn dlc_bytes(dlc u64, fd bool) ?u64 {
	// A DLC is a FOUR-BIT code. Anything above 15 did not come off a wire — it is a damaged
	// record, and the honest answer is that the length is unknown rather than a plausible 8.
	if dlc > 15 {
		return none
	}
	if dlc <= 8 {
		return dlc
	}
	if !fd {
		return u64(8) // classic CAN: codes 9..15 all mean 8 bytes
	}
	return match dlc {
		9 { u64(12) }
		10 { u64(16) }
		11 { u64(20) }
		12 { u64(24) }
		13 { u64(32) }
		14 { u64(48) }
		15 { u64(64) }
		else { none }
	}
}

// load_file parses an .mf4 file and returns its CAN frames as canlog entries,
// sorted by timestamp (each bus group is internally time-sorted; merging many
// groups needs the final sort). Errors on I/O or a non-MDF file.
pub fn load_file(path string) ![]canlog.LogEntry {
	buf := os.read_bytes(path)!
	return parse(buf)!
}

// BusInfo is one bus of a recording: the label its frames actually carry, and the name the FILE
// gives it. They are different things and neither replaces the other. The label is what entries
// are tagged with and what a caller filters on; the name is `cg_tx_acq_name`, free text the
// writer chose ('CAN1', 'CAN12'), which is how a person recognises the bus but is not unique,
// not guaranteed present, and — as these recordings show — not necessarily the name of the
// database that decodes it. Offered so a caller can let somebody pick a bus by the name they
// know, without that name ever becoming an identity.
pub struct BusInfo {
pub:
	iface  string // the label on every entry from this bus, e.g. 'mf4:group25'
	name   string // the recording's own name for it; '' when the file gives none
	frames int
}

// Recording is a parsed file: its frames, and what buses they came from.
pub struct Recording {
pub:
	entries []canlog.LogEntry
	buses   []BusInfo
}

// load_recording parses a file and also reports its buses. Same work as load_file — the bus
// list is a by-product of the one walk, not a second pass, so the two cannot disagree.
pub fn load_recording(path string) !Recording {
	buf := os.read_bytes(path)!
	return parse_recording(buf)!
}

// parse reads an in-memory MDF4 image. Split out from load_file so callers/tests
// can feed bytes directly.
pub fn parse(buf []u8) ![]canlog.LogEntry {
	return parse_recording(buf)!.entries
}

// tally_buses attributes a slice of freshly decoded entries to their bus labels, carrying the
// channel group's acquisition name along. A group that produced SEVERAL labels (records carrying
// their own BusChannel) keeps the name only where it is unambiguous: one name covering two buses
// would be a label pretending to be an identity.
fn tally_buses(entries []canlog.LogEntry, acq string, mut names map[string]string, mut counts map[string]int) {
	for e in entries {
		counts[e.iface]++
		if existing := names[e.iface] {
			if existing != acq {
				names[e.iface] = '' // two different names for one label: trust neither
			}
		} else {
			names[e.iface] = acq
		}
	}
}

fn parse_recording(buf []u8) !Recording {
	if buf.len < 64 {
		return error('not an MDF file (bad id block)')
	}
	magic := buf[0..8].bytestr()
	unfin := magic.starts_with('UnFinMF')
	if !magic.starts_with('MDF') && !unfin {
		return error('not an MDF file (bad id block)')
	}
	mut out := []canlog.LogEntry{}
	// HDBLOCK is at the fixed offset 64; its first link is the first DGBLOCK.
	hd := block_links(buf, 64)
	mut dg := if hd.len > 0 { hd[0] } else { u64(0) }
	mut group := 0 // ordinal of the CAN_DataFrame group, for files without a BusChannel
	mut bus_names := map[string]string{}
	mut bus_counts := map[string]int{}
	for dg != 0 {
		dgl := block_links(buf, dg)
		dg_data_off := data_off(buf, dg)
		rec_id_size := buf[dg_data_off]
		cg_first := if dgl.len > 1 { dgl[1] } else { u64(0) }
		data_link := if dgl.len > 2 { dgl[2] } else { u64(0) }
		if cg_first != 0 {
			raw := read_data_block(buf, data_link, unfin)!
			start := out.len
			if rec_id_size == 0 {
				// Sorted: one CG per DG, the data block is its record stream.
				parse_cg(buf, cg_first, raw, unfin, map[u64][]u8{}, group, mut out)!
				group++
				// cg_tx_acq_name is link 2. Read AFTER the decode and only over the entries it
				// produced, so the name follows the frames rather than being guessed at.
				cgl := block_links(buf, cg_first)
				acq := read_tx(buf, if cgl.len > 2 { cgl[2] } else { u64(0) })
				tally_buses(out[start..], acq, mut bus_names, mut bus_counts)
			} else {
				// Tallied per channel group inside, since each has its own acquisition name.
				group = demux_unsorted(buf, cg_first, raw, int(rec_id_size), unfin, group, mut
					out, mut bus_names, mut bus_counts)!
			}
		}
		dg = if dgl.len > 0 { dgl[0] } else { u64(0) }
	}
	out.sort(a.t_s < b.t_s)
	// A name that covers SEVERAL labels is not a name for any of them. One channel group whose
	// records carry their own BusChannel produces two buses under one acquisition name, and
	// handing that name to both would let a caller ask for a bus the file cannot single out —
	// the label pretending to be an identity, which is the thing bus_iface exists to prevent.
	mut labels_per_name := map[string]int{}
	for _, nm in bus_names {
		if nm != '' {
			labels_per_name[nm]++
		}
	}
	mut buses := []BusInfo{}
	for iface, n in bus_counts {
		nm := bus_names[iface] or { '' }
		buses << BusInfo{
			iface:  iface
			name:   if labels_per_name[nm] > 1 { '' } else { nm }
			frames: n
		}
	}
	buses.sort(a.iface < b.iface)
	return Recording{
		entries: out
		buses:   buses
	}
}

// CgInfo is one channel group's demux key in an unsorted data group.
struct CgInfo {
	link   u64
	rec_id u64
	vlsd   bool // cg_flags bit 0: variable-length records (4-byte size prefix)
	size   int  // fixed record size (data + invalidation bytes)
}

// demux_unsorted splits an unsorted DG's record stream (records from several
// CGs interleaved, each prefixed by its record id) into per-CG streams, then
// decodes each fixed-length CG. A VLSD group's records (u32 length + bytes)
// are concatenated VERBATIM into a stream keyed by the CG's block address:
// other groups' VLSD channels carry byte offsets into exactly that
// concatenation, and their cn_data link names the VLSD CG block (this is how
// CANedge stores classic-CAN DataBytes).
// Returns the next free group ordinal, so numbering stays unique across data groups.
fn demux_unsorted(buf []u8, cg_first u64, raw []u8, rec_id_size int, unfin bool, group int,
	mut out []canlog.LogEntry, mut names map[string]string, mut counts map[string]int) !int {
	mut cgs := []CgInfo{}
	mut cgi := cg_first
	for cgi != 0 {
		cgd := data_off(buf, cgi)
		cgs << CgInfo{
			link:   cgi
			rec_id: binary.little_endian_u64_at(buf, cgd)
			vlsd:   binary.little_endian_u16_at(buf, cgd + 16) & 1 == 1
			size:   int(binary.little_endian_u32_at(buf, cgd + 24)) +
				int(binary.little_endian_u32_at(buf, cgd + 28))
		}
		l := block_links(buf, cgi)
		cgi = if l.len > 0 { l[0] } else { u64(0) }
	}
	mut streams := map[u64][]u8{} // fixed-length CGs, keyed by record id
	mut vlsd_streams := map[u64][]u8{} // VLSD CGs, keyed by CG block address
	mut pos := 0
	outer: for pos + rec_id_size <= raw.len {
		rid := read_uint(raw, pos, 0, rec_id_size * 8)
		pos += rec_id_size
		mut found := false
		for c in cgs {
			if c.rec_id != rid {
				continue
			}
			found = true
			if c.vlsd {
				if pos + 4 > raw.len {
					break outer
				}
				n := int(binary.little_endian_u32_at(raw, pos))
				if pos + 4 + n > raw.len {
					break outer
				}
				vlsd_streams[c.link] << raw[pos..pos + 4 + n] // keep the length prefix
				pos += 4 + n
			} else {
				if pos + c.size > raw.len {
					break outer
				}
				streams[c.rec_id] << raw[pos..pos + c.size]
				pos += c.size
			}
			break
		}
		if !found {
			break // unknown record id — corrupt tail (common in unfinalized files)
		}
	}
	mut g := group
	for c in cgs {
		if !c.vlsd {
			start := out.len
			parse_cg(buf, c.link, streams[c.rec_id] or { []u8{} }, unfin, vlsd_streams, g, mut
				out)!
			g++
			// Each channel group here has its OWN cg_tx_acq_name — sharing a record stream is a
			// storage detail, not a reason to leave every bus in the file unnamed.
			cgl := block_links(buf, c.link)
			tally_buses(out[start..], read_tx(buf, if cgl.len > 2 { cgl[2] } else { u64(0) }), mut
				names, mut counts)
		}
	}
	return g
}

// chan holds the record-layout facts we need for one leaf channel.
struct Chan {
	name      string
	cn_type   u8    // 0=fixed, 1=VLSD, 2=master, 5=MLSD (max-length inline)
	data_type u8    // 0/1=uint LE/BE, 2/3=int, 4/5=float LE/BE
	byte_off  int   // offset of the field within a record
	bit_off   u8    // bit offset within that byte (CANedge bit-packs channels)
	bit_count u32
	data_link u64   // cn_data: VLSD signal-data block (type 1) or length channel (type 5)
	cc_link   u64   // cn_cc_conversion (CCBLOCK), for the master-time scale
	// cn_flags bit 0 = EVERY sample of this channel is invalid; bit 1 = it has a per-record
	// invalidation bit, whose position in the record's invalidation area is cn_inval_bit_pos.
	// Either way the raw bits are undefined where the flag applies — reading them anyway
	// invents a value.
	flags     u32
	inval_bit u32
}

// `group` distinguishes this channel group from the file's others when the records carry no
// BusChannel of their own — better a stable synthetic name per group than one shared label.
fn parse_cg(buf []u8, cg u64, recs []u8, unfin bool, vlsd_streams map[u64][]u8, group int,
	mut out []canlog.LogEntry) ! {
	cgl := block_links(buf, cg)
	cg_d := data_off(buf, cg)
	declared := binary.little_endian_u64_at(buf, cg_d + 8)
	data_bytes := int(binary.little_endian_u32_at(buf, cg_d + 24))
	inval_bytes := int(binary.little_endian_u32_at(buf, cg_d + 28))
	cn_first := if cgl.len > 1 { cgl[1] } else { u64(0) }

	// Collect leaf channels (recursing struct compositions like CAN_DataFrame).
	mut chans := []Chan{}
	collect_channels(buf, cn_first, mut chans)
	c_id := find_chan(chans, 'CAN_DataFrame.ID') or { return }
	c_db := find_chan(chans, 'CAN_DataFrame.DataBytes') or { return }
	c_len := find_chan(chans, 'CAN_DataFrame.DataLength') or {
		find_chan(chans, 'CAN_DataFrame.DLC') or { return }
	}
	// Whether that channel counts BYTES. DataLength does; DLC is the wire code, and above 8 the
	// two part company — a CAN-FD DLC of 15 means 64 bytes. Only the byte count can be compared
	// against a payload length, so a file carrying just DLC gets the ceiling check and not the
	// agreement check.
	len_is_bytes := c_len.name == 'CAN_DataFrame.DataLength'
	// The time master is identified by cn_type==2, not its name (Vector calls it
	// 't', python-can 'time'); fall back to a 't' lookup just in case.
	c_t := find_master(chans) or { find_chan(chans, 't') or { Chan{} } }
	// Vector packs the IDE flag into ID bit 31; CANedge gives it its own 1-bit
	// channel (the 29-bit ID is masked to its declared bit count, so bit 31 is 0).
	c_ide := find_chan(chans, 'CAN_DataFrame.IDE') or { Chan{} }
	// WHICH BUS. A recording carries several buses — each CAN_DataFrame group is one, and the
	// standard BusChannel field names it per record. Labelling every frame 'can' merged them:
	// 0x100 from CAN1 and 0x100 from CAN3 became one interleaved stream, and one row in the
	// grouped view whose count was two different messages added together.
	c_bus := find_chan(chans, 'CAN_DataFrame.BusChannel') or { Chan{} }
	// DIRECTION, as the recording states it: 0 = the device received the frame, 1 = it
	// transmitted. It says what the RECORDER did, not what we would have done — in a foreign
	// capture a `tx` frame is that recorder's own traffic. Dropped until now; it is the only
	// provenance a file can carry, and a candump has none at all.
	c_dir := find_chan(chans, 'CAN_DataFrame.Dir') or { Chan{} }
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
		return
	}
	// Record count: the data length is ground truth; the declared cg_cycle_count
	// is a sanity cap only when the file is finalized (it is stale in unfinalized
	// files, and a sorted DT may carry trailing slack we must not decode).
	mut cycles := u64(recs.len / stride)
	if !unfin && declared > 0 && declared < cycles {
		cycles = declared
	}
	// CAN-FD groups store DataBytes as VLSD: a separate signal-data block holding
	// length-prefixed entries, with each record carrying the byte offset into it.
	// Classic groups use MLSD: the payload is inline in the record (length =
	// DataLength). cn_type 1 = VLSD, 5 = MLSD.
	is_vlsd := c_db.cn_type == 1
	// VLSD source: in a sorted file cn_data links an SD/DZ block; in an unsorted
	// one it names the VLSD channel GROUP, whose records were concatenated into
	// vlsd_streams during demux.
	vlsd := if !is_vlsd {
		[]u8{}
	} else if c_db.data_link in vlsd_streams {
		vlsd_streams[c_db.data_link] or { []u8{} }
	} else {
		read_data_block(buf, c_db.data_link, unfin)!
	}
	// Master-time scale: raw value (usually integer nanoseconds) -> seconds via a
	// linear CCBLOCK (t = off + factor*raw); identity if no conversion.
	t_off, t_factor := cc_linear(buf, c_t.cc_link)
	raw := recs
	for k := u64(0); k < cycles; k++ {
		base := int(k) * stride
		if base + data_bytes > raw.len {
			break
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
		ts := t_off + t_factor * raw_t
		mut data := []u8{}
		// Both payload lookups stay UNSIGNED. The offset and the two length fields are u32 on
		// the wire, and a corrupt one — 0xFFFFFFF0, or the unwritten filler an unfinalized
		// file's extended last block decodes as records — becomes NEGATIVE as a signed int.
		// The bounds tests then pass (a negative start is `<=` anything) and the slice runs off
		// the front of the array, which aborts the process instead of skipping one bad record.
		// A malformed file must cost its frame, not the measurement.
		if is_vlsd {
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
					fd := c_edl.bit_count > 0 && read_uint(raw, base + c_edl.byte_off, int(c_edl.bit_off),
						int(c_edl.bit_count)) == 1
					dlc_bytes(stated, fd)
				}
				// `none` is NOT permission. It means the record states no resolvable length —
				// a DLC outside 0..15 — and accepting the prefix on that basis replays a
				// payload whose only corroboration is the damaged field itself. The inline
				// branch refuses the identical doubt; these two must not disagree.
				agrees := if want := expect { n == want } else { false }
				if n <= max_can_payload && end <= u64(vlsd.len) && agrees {
					data = vlsd[int(off) + 4..int(end)].clone()
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
				data = raw[int(dstart)..int(dstart + n)].clone()
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
		is_fd := data.len > 8 || (c_edl.bit_count > 0
			&& !chan_invalid(raw, base, data_bytes, inval_bytes, c_edl)
			&& read_uint(raw, base + c_edl.byte_off, int(c_edl.bit_off), int(c_edl.bit_count)) == 1)
		brs := is_fd && c_brs.bit_count > 0
			&& !chan_invalid(raw, base, data_bytes, inval_bytes, c_brs)
			&& read_uint(raw, base + c_brs.byte_off, int(c_brs.bit_off), int(c_brs.bit_count)) == 1
		esi := is_fd && c_esi.bit_count > 0
			&& !chan_invalid(raw, base, data_bytes, inval_bytes, c_esi)
			&& read_uint(raw, base + c_esi.byte_off, int(c_esi.bit_off), int(c_esi.bit_count)) == 1
		out << canlog.LogEntry{
			t_s:   ts
			dir:   dir
			iface: bus_iface(bus_no, group)
			frame: transport.CanFrame{
				id:       u32(rid) & 0x1FFFFFFF
				extended: ide
				fd:       is_fd
				brs:      brs
				esi:      esi
				data:     data
			}
		}
	}
}

// bus_iface names the bus a frame came from — as the FILE states it, not as we would prefer it.
// The number is BusChannel verbatim: writers disagree about whether it counts from 0 (python-can)
// or 1 (Vector, CANedge), and there is nothing in the file that says which. Re-basing it would be
// a guess presented as a fact — the exact habit that made everything 'can' in the first place.
// What matters here is that two buses stay two buses.
//
// Without a BusChannel, the channel group's position is the only distinction the file offers.
//
// NAMESPACED, for the same reason the number is left alone. A recording's bus numbers are not
// this project's interface names, and a bare `can1` would match a project channel called can1
// exactly — the imported frames would silently adopt that channel's protection rules, and a
// Vector file (1-based) would hand bus #1's frames the verdicts meant for the second bus. `mf4:`
// cannot collide, so an imported label stays unresolved unless the project has exactly one bus
// to resolve it to. The two sources stay apart too: `bus` is what the file recorded, `group` is
// only this decoder's ordinal for a group carrying no BusChannel — one name for both would merge
// a BusChannel-less group 1 with another group's BusChannel 1, the same collapse one level down.
fn bus_iface(bus_no int, group int) string {
	if bus_no >= 0 {
		return 'mf4:bus${bus_no}'
	}
	return 'mf4:group${group}'
}

// collect_channels walks a cn_next chain, recursing into struct compositions
// (cn_composition), accumulating every leaf channel's record-layout facts.
fn collect_channels(buf []u8, cn_first u64, mut chans []Chan) {
	mut cn := cn_first
	for cn != 0 {
		cnl := block_links(buf, cn)
		d := data_off(buf, cn)
		name := read_tx(buf, if cnl.len > 2 { cnl[2] } else { u64(0) })
		chans << Chan{
			name:      name
			cn_type:   buf[d + 0]
			data_type: buf[d + 2]
			bit_off:   buf[d + 3] // cn_bit_offset
			byte_off:  int(binary.little_endian_u32_at(buf, d + 4))
			bit_count: binary.little_endian_u32_at(buf, d + 8)
			data_link: if cnl.len > 5 { cnl[5] } else { u64(0) }
			cc_link:   if cnl.len > 4 { cnl[4] } else { u64(0) }
			flags:     binary.little_endian_u32_at(buf, d + 12)
			inval_bit: binary.little_endian_u32_at(buf, d + 16)
		}
		comp := if cnl.len > 1 { cnl[1] } else { u64(0) }
		if comp != 0 && block_id(buf, comp) == '##CN' {
			collect_channels(buf, comp, mut chans)
		}
		cn = if cnl.len > 0 { cnl[0] } else { u64(0) }
	}
}

// chan_invalid reports whether this record marks the channel invalid. The invalidation area sits
// after the data bytes of each record, one bit per flagged channel; a SET bit means the value is
// not defined. Without this check a stale or zero BusChannel reads as a real bus number, which
// either merges those frames into a genuine mf4:busN stream or invents a bus that never existed.
fn chan_invalid(raw []u8, base int, data_bytes int, inval_bytes int, c Chan) bool {
	if c.flags & 0x01 != 0 {
		return true // channel-wide: EVERY sample is invalid, so there is no per-record bit to read
	}
	if c.flags & 0x02 == 0 || inval_bytes == 0 {
		return false // no invalidation bit for this channel
	}
	byte_i := base + data_bytes + int(c.inval_bit / 8)
	if byte_i >= raw.len || int(c.inval_bit / 8) >= inval_bytes {
		return false // malformed: treat as valid rather than dropping the whole record
	}
	return raw[byte_i] & (u8(1) << u8(c.inval_bit % 8)) != 0
}

// cc_linear returns (offset, factor) of a linear CCBLOCK (cc_type 1), so that
// physical = offset + factor*raw. Defaults to (0, 1) when there is no conversion
// or it isn't linear (the master time channel here is linear ns->s).
fn cc_linear(buf []u8, cc u64) (f64, f64) {
	if cc == 0 || block_id(buf, cc) != '##CC' {
		return 0.0, 1.0
	}
	d := data_off(buf, cc)
	cc_type := buf[d + 0]
	val_count := int(binary.little_endian_u16_at(buf, d + 6))
	if cc_type != 1 || val_count < 2 {
		return 0.0, 1.0
	}
	off := math.f64_from_bits(binary.little_endian_u64_at(buf, d + 24))
	factor := math.f64_from_bits(binary.little_endian_u64_at(buf, d + 24 + 8))
	return off, factor
}

fn find_chan(chans []Chan, name string) ?Chan {
	for c in chans {
		if c.name == name {
			return c
		}
	}
	return none
}

// find_master returns the channel-group's time master (cn_type 2).
fn find_master(chans []Chan) ?Chan {
	for c in chans {
		if c.cn_type == 2 {
			return c
		}
	}
	return none
}

// read_uint reads a little-endian unsigned integer of `bits` bits starting at
// byte `off`, bit `bit_off` (Vector files keep fields byte-aligned; CANedge
// bit-packs, e.g. a 29-bit ID at bit offset 0 followed by 1-bit flags).
fn read_uint(b []u8, off int, bit_off int, bits int) u64 {
	nbytes := (bit_off + bits + 7) / 8
	mut v := u64(0)
	for i := 0; i < nbytes && off + i < b.len; i++ {
		v |= u64(b[off + i]) << (8 * i)
	}
	v >>= bit_off
	if bits < 64 {
		v &= (u64(1) << bits) - 1
	}
	return v
}

// ---- block helpers ----

fn block_id(buf []u8, off u64) string {
	return buf[off..off + 4].bytestr()
}

// block_links returns a block's link array (N u64 links after the common header).
fn block_links(buf []u8, off u64) []u64 {
	n := int(binary.little_endian_u64_at(buf, int(off) + 16))
	mut links := []u64{cap: n}
	for i := 0; i < n; i++ {
		links << binary.little_endian_u64_at(buf, int(off) + 24 + 8 * i)
	}
	return links
}

// data_off returns the byte offset of a block's type-specific data section.
fn data_off(buf []u8, off u64) int {
	n := int(binary.little_endian_u64_at(buf, int(off) + 16))
	return int(off) + 24 + 8 * n
}

// read_tx returns the UTF-8 text of a TX/MD block (null-terminated), or '' .
fn read_tx(buf []u8, link u64) string {
	if link == 0 {
		return ''
	}
	id := block_id(buf, link)
	if id != '##TX' && id != '##MD' {
		return ''
	}
	d := data_off(buf, link)
	mut e := d
	for e < buf.len && buf[e] != 0 {
		e++
	}
	return buf[d..e].bytestr()
}

// read_data_block resolves a DGBLOCK data link to its raw record bytes, handling
// uncompressed (DT/DV/DI/RD), compressed (DZ), and list (DL/HL) blocks. In an
// unfinalized file the LAST DT block's declared length is stale (the logger
// died before updating it) — when nothing but file-end follows the declared
// end, the block really extends to the end of the file.
fn read_data_block(buf []u8, link u64, unfin bool) ![]u8 {
	if link == 0 {
		return []u8{}
	}
	id := block_id(buf, link)
	match id {
		'##DT', '##DV', '##DI', '##RD', '##SD' {
			length := binary.little_endian_u64_at(buf, int(link) + 8)
			d := data_off(buf, link)
			mut end := int(link) + int(length)
			if unfin {
				if end > buf.len {
					end = buf.len
				} else {
					// MDF blocks are 8-byte aligned: if no '##' block header sits
					// where the next block would start, the length is stale and
					// the data runs to the end of the file.
					ae := (end + 7) / 8 * 8
					if ae + 4 > buf.len || buf[ae] != `#` || buf[ae + 1] != `#` {
						end = buf.len
					}
				}
			}
			if end > buf.len {
				end = buf.len
			}
			if d >= end {
				return []u8{}
			}
			return buf[d..end].clone()
		}
		'##DZ' {
			return dz_decompress(buf, link)!
		}
		'##DL' {
			mut out := []u8{}
			mut dl := link
			for dl != 0 {
				dll := block_links(buf, dl)
				for i := 1; i < dll.len; i++ {
					if dll[i] != 0 {
						out << read_data_block(buf, dll[i], unfin)!
					}
				}
				dl = if dll.len > 0 { dll[0] } else { u64(0) }
			}
			return out
		}
		'##HL' {
			hll := block_links(buf, link)
			return read_data_block(buf, if hll.len > 0 { hll[0] } else { u64(0) }, unfin)!
		}
		else {
			return error('unknown data block ${id}')
		}
	}
}

// dz_decompress inflates a DZBLOCK and, for zip_type 1, reverses the byte-column
// transposition MDF applies before deflate to improve compression of records.
fn dz_decompress(buf []u8, off u64) ![]u8 {
	d := data_off(buf, off)
	zip_type := buf[d + 2]
	zip_param := int(binary.little_endian_u32_at(buf, d + 4))
	org_len := int(binary.little_endian_u64_at(buf, d + 8))
	data_len := int(binary.little_endian_u64_at(buf, d + 16))
	comp := buf[d + 24..d + 24 + data_len]
	raw := zlib.decompress(comp)!
	if raw.len != org_len {
		return error('DZ length mismatch: got ${raw.len}, want ${org_len}')
	}
	if zip_type != 1 {
		return raw
	}
	// zip_type 1: data was stored column-major in `zip_param`-wide rows; undo it.
	cols := zip_param
	rows := org_len / cols
	mut transposed := []u8{len: org_len}
	for c := 0; c < cols; c++ {
		col := c * rows
		for r := 0; r < rows; r++ {
			transposed[r * cols + c] = raw[col + r]
		}
	}
	// trailing bytes that don't fill a full row are stored as-is at the end.
	for i := rows * cols; i < org_len; i++ {
		transposed[i] = raw[i]
	}
	return transposed
}
