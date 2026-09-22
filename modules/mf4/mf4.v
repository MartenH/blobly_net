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
// before decoding, and a VLSD channel group inside an unsorted DT is carried along as
// the byte stream its data records point into (`vlsd_streams`).
//
// GUI-free + pure V (see CLAUDE.md module convention). Returns canlog.LogEntry so
// it plugs straight into the existing log/replay path. Validated frame-for-frame
// against asammdf on a real 62k-frame J1939 recording.
//
// MDF4 block layout reference (all little-endian): every block starts with a
// common header — id[4] "##XX", reserved[4], u64 length, u64 link_count N,
// then N u64 links, then a type-specific data section.
module mf4

import encoding.binary
import math
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
	return load_recording(path)!.log.entries()
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
	log   canlog.Log
	buses []BusInfo
}

// load_recording parses a file and also reports its buses. Same work as load_file — the bus
// list is a by-product of the one walk, not a second pass, so the two cannot disagree.
pub fn load_recording(path string) !Recording {
	mut src := open_source(path)!
	defer {
		src.close()
	}
	return parse_recording(mut src)!
}

// parse reads an in-memory MDF4 image. Split out from load_file so callers/tests
// can feed bytes directly.
pub fn parse(buf []u8) ![]canlog.LogEntry {
	mut src := MemSource{
		buf: buf
	}
	return parse_recording(mut src)!.log.entries()
}

// parse_log is parse into the arena: what a replay loads.
pub fn parse_log(buf []u8) !canlog.Log {
	mut src := MemSource{
		buf: buf
	}
	return parse_recording(mut src)!.log
}

// load_log is load_file into the arena.
pub fn load_log(path string) !canlog.Log {
	return load_recording(path)!.log
}

// tally_buses attributes a slice of freshly decoded entries to their bus labels, carrying the
// channel group's acquisition name along. A group that produced SEVERAL labels (records carrying
// their own BusChannel) keeps the name only where it is unambiguous: one name covering two buses
// would be a label pretending to be an identity.
fn tally_buses(log &canlog.Log, start int, acq string, mut names map[string]string, mut counts map[string]int) {
	// By bus INDEX over the rows, one array increment each; the label is resolved once per
	// bus the range touched, not once per record.
	mut per := []int{len: log.labels.len}
	for i in start .. log.rows.len {
		per[log.rows[i].bus]++
	}
	for b, n in per {
		if n == 0 {
			continue
		}
		lbl := log.labels[b]
		counts[lbl] += n
		if existing := names[lbl] {
			if existing != acq {
				names[lbl] = '' // two different names for one label: trust neither
			}
		} else {
			names[lbl] = acq
		}
	}
}

// read_id_block checks the 64-byte identification block and says whether the file is
// UNFINALIZED (`UnFinMF `: a logger that powered off before finalizing, whose counts and last
// block length are stale). ONE check for the loader and the stream.
fn read_id_block(mut src ByteSource) !bool {
	if src.size() < 64 {
		return error('not an MDF file (bad id block)')
	}
	magic := bytes_at(mut src, 0, 8).bytestr()
	unfin := magic.starts_with('UnFinMF')
	if !magic.starts_with('MDF') && !unfin {
		return error('not an MDF file (bad id block)')
	}
	return unfin
}

fn parse_recording(mut src ByteSource) !Recording {
	rec := parse_recording_unchecked(mut src)!
	f := src.failure()
	if f != '' {
		return error(f)
	}
	return rec
}

fn parse_recording_unchecked(mut src ByteSource) !Recording {
	unfin := read_id_block(mut src)!
	mut log := canlog.Log{}
	// Tie-break key, one per entry, on ONE monotone scale across the whole file: the position of
	// the record that produced it. Sorting by timestamp alone reorders frames that share one,
	// and that order is real — a SORTED data group still carries several buses when its records
	// have a BusChannel column (samples/two_buses.mf4 is exactly that), so its record stream
	// orders them just as an unsorted group's interleaving does. An earlier version gave sorted
	// groups max_int on the reasoning that each stores one bus; that is true only of buses in
	// SEPARATE groups, and it discarded the order inside a multi-bus one.
	mut order := []int{}
	mut seq := 0
	// HDBLOCK is at the fixed offset 64; its first link is the first DGBLOCK.
	hd := block_links(mut src, 64)
	mut dg := if hd.len > 0 { hd[0] } else { u64(0) }
	mut group := 0 // ordinal of the CAN_DataFrame group, for files without a BusChannel
	mut bus_names := map[string]string{}
	mut bus_counts := map[string]int{}
	for dg != 0 {
		dgl := block_links(mut src, dg)
		dg_data_off := data_off(mut src, dg)
		rec_id_size := u8_at(mut src, dg_data_off)
		cg_first := if dgl.len > 1 { dgl[1] } else { u64(0) }
		data_link := if dgl.len > 2 { dgl[2] } else { u64(0) }
		if cg_first != 0 {
			check_rec_id_size(int(rec_id_size))!
			raw := read_data_block(mut src, data_link, unfin)!
			start := log.rows.len
			if rec_id_size == 0 {
				// Sorted: one CG per DG, the data block is its record stream.
				before := log.rows.len
				// The record indices are not needed here: a SORTED group's ordinal is a running
				// counter over the entries that EXIST, so a refused record simply never gets one
				// and the sequence stays ascending. Only the unsorted path indexes ordinals by
				// record, and only that one breaks when a record produces no entry.
				mut idxs := []int{}
				parse_cg(mut src, cg_first, raw, unfin, map[u64][]u8{}, group, mut idxs, mut log)!
				// One entry per ENTRY, in record order, so the counter IS the sequence position.
				for _ in before .. log.rows.len {
					order << seq
					seq++
				}
				group++
				// cg_tx_acq_name is link 2. Read AFTER the decode and only over the entries it
				// produced, so the name follows the frames rather than being guessed at.
				cgl := block_links(mut src, cg_first)
				acq := read_tx(mut src, if cgl.len > 2 { cgl[2] } else { u64(0) })
				tally_buses(&log, start, acq, mut bus_names, mut bus_counts)
			} else {
				// Tallied per channel group inside, since each has its own acquisition name.
				base := seq
				before := log.rows.len
				group = demux_unsorted(mut src, cg_first, raw, int(rec_id_size), unfin, group, mut
					log, mut bus_names, mut bus_counts, mut order)!
				// demux appends this group's INTERLEAVED record ordinals; lift them onto the
				// file-wide scale so ties never compare a per-group ordinal against a global one.
				mut top := base
				for k in before .. log.rows.len {
					if order[k] != max_int {
						order[k] += base
						if order[k] >= top {
							top = order[k] + 1
						}
					}
				}
				// Past the highest ordinal ACTUALLY ASSIGNED, not past the number of decoded
				// entries. Those differ: the ordinals count raw records — VLSD payload records
				// and any the demux steps over included — so advancing by the decode count left
				// the next group starting at or below ordinals already used, and a later group's
				// equal-timestamp frames could sort ahead of an earlier one's.
				seq = top
			}
		}
		dg = if dgl.len > 0 { dgl[0] } else { u64(0) }
	}
	// Sorted as PAIRS so the tie-break survives: sorting the rows alone would leave `order`
	// pointing at the wrong entries, which is worse than not having it. The INDEX is sorted
	// (the comparator reads two f64s out of a pointer-free block) and the rows are permuted IN
	// PLACE, so the recording is never held twice — a second block was a second 98 MB the
	// collector could find on the worker's stack for the rest of the run.
	rows := log.rows
	mut idx := []int{len: rows.len, init: index}
	idx.sort_with_compare(fn [rows, order] (a &int, b &int) int {
		ta := rows[*a].t_s
		tb := rows[*b].t_s
		if ta != tb {
			return if ta < tb { -1 } else { 1 }
		}
		oa := order[*a]
		ob := order[*b]
		if oa != ob {
			return if oa < ob { -1 } else { 1 }
		}
		return 0
	})
	permute_rows(mut log.rows, idx)
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
		log:   log
		buses: buses
	}
}

// CgInfo is one channel group's demux key in an unsorted data group.
struct CgInfo {
	link   u64
	rec_id u64
	vlsd   bool // cg_flags bit 0: variable-length records (4-byte size prefix)
	size   int  // fixed record size (data + invalidation bytes)
	// A record id an EARLIER group of this data group already declared. The demux hands a record
	// to the first group claiming its id; a later claimant gets no records at all, rather than
	// decoding the first group's bytes a second time under its own label (which is what keying
	// the per-id streams alone did). The stream's cursor makes the same choice.
	dup bool
}

// demux_unsorted splits an unsorted DG's record stream (records from several
// CGs interleaved, each prefixed by its record id) into per-CG streams, then
// decodes each fixed-length CG. A VLSD group's records (u32 length + bytes)
// are concatenated VERBATIM into a stream keyed by the CG's block address:
// other groups' VLSD channels carry byte offsets into exactly that
// concatenation, and their cn_data link names the VLSD CG block (this is how
// CANedge stores classic-CAN DataBytes).
// Returns the next free group ordinal, so numbering stays unique across data groups.
fn demux_unsorted(mut src ByteSource, cg_first u64, raw []u8, rec_id_size int, unfin bool, group int,
	mut log canlog.Log, mut names map[string]string, mut counts map[string]int, mut order []int) !int {
	mut cgs := []CgInfo{}
	mut claimed := map[u64]bool{}
	mut cgi := cg_first
	for cgi != 0 {
		cgd := data_off(mut src, cgi)
		rid := u64_at(mut src, cgd)
		cgs << CgInfo{
			link:   cgi
			rec_id: rid
			vlsd:   u16_at(mut src, cgd + 16) & 1 == 1
			size:   record_size(u32_at(mut src, cgd + 24), u32_at(mut src, cgd + 28))
			dup:    rid in claimed
		}
		claimed[rid] = true
		l := block_links(mut src, cgi)
		cgi = if l.len > 0 { l[0] } else { u64(0) }
	}
	mut streams := map[u64][]u8{} // fixed-length CGs, keyed by record id
	// Where each of those records sat in the INTERLEAVED stream. Splitting by record id and
	// decoding one CG at a time discards the only cross-bus ordering an unsorted file has: two
	// frames sharing a timestamp come back in channel-group order instead of the order the
	// logger wrote them, and a replay then reorders simultaneous stimuli across buses.
	mut ordinals := map[u64][]int{}
	mut rec_n := 0
	mut vlsd_streams := map[u64][]u8{} // VLSD CGs, keyed by CG block address
	for c in cgs {
		if c.vlsd {
			// declared here even with no record in the stream: a frame group naming a VLSD group
			// that wrote nothing is a frame group with no payloads, not a data link to a CG
			// block — which is what read_data_block was handed, failing the whole file
			vlsd_streams[c.link] = []u8{}
		}
	}
	mut pos := 0
	outer: for pos + rec_id_size <= raw.len {
		rid := read_uint(raw, pos, 0, rec_id_size * 8)
		rec_n++
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
				// UNSIGNED, and bounded before it slices: the filler an unfinalized file's
				// extended last block decodes as records reads as 0xFFFFFFF0, which as an int is
				// negative — the bounds test passed and the slice ran backwards, aborting the
				// process on one bad record (found by the stream's golden test, #172 step 1).
				n64 := u64(binary.little_endian_u32_at(raw, pos))
				if n64 > u64(raw.len - pos - 4) {
					break outer
				}
				n := int(n64)
				vlsd_streams[c.link] << raw[pos..pos + 4 + n] // keep the length prefix
				pos += 4 + n
			} else {
				if c.size < 0 || pos + c.size > raw.len {
					break outer // a corrupt width, or a record past the end
				}
				streams[c.rec_id] << raw[pos..pos + c.size]
				ordinals[c.rec_id] << rec_n
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
			start := log.rows.len
			mut idxs := []int{}
			// a duplicate claimant decodes nothing (see CgInfo.dup) but still counts as a group
			recs := if c.dup { []u8{} } else { streams[c.rec_id] or { []u8{} } }
			parse_cg(mut src, c.link, recs, unfin, vlsd_streams, g, mut idxs, mut log)!
			// BY RECORD INDEX, not by position in `out`. A record the decoder refused — an
			// undefined id, a remote frame whose requested length is unknown — produces no
			// entry, so the two lists stop lining up at the first skip and everything after it
			// would take an earlier record's ordinal. That is not a cosmetic slip: these
			// ordinals are what restore the INTERLEAVED order of several channel groups sharing
			// one record stream, and a wrong one reorders equal-timestamp frames across buses.
			ords := ordinals[c.rec_id] or { []int{} }
			for k in start .. log.rows.len {
				ri := idxs[k - start]
				order << if ri < ords.len { ords[ri] } else { max_int }
			}
			g++
			// Each channel group here has its OWN cg_tx_acq_name — sharing a record stream is a
			// storage detail, not a reason to leave every bus in the file unnamed.
			cgl := block_links(mut src, c.link)
			tally_buses(&log, start, read_tx(mut src, if cgl.len > 2 { cgl[2] } else { u64(0) }), mut
				names, mut counts)
		}
	}
	return g
}

// chan holds the record-layout facts we need for one leaf channel.
struct Chan {
	name      string
	cn_type   u8  // 0=fixed, 1=VLSD, 2=master, 5=MLSD (max-length inline)
	data_type u8  // 0/1=uint LE/BE, 2/3=int, 4/5=float LE/BE
	byte_off  int // offset of the field within a record
	bit_off   u8  // bit offset within that byte (CANedge bit-packs channels)
	bit_count u32
	data_link u64 // cn_data: VLSD signal-data block (type 1) or length channel (type 5)
	cc_link   u64 // cn_cc_conversion (CCBLOCK), for the master-time scale
	// cn_flags bit 0 = EVERY sample of this channel is invalid; bit 1 = it has a per-record
	// invalidation bit, whose position in the record's invalidation area is cn_inval_bit_pos.
	// Either way the raw bits are undefined where the flag applies — reading them anyway
	// invents a value.
	flags     u32
	inval_bit u32
}

// `group` distinguishes this channel group from the file's others when the records carry no
// BusChannel of their own — better a stable synthetic name per group than one shared label.
// `rec_idx` receives the index of the RECORD each appended entry came from. It used to be
// unnecessary: one entry per record meant the caller could pair them positionally, and
// demux_unsorted does exactly that when it restores the interleaved order. Skipping a record —
// an undefined id, or a remote frame whose requested length is unknown — breaks that pairing,
// and every entry after the skip would inherit an earlier record's ordinal. Equal-timestamp
// frames from another channel group would then sort into the wrong order and replay in a
// cross-bus sequence the recording never had, which is the one property multibus replay exists
// to preserve (codex #175 r3).
fn parse_cg(mut src ByteSource, cg u64, recs []u8, unfin bool, vlsd_streams map[u64][]u8, group int, mut rec_idx []int,
	mut log canlog.Log) ! {
	mut labels := new_labels(group)
	lay := resolve_layout(mut src, cg) or { return }
	cycles := lay.record_count(u64(recs.len), unfin)
	// VLSD source: in a sorted file cn_data links an SD/DZ block; in an unsorted
	// one it names the VLSD channel GROUP, whose records were concatenated into
	// vlsd_streams during demux.
	mut vlsd := VlsdBytes(MemVlsd{})
	if lay.is_vlsd {
		vlsd = if lay.vlsd_link in vlsd_streams {
			MemVlsd{
				buf: vlsd_streams[lay.vlsd_link] or { []u8{} }
			}
		} else {
			MemVlsd{
				buf: read_data_block(mut src, lay.vlsd_link, unfin)!
			}
		}
	}
	for k := u64(0); k < cycles; k++ {
		base := int(k) * lay.stride
		if base + lay.data_bytes > recs.len {
			break
		}
		// ONE decoder for this loop and for the stream's cursors (layout.v). A refused record
		// leaves no ordinal behind: rec_idx is pushed only for a row that was decoded.
		row := decode_row(&lay, recs, base, mut vlsd, mut labels, mut log) or { continue }
		rec_idx << int(k) // which record this entry came from — see the note on the parameter
		log.rows << row
	}
}

// permute_rows applies a sorted index in place: position j receives rows[idx[j]], cycle by
// cycle with one row of scratch, so the block is never duplicated.
fn permute_rows(mut rows []canlog.Row, idx []int) {
	mut done := []bool{len: rows.len}
	for i in 0 .. rows.len {
		if done[i] || idx[i] == i {
			done[i] = true
			continue
		}
		tmp := rows[i]
		mut j := i
		for {
			k := idx[j]
			done[j] = true
			if k == i {
				rows[j] = tmp
				break
			}
			rows[j] = rows[k]
			j = k
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

// Labels hands out ONE string per bus, not one per record: a recording of a million frames
// otherwise carried a million copies of a dozen labels — a million objects for the collector to
// mark on every pass, for as long as the replay held the recording (#299's follow-up). Keyed on
// what bus_iface keys on, so the text is the same; only the identity is shared.
struct Labels {
	group_no int
mut:
	group  int = -1 // the label a record without its own BusChannel gets, interned on first use
	by_bus map[int]u16
}

fn new_labels(group int) Labels {
	return Labels{
		group_no: group
	}
}

// label is the Log's index for a record's bus — interned ON FIRST USE and cached here, so a
// million records cost a million map lookups and a dozen interns, and a label exists in the
// Log only if a row carries it: the group label interned eagerly named a bus for every channel
// group, signal and error-frame groups included, and a one-bus file read as four (self-review
// of the arena). None when the Log can name no more buses; the caller drops the record.
fn (mut l Labels) label(bus_no int, mut log canlog.Log) ?u16 {
	if bus_no < 0 {
		if l.group < 0 {
			l.group = int(log.intern(bus_iface(-1, l.group_no)) or { return none })
		}
		return u16(l.group)
	}
	return l.by_bus[bus_no] or {
		b := log.intern(bus_iface(bus_no, -1)) or { return none }
		l.by_bus[bus_no] = b
		b
	}
}

// collect_channels walks a cn_next chain, recursing into struct compositions
// (cn_composition), accumulating every leaf channel's record-layout facts.
fn collect_channels(mut src ByteSource, cn_first u64, mut chans []Chan) {
	mut cn := cn_first
	for cn != 0 {
		cnl := block_links(mut src, cn)
		d := data_off(mut src, cn)
		name := read_tx(mut src, if cnl.len > 2 { cnl[2] } else { u64(0) })
		chans << Chan{
			name:      name
			cn_type:   u8_at(mut src, d + 0)
			data_type: u8_at(mut src, d + 2)
			bit_off:   u8_at(mut src, d + 3) // cn_bit_offset
			byte_off:  int(u32_at(mut src, d + 4))
			bit_count: u32_at(mut src, d + 8)
			data_link: if cnl.len > 5 { cnl[5] } else { u64(0) }
			cc_link:   if cnl.len > 4 { cnl[4] } else { u64(0) }
			flags:     u32_at(mut src, d + 12)
			inval_bit: u32_at(mut src, d + 16)
		}
		comp := if cnl.len > 1 { cnl[1] } else { u64(0) }
		if comp != 0 && block_id(mut src, comp) == '##CN' {
			collect_channels(mut src, comp, mut chans)
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
fn cc_linear(mut src ByteSource, cc u64) (f64, f64) {
	if cc == 0 || block_id(mut src, cc) != '##CC' {
		return 0.0, 1.0
	}
	d := data_off(mut src, cc)
	cc_type := u8_at(mut src, d + 0)
	val_count := int(u16_at(mut src, d + 6))
	if cc_type != 1 || val_count < 2 {
		return 0.0, 1.0
	}
	off := math.f64_from_bits(u64_at(mut src, d + 24))
	factor := math.f64_from_bits(u64_at(mut src, d + 24 + 8))
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

fn block_id(mut src ByteSource, off u64) string {
	return bytes_at(mut src, off, 4).bytestr()
}

// block_links returns a block's link array (N u64 links after the common header). The count is
// bounded before it sizes anything: a damaged header claiming 2^60 links must not be believed.
// link_count is a block's link count, bounded by what the block and the file can hold: the
// array lies inside the block's declared length and the block inside the file, so a corrupt
// count sizes nothing. A fixed cap of 65,536 stood here and read a VALID count above it as 0
// — a DL block listing a large recording's data blocks one by one — which made the chain
// empty and the recording silently nothing, in both readers (codex on #342 round 7). The array
// is materialized: 8 bytes a link, and the bound is the block, so a DL of a hundred thousand
// links is under a megabyte read once.
fn link_count(mut src ByteSource, off u64) u64 {
	n := u64_at(mut src, off + 16)
	length := u64_at(mut src, off + 8)
	if length < 24 || n > (length - 24) / 8 {
		return 0
	}
	if off > src.size() || src.size() - off < 24 || n > (src.size() - off - 24) / 8 {
		return 0
	}
	if n > u64(max_int) {
		return 0
	}
	return n
}

// The most links a HEADER block is read with: the format gives HD, DG, CG, CN, SI and HL a
// handful each, a CC as many as its value table has entries — hundreds — and only the DL an
// unbounded array, which chain_walk iterates without this. So the array materialized here is
// at most half a megabyte, whatever a corrupt count claims; a count past it is a corrupt
// header, not a large one, and reads as no links.
const max_header_links = u64(1) << 16

fn block_links(mut src ByteSource, off u64) []u64 {
	n64 := link_count(mut src, off)
	n := if n64 > max_header_links { 0 } else { int(n64) }
	mut links := []u64{cap: n}
	for i := 0; i < n; i++ {
		links << u64_at(mut src, off + 24 + 8 * u64(i))
	}
	return links
}

// data_off returns the byte offset of a block's type-specific data section.
fn data_off(mut src ByteSource, off u64) u64 {
	return off + 24 + 8 * link_count(mut src, off)
}

// read_tx returns the UTF-8 text of a TX/MD block (null-terminated), or '' .
fn read_tx(mut src ByteSource, link u64) string {
	if link == 0 {
		return ''
	}
	id := block_id(mut src, link)
	if id != '##TX' && id != '##MD' {
		return ''
	}
	d := data_off(mut src, link)
	// The text runs to its NUL — INSIDE ITS BLOCK. A block missing the terminator used to be
	// read to the next zero byte in the file, which in a recording of tens of GB is the rest of
	// the file into memory before the first record is read (codex on #342 round 3); the block's
	// declared length bounds it now, under a cap no name or comment reaches.
	length := u64_at(mut src, link + 8)
	if d >= src.size() {
		return ''
	}
	// the block's end, clamped to the file before the addition (as chain_walk clamps), and the
	// text is what lies between the DATA offset and it — the link array is `d`'s to skip, not
	// the text's to read: `length - 24` read 8 bytes per link past the block (codex on #342
	// round 5, a defect of round 3's fix)
	stop := if link > src.size() || length > src.size() - link { src.size() } else { link + length }
	mut limit := if stop > d { stop - d } else { u64(0) }
	if limit > max_text_block {
		limit = max_text_block
	}
	mut out := []u8{}
	mut at := d
	for at < d + limit {
		left := d + limit - at
		n := if left < 256 { int(left) } else { 256 }
		piece := bytes_at(mut src, at, n)
		mut end := -1
		for i in 0 .. n {
			if piece[i] == 0 {
				end = i
				break
			}
		}
		if end >= 0 {
			out << piece[..end]
			return out.bytestr()
		}
		out << piece[..n]
		at += u64(n)
	}
	return out.bytestr()
}

// check_rec_id_size admits the record id widths the format defines — 0 (sorted), 1, 2, 4 and 8
// bytes — and refuses the rest: read_uint over more than 64 bits shifts past the word, which is
// undefined in the C it becomes, so a corrupt width was a platform-dependent record id and a
// stream misrouted from its first record (codex on #342 round 11). One rule for both readers.
fn check_rec_id_size(n int) ! {
	if n !in [0, 1, 2, 4, 8] {
		return error('data group declares a record id of ${n} bytes; the format allows 1, 2, 4 or 8')
	}
}

// record_size is a fixed channel group's record width — cg_data_bytes + cg_invalidation_bytes —
// or -1 where the two u32s sum past an int: added as ints they went NEGATIVE, and the demux
// sliced backwards on it. 0 is a legitimate width (a group with no channels; its record is the
// record id alone) that both readers step over.
fn record_size(data u32, inval u32) int {
	total := u64(data) + u64(inval)
	if total > u64(max_int) {
		return -1
	}
	return int(total)
}

// The most text a TX/MD block is read for: a channel name or a comment is bytes to kilobytes,
// and a block claiming more is not one whose text this reader needs.
const max_text_block = u64(1) << 20

// read_data_block resolves a DGBLOCK data link to its raw record bytes: the data CHAIN
// concatenated (chain.v) — uncompressed (DT/DV/DI/RD/SD), compressed (DZ) and list (DL/HL)
// blocks, an unfinalized file's understated last block extended to the end of the file. The
// loader and the stream resolve a link through the one walker, so they cannot disagree about
// which bytes a link names.
fn read_data_block(mut src ByteSource, link u64, unfin bool) ![]u8 {
	blocks := chain_blocks(mut src, link, unfin)!
	total := chain_len(blocks)
	if total > u64(max_int) {
		return error('data of ${total} bytes cannot be held in memory whole; stream it')
	}
	mut out := []u8{cap: int(total)}
	for b in blocks {
		out << block_bytes(mut src, b)!
	}
	return out
}
