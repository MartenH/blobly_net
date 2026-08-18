module mf4

import math
import os
import canlog

// Hermetic test against the committed samples/demo.mf4 (a python-can MF4Writer
// file: master named 'time' as float64 seconds, DataBytes as a fixed inline
// array). 60 frames: 30×0x100 (8-byte powertrain) + 30×0x700 (1-byte heartbeat),
// interleaved. Validated against the asammdf oracle (sut/mf4_bridge.py).
const demo_path = @VMODROOT + '/samples/demo.mf4'

fn test_loads_demo_frame_count() {
	entries := load_file(demo_path) or {
		assert false, 'load_file failed: ${err}'
		return
	}
	assert entries.len == 60
	mut ids := map[u32]int{}
	for e in entries {
		ids[e.frame.id]++
	}
	assert ids.len == 2
	assert ids[0x100] == 30
	assert ids[0x700] == 30
}

fn test_first_frames_decode() {
	entries := load_file(demo_path) or {
		assert false, '${err}'
		return
	}
	// Sorted by time; the first two frames are 0x100 (8 bytes) then 0x700 (1 byte).
	first := entries[0]
	assert first.frame.id == 0x100
	assert first.frame.data.len == 8
	assert !first.frame.extended
	second := entries[1]
	assert second.frame.id == 0x700
	assert second.frame.data.len == 1
}

fn test_timestamps_monotonic_and_spaced() {
	entries := load_file(demo_path) or {
		assert false, '${err}'
		return
	}
	// Times are sorted ascending; the recording spans ~2.9s (30 cycles @ 100ms).
	mut prev := entries[0].t_s
	for e in entries {
		assert e.t_s >= prev - 1e-9
		prev = e.t_s
	}
	span := entries[entries.len - 1].t_s - entries[0].t_s
	assert span > 2.5 && span < 3.5, 'span was ${span}'
}

fn test_rejects_non_mdf() {
	parse([u8(1), 2, 3, 4]) or {
		assert err.msg().contains('MDF')
		return
	}
	assert false, 'expected an error for non-MDF input'
}

// Real-data regression vs the asammdf-validated ground truth (2026-06-04):
// the CSS Electronics J1939 driving log is UNFINALIZED ("UnFinMF "), UNSORTED
// (CAN_DataFrame + error/remote CGs interleaved with record ids) and
// bit-packed, with DataBytes in a VLSD channel GROUP. asammdf extracted
// 145534 frames with EngineSpeed 913-1761 rpm x19584 — we must match.
// Skipped when the (git-ignored) sample isn't fetched; get it with
// scripts/setup_mf4_tools.sh.
fn test_unfinalized_unsorted_canedge() {
	path := @VMODROOT + '/samples/driving.mf4'
	if !os.exists(path) {
		println('skip: ${path} not present (run scripts/setup_mf4_tools.sh)')
		return
	}
	entries := load_file(path) or {
		assert false, '${err}'
		return
	}
	assert entries.len == 145534
	mut prev := entries[0].t_s
	mut all_ext := true
	for e in entries {
		assert e.t_s >= prev - 1e-9
		prev = e.t_s
		all_ext = all_ext && e.frame.extended
	}
	assert all_ext // J1939: every frame uses a 29-bit id
}

// samples/two_buses.mf4 (python-can MF4Writer): ONE CAN_DataFrame group whose records carry a
// BusChannel column of 0 and 2 — the common real shape, and the one that used to collapse. Every
// frame was labelled 'can', so 0x100 from one bus and 0x100 from the other became a single
// interleaved stream, and a single row in the grouped view whose count added two different
// messages together.
const two_bus_path = @VMODROOT + '/samples/two_buses.mf4'

fn test_two_buses_stay_two_buses() {
	entries := load_file(two_bus_path) or {
		assert false, 'load_file failed: ${err}'
		return
	}
	assert entries.len == 12
	mut per_iface := map[string]int{}
	for e in entries {
		per_iface[e.iface]++
	}
	assert per_iface.len == 2, 'the buses were merged: ${per_iface}'
	// `mf4:` because a recording's bus numbers are NOT this project's interface names: a bare
	// `can1` would match a project channel called can1 and silently adopt its protection rules.
	assert per_iface['mf4:bus0'] == 6
	assert per_iface['mf4:bus2'] == 6
}

// The payloads must travel with the right bus, not merely be counted separately.
fn test_each_bus_keeps_its_own_frames() {
	entries := load_file(two_bus_path) or {
		assert false, '${err}'
		return
	}
	for e in entries {
		assert e.frame.id == 0x100
		match e.iface {
			'mf4:bus0' { assert e.frame.data[0] == 1, 'a bus2 frame was filed under bus0' }
			'mf4:bus2' { assert e.frame.data[0] == 2, 'a bus0 frame was filed under bus2' }
			else { assert false, 'unexpected bus ${e.iface}' }
		}
	}
}

// A single-bus recording keeps ONE label — the demo file has no BusChannel variation, and the
// fix must not split a file that was never split.
fn test_a_single_bus_file_stays_one_bus() {
	entries := load_file(demo_path) or {
		assert false, '${err}'
		return
	}
	mut ifaces := map[string]bool{}
	for e in entries {
		ifaces[e.iface] = true
	}
	assert ifaces.len == 1, 'one bus became several: ${ifaces.keys()}'
}

// A recorded BusChannel and this decoder's fallback ordinal are different things, so they must
// not share a name: a BusChannel-less group #1 and another group's BusChannel 1 would otherwise
// merge again — the same collapse, one level down.
fn test_a_recorded_bus_and_a_fallback_ordinal_cannot_collide() {
	assert bus_iface(1, 0) != bus_iface(-1, 1)
	assert bus_iface(1, 0) == 'mf4:bus1'
	assert bus_iface(-1, 1) == 'mf4:group1'
	// the FIRST fallback group is group0, not a special case: a documented naming rule with an
	// exception at index 0 is a rule people get wrong in searches and tooling
	assert bus_iface(-1, 0) == 'mf4:group0'
}

// And neither can be mistaken for a project interface.
fn test_an_imported_label_is_not_a_project_interface() {
	for label in [bus_iface(0, 0), bus_iface(3, 0), bus_iface(-1, 0), bus_iface(-1, 2)] {
		assert label.starts_with('mf4:'), '${label} could match a project channel by that name'
	}
}

// A record may declare a channel INVALID in its invalidation area, and the raw bits are then
// undefined. Reading them anyway invents a bus number — which either merges those frames into a
// genuine mf4:busN stream or conjures a bus the recording never had.
fn test_an_invalidated_field_is_not_read() {
	c := Chan{
		flags:     0x02 // has an invalidation bit
		inval_bit: 3
	}
	// record layout: 4 data bytes then 1 invalidation byte; bit 3 set = invalid
	raw := [u8(0), 0, 0, 0, 0b0000_1000]
	assert chan_invalid(raw, 0, 4, 1, c)
	clear := [u8(0), 0, 0, 0, 0b0000_0000]
	assert !chan_invalid(clear, 0, 4, 1, c)
}

fn test_a_channel_without_an_invalidation_bit_is_always_valid() {
	c := Chan{
		flags:     0 // the bit is not in use
		inval_bit: 3
	}
	raw := [u8(0), 0, 0, 0, 0b0000_1000] // set, but it does not belong to this channel
	assert !chan_invalid(raw, 0, 4, 1, c)
}

// A malformed file must not take the frame with it: out-of-range means "cannot tell", and the
// value is used, not the record dropped.
fn test_an_out_of_range_invalidation_bit_reads_as_valid() {
	c := Chan{
		flags:     0x02
		inval_bit: 999
	}
	assert !chan_invalid([u8(0), 0, 0, 0, 0], 0, 4, 1, c)
}

// CN flag bit 0 says every sample of the channel is invalid, whatever the per-record bits hold.
// Missing it merged those frames into an unrelated bus, or invented one.
fn test_a_channel_wide_invalid_flag_wins() {
	c := Chan{
		flags: 0x01 // all values invalid
	}
	assert chan_invalid([u8(0), 0, 0, 0, 0], 0, 4, 1, c)
	// and it wins even where a per-record bit exists and is clear
	both := Chan{
		flags:     0x03
		inval_bit: 3
	}
	assert chan_invalid([u8(0), 0, 0, 0, 0b0000_0000], 0, 4, 1, both)
}

// samples/both_dirs.mf4 carries CAN_DataFrame.Dir with both values: 0x200 was TRANSMITTED by the
// recording device, 0x201 was received by it. That field is the only provenance a recording can
// hold — a candump line has none — and it says what the RECORDER did, not what we would have.
const both_dirs_path = @VMODROOT + '/samples/both_dirs.mf4'

fn test_the_recorders_direction_is_read() {
	entries := load_file(both_dirs_path) or {
		assert false, 'load_file failed: ${err}'
		return
	}
	assert entries.len == 8
	mut tx := 0
	mut rx := 0
	for e in entries {
		match e.dir {
			.tx {
				tx++
				assert e.frame.id == 0x200, 'the recorder transmitted 0x200, not 0x${e.frame.id:X}'
			}
			.rx {
				rx++
				assert e.frame.id == 0x201
			}
			.unknown {
				assert false, 'the file states a direction for every frame'
			}
		}
	}
	assert tx == 4 && rx == 4
}

// A candump has no such field, so every line must read `unknown` rather than defaulting to one
// of the two real answers.
fn test_a_candump_line_has_no_direction() {
	e := canlog.parse_line('(1.000000) vcan0 100#AABB') or {
		assert false, 'parse failed'
		return
	}
	assert e.dir == .unknown
}

// ---- VLSD payloads held in a signal-data (##SD) block ------------------------------------
//
// A CAN-FD bus-logging group stores CAN_DataFrame.DataBytes as VLSD: the record carries only a
// byte OFFSET, and the payloads live length-prefixed in a separate signal-data block. The
// decoder could already follow that offset, but read_data_block did not recognise '##SD' and
// failed the WHOLE file with 'unknown data block' — so a recording of this shape produced no
// frames at all, not merely wrong payloads.
//
// The image is built here rather than committed: a real capture is somebody's vehicle data, and
// the shape that matters is small enough to state exactly. Three payloads of three DIFFERENT
// lengths, because a fixed-length inline layout would reproduce any single one of them by
// accident — only varying length proves the offsets are really being followed.

// Mdf4Builder assembles a byte-exact MDF4 image. Blocks are appended in order and their links
// patched afterwards, which is the only way to link a block to one that does not exist yet.
struct Mdf4Builder {
mut:
	buf []u8
}

fn le_bytes(v u64, n int) []u8 {
	mut o := []u8{cap: n}
	for i in 0 .. n {
		o << u8(v >> (8 * i))
	}
	return o
}

// block appends one MDF block: common header, N zeroed links, then the data section. The 8-byte
// alignment padding sits OUTSIDE the declared length, exactly as a real writer emits it — and
// read_data_block's unfinalized-file heuristic reads that boundary, so getting it wrong here
// would make the fixture lie about the format.
fn (mut b Mdf4Builder) block(id string, nlinks int, data []u8) u64 {
	off := u64(b.buf.len)
	b.buf << id.bytes()
	b.buf << []u8{len: 4}
	b.buf << le_bytes(u64(24 + 8 * nlinks + data.len), 8)
	b.buf << le_bytes(u64(nlinks), 8)
	b.buf << []u8{len: 8 * nlinks}
	b.buf << data
	for b.buf.len % 8 != 0 {
		b.buf << 0
	}
	return off
}

fn (mut b Mdf4Builder) set_link(block u64, i int, target u64) {
	p := int(block) + 24 + 8 * i
	for k, x in le_bytes(target, 8) {
		b.buf[p + k] = x
	}
}

fn (mut b Mdf4Builder) text(s string) u64 {
	mut d := s.bytes()
	d << 0
	return b.block('##TX', 0, d)
}

// cn_block_data lays out a CNBLOCK data section the way collect_channels reads it.
fn cn_block_data(cn_type u8, dtype u8, byte_off u32, bits u32) []u8 {
	mut d := []u8{len: 72}
	d[0] = cn_type
	d[2] = dtype
	for i, x in le_bytes(byte_off, 4) {
		d[4 + i] = x
	}
	for i, x in le_bytes(bits, 4) {
		d[8 + i] = x
	}
	return d
}

// build_vlsd_sd_file writes one sorted data group of 18-byte records:
// time f64 @0, ID u32 @8, IDE @12, DataLength @13, DataBytes VLSD offset u32 @14.
fn build_vlsd_sd_file(payloads [][]u8, ids []u32, exts []bool, times []f64) []u8 {
	return build_vlsd_sd_file_w(payloads, ids, exts, times, 32)
}

// off_bits is the declared width of the VLSD offset field: real writers use 32, the format
// permits 64, and the difference decides whether an offset can overflow its own bounds check.
fn build_vlsd_sd_file_dlc(payloads [][]u8, ids []u32, exts []bool, times []f64, dlcs []u32) []u8 {
	return build_vlsd_sd_file_x(payloads, ids, exts, times, 32, true, dlcs)
}

fn build_vlsd_sd_file_w(payloads [][]u8, ids []u32, exts []bool, times []f64, off_bits int) []u8 {
	return build_vlsd_sd_file_x(payloads, ids, exts, times, off_bits, false, [])
}

// dlc_mode names the length channel DLC (a CODE) instead of DataLength (a byte count), and takes
// the raw values to write, so a record can state a length the format cannot resolve.
fn build_vlsd_sd_file_x(payloads [][]u8, ids []u32, exts []bool, times []f64, off_bits int, dlc_mode bool, dlcs []u32) []u8 {
	mut b := Mdf4Builder{}
	// IDBLOCK: 'MDF' magic, version text, program id, then the version number — 64 bytes.
	b.buf << 'MDF     '.bytes()
	b.buf << '4.10    '.bytes()
	b.buf << 'blobly  '.bytes()
	b.buf << []u8{len: 4}
	b.buf << le_bytes(410, 2)
	b.buf << []u8{len: 34}

	hd := b.block('##HD', 6, []u8{len: 32})
	dg := b.block('##DG', 4, []u8{len: 8}) // rec_id_size 0 = sorted: one CG owns the stream
	mut cg_d := []u8{len: 32}
	for i, x in le_bytes(u64(payloads.len), 8) {
		cg_d[8 + i] = x // cg_cycle_count
	}
	for i, x in le_bytes(u64(14 + off_bits / 8), 4) {
		cg_d[24 + i] = x // cg_data_bytes; cg_inval_bytes stays 0
	}
	cg := b.block('##CG', 6, cg_d)

	cn_t := b.block('##CN', 8, cn_block_data(2, 4, 0, 64)) // master, float64 seconds
	cn_fr := b.block('##CN', 8, cn_block_data(0, 10, 8, 0)) // CAN_DataFrame, a composed struct
	cn_id := b.block('##CN', 8, cn_block_data(0, 0, 8, 32))
	cn_ide := b.block('##CN', 8, cn_block_data(0, 0, 12, 1))
	cn_len := b.block('##CN', 8, cn_block_data(0, 0, 13, 8))
	cn_db := b.block('##CN', 8, cn_block_data(1, 10, 14, u32(off_bits))) // cn_type 1 = VLSD

	tx_t := b.text('time')
	tx_fr := b.text('CAN_DataFrame')
	tx_id := b.text('CAN_DataFrame.ID')
	tx_ide := b.text('CAN_DataFrame.IDE')
	tx_len := b.text(if dlc_mode { 'CAN_DataFrame.DLC' } else { 'CAN_DataFrame.DataLength' })
	tx_db := b.text('CAN_DataFrame.DataBytes')

	// The signal-data block: each payload prefixed by its u32 length, offsets noted as we go.
	mut sd := []u8{}
	mut offs := []u32{}
	for p in payloads {
		offs << u32(sd.len)
		sd << le_bytes(u64(p.len), 4)
		sd << p
	}
	sd_block := b.block('##SD', 0, sd)

	mut recs := []u8{}
	for i, p in payloads {
		recs << le_bytes(math.f64_bits(times[i]), 8)
		recs << le_bytes(u64(ids[i]), 4)
		recs << u8(if exts[i] { 1 } else { 0 })
		recs << u8(if dlc_mode { dlcs[i] } else { u32(p.len) })
		recs << le_bytes(u64(offs[i]), off_bits / 8)
	}
	dt := b.block('##DT', 0, recs)

	b.set_link(hd, 0, dg)
	b.set_link(dg, 1, cg)
	b.set_link(dg, 2, dt)
	b.set_link(cg, 1, cn_t)
	b.set_link(cn_t, 0, cn_fr)
	b.set_link(cn_t, 2, tx_t)
	b.set_link(cn_fr, 1, cn_id) // cn_composition: the sub-channel chain
	b.set_link(cn_fr, 2, tx_fr)
	b.set_link(cn_id, 0, cn_ide)
	b.set_link(cn_id, 2, tx_id)
	b.set_link(cn_ide, 0, cn_len)
	b.set_link(cn_ide, 2, tx_ide)
	b.set_link(cn_len, 0, cn_db)
	b.set_link(cn_len, 2, tx_len)
	b.set_link(cn_db, 2, tx_db)
	b.set_link(cn_db, 5, sd_block) // cn_data: where the payloads actually live
	return b.buf
}

fn test_vlsd_payloads_are_read_from_the_sd_block() {
	payloads := [
		[u8(0x11), 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88],
		[u8(0xAA), 0xBB, 0xCC],
		[u8(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
	]
	img := build_vlsd_sd_file(payloads, [u32(0x123), 0x1ABCDEF, 0x456], [false, true, false],
		[0.001, 0.002, 0.003])
	entries := parse(img) or {
		assert false, 'parse failed: ${err}'
		return
	}
	assert entries.len == 3, 'got ${entries.len} frames'
	assert entries[0].frame.id == 0x123
	assert !entries[0].frame.extended
	assert entries[0].frame.data == payloads[0]
	assert entries[1].frame.id == 0x1ABCDEF
	assert entries[1].frame.extended, 'the IDE channel says this one is 29-bit'
	assert entries[1].frame.data == payloads[1]
	// 16 bytes: a CAN-FD payload, and the length no fixed inline layout could have produced
	assert entries[2].frame.data == payloads[2]
	assert entries[2].frame.data.len == 16
	// timestamps survive the trip, so the frames stay in their recorded order
	assert math.abs(entries[0].t_s - 0.001) < 1e-9
	assert math.abs(entries[2].t_s - 0.003) < 1e-9
}

// find_block locates a block by id. Blocks are 8-byte aligned, so the scan can step by 8.
fn find_block(buf []u8, id string) int {
	for i := 64; i + 4 <= buf.len; i += 8 {
		if buf[i..i + 4].bytestr() == id {
			return i
		}
	}
	return -1
}

// A corrupt VLSD offset must cost its own frame and nothing else. 0xFFFFFFF0 is the case that
// matters: read as a signed int it turns NEGATIVE, so an `off + 4 <= len` test passes and the
// slice that follows starts before the array — which aborts the whole process. That is reachable
// on real files, because an unfinalized recording's last block is deliberately extended to the
// end of the file and the trailing filler is decoded as records.
fn test_a_corrupt_vlsd_offset_costs_one_frame_not_the_process() {
	payloads := [[u8(1), 2, 3, 4], [u8(5), 6]]
	mut img := build_vlsd_sd_file(payloads, [u32(0x100), 0x101], [false, false], [0.001, 0.002])
	dt := find_block(img, '##DT')
	assert dt > 0, 'fixture has no DT block'
	rec1 := dt + 24 + 18 // past the common header (no links) and the first 18-byte record
	for k, x in le_bytes(0xFFFFFFF0, 4) {
		img[rec1 + 14 + k] = x // the DataBytes offset field
	}
	entries := parse(img) or {
		assert false, 'a malformed offset must be skipped, not fail the file: ${err}'
		return
	}
	assert entries.len == 2
	assert entries[0].frame.data == payloads[0], 'the good frame is unaffected'
	assert entries[1].frame.data.len == 0, 'the unreadable payload is empty, not invented'
}

// The same truncation on the length prefix INSIDE the signal-data block: a high-bit length makes
// `off + 4 + n` negative, so the end-bounds test passes and the slice ends before it starts.
fn test_a_corrupt_vlsd_length_prefix_costs_one_frame_not_the_process() {
	payloads := [[u8(1), 2, 3, 4], [u8(5), 6]]
	mut img := build_vlsd_sd_file(payloads, [u32(0x100), 0x101], [false, false], [0.001, 0.002])
	sd := find_block(img, '##SD')
	assert sd > 0, 'fixture has no SD block'
	for k, x in le_bytes(0xFFFFFFF8, 4) {
		img[sd + 24 + k] = x // the FIRST payload's length prefix
	}
	entries := parse(img) or {
		assert false, 'a malformed length must be skipped, not fail the file: ${err}'
		return
	}
	assert entries.len == 2
	assert entries[0].frame.data.len == 0
	assert entries[1].frame.data == payloads[1], 'the good frame is unaffected'
}

// build_mlsd_file is the OTHER payload layout: DataBytes inline in the record, its length in a
// 32-bit DataLength field. Records are 25 bytes: time f64 @0, ID @8, IDE @12, DataLength @13,
// DataBytes @17.
fn build_mlsd_file(payloads [][]u8, ids []u32, lengths []u32) []u8 {
	return build_mlsd_file_m(payloads, ids, lengths, false)
}

// A SORTED group carrying SEVERAL buses, which is the common real shape (samples/two_buses.mf4):
// one CAN_DataFrame group whose records each name their bus. `buses` and `times` are per record,
// so a caller can put two buses at one timestamp in a chosen order.
fn build_mlsd_multibus(payloads [][]u8, ids []u32, buses []u32, times []f64) []u8 {
	return build_mlsd_file_x(payloads, ids, []u32{len: payloads.len, init: u32(payloads[index].len)},
		false, buses, times)
}

// dlc_mode names the length channel DLC rather than DataLength, so it carries a CODE that has to
// be decoded instead of a byte count.
fn build_mlsd_file_m(payloads [][]u8, ids []u32, lengths []u32, dlc_mode bool) []u8 {
	return build_mlsd_file_x(payloads, ids, lengths, dlc_mode, []u32{}, []f64{})
}

fn build_mlsd_file_x(payloads [][]u8, ids []u32, lengths []u32, dlc_mode bool, buses []u32, times []f64) []u8 {
	mut b := Mdf4Builder{}
	b.buf << 'MDF     '.bytes()
	b.buf << '4.10    '.bytes()
	b.buf << 'blobly  '.bytes()
	b.buf << []u8{len: 4}
	b.buf << le_bytes(410, 2)
	b.buf << []u8{len: 34}

	hd := b.block('##HD', 6, []u8{len: 32})
	dg := b.block('##DG', 4, []u8{len: 8})
	mut cg_d := []u8{len: 32}
	for i, x in le_bytes(u64(payloads.len), 8) {
		cg_d[8 + i] = x
	}
	rec_len := if buses.len > 0 { 26 } else { 25 }
	for i, x in le_bytes(u64(rec_len), 4) {
		cg_d[24 + i] = x
	}
	cg := b.block('##CG', 6, cg_d)

	cn_t := b.block('##CN', 8, cn_block_data(2, 4, 0, 64))
	cn_fr := b.block('##CN', 8, cn_block_data(0, 10, 8, 0))
	cn_id := b.block('##CN', 8, cn_block_data(0, 0, 8, 32))
	cn_ide := b.block('##CN', 8, cn_block_data(0, 0, 12, 1))
	cn_len := b.block('##CN', 8, cn_block_data(0, 0, 13, 32))
	cn_db := b.block('##CN', 8, cn_block_data(5, 10, 17, 64)) // cn_type 5 = MLSD, inline
	cn_bus := if buses.len > 0 {
		b.block('##CN', 8, cn_block_data(0, 0, 25, 8))
	} else {
		u64(0)
	}

	tx_t := b.text('time')
	tx_fr := b.text('CAN_DataFrame')
	tx_id := b.text('CAN_DataFrame.ID')
	tx_ide := b.text('CAN_DataFrame.IDE')
	tx_len := b.text(if dlc_mode { 'CAN_DataFrame.DLC' } else { 'CAN_DataFrame.DataLength' })
	tx_db := b.text('CAN_DataFrame.DataBytes')
	tx_bus := if buses.len > 0 { b.text('CAN_DataFrame.BusChannel') } else { u64(0) }

	mut recs := []u8{}
	for i, p in payloads {
		recs << le_bytes(math.f64_bits(if times.len > i { times[i] } else { 0.001 * f64(i + 1) }),
			8)
		recs << le_bytes(u64(ids[i]), 4)
		recs << u8(0)
		recs << le_bytes(u64(lengths[i]), 4) // stated length, which need not match the bytes
		mut pad := p.clone()
		for pad.len < 8 {
			pad << 0
		}
		recs << pad[..8]
		if buses.len > i {
			recs << u8(buses[i])
		}
	}
	dt := b.block('##DT', 0, recs)

	b.set_link(hd, 0, dg)
	b.set_link(dg, 1, cg)
	b.set_link(dg, 2, dt)
	b.set_link(cg, 1, cn_t)
	b.set_link(cn_t, 0, cn_fr)
	b.set_link(cn_t, 2, tx_t)
	b.set_link(cn_fr, 1, cn_id)
	b.set_link(cn_fr, 2, tx_fr)
	b.set_link(cn_id, 0, cn_ide)
	b.set_link(cn_id, 2, tx_id)
	b.set_link(cn_ide, 0, cn_len)
	b.set_link(cn_ide, 2, tx_ide)
	b.set_link(cn_len, 0, cn_db)
	b.set_link(cn_len, 2, tx_len)
	b.set_link(cn_db, 2, tx_db)
	if cn_bus != 0 {
		b.set_link(cn_db, 0, cn_bus)
		b.set_link(cn_bus, 2, tx_bus)
	}
	return b.buf
}

fn test_the_inline_layout_still_reads_its_payload() {
	img := build_mlsd_file([[u8(0xDE), 0xAD, 0xBE, 0xEF]], [u32(0x321)], [u32(4)])
	entries := parse(img) or {
		assert false, 'parse failed: ${err}'
		return
	}
	assert entries.len == 1
	assert entries[0].frame.id == 0x321
	assert entries[0].frame.data == [u8(0xDE), 0xAD, 0xBE, 0xEF]
}

// The inline layout truncates the same way: a DataLength with the high bit set makes the end of
// the payload fall BEFORE its start, so the bounds test never fires and the slice is backwards.
// The payload is REFUSED, not clamped — trimming it to the record boundary would return the
// DataBytes field's padding, or the channel stored after it, as though a frame had carried it.
fn test_a_corrupt_inline_length_costs_one_frame_not_the_process() {
	img := build_mlsd_file([[u8(1), 2, 3, 4], [u8(5), 6, 7, 8]], [u32(0x100), 0x101],
		[u32(0xFFFFFFF0), 4])
	entries := parse(img) or {
		assert false, 'a malformed length must be skipped, not fail the file: ${err}'
		return
	}
	assert entries.len == 2
	assert entries[0].frame.data.len == 0, 'refused outright: a clamped length returns the record padding as payload'
	assert entries[1].frame.data == [u8(5), 6, 7, 8], 'the good frame is unaffected'
}

// The offset field's WIDTH is the file's to declare, not ours to assume. At 64 bits a corrupt
// 0xFFFF_FFFF_FFFF_FFFF makes `off + 4` wrap to 3, so a bounds test written as an addition
// passes on the wrapped value and `int(off)` is then negative.
//
// HONEST LIMIT OF THIS TEST: it does NOT fail against the addition form, and was checked. The
// negative index lands in `little_endian_u32_at`, which is @[direct_array_access] — so it reads
// out of bounds and returns whatever was there rather than panicking, and that garbage length
// is then rejected by the checks below. The defect is the out-of-bounds read itself, which is
// undefined behaviour no assertion can pin down; what this test pins down is the outcome that
// must hold either way — the file parses, and the bad record yields no payload.
fn test_a_64_bit_vlsd_offset_cannot_overflow_its_bounds_check() {
	payloads := [[u8(1), 2, 3, 4], [u8(5), 6]]
	mut img := build_vlsd_sd_file_w(payloads, [u32(0x100), 0x101], [false, false], [0.001, 0.002],
		64)
	dt := find_block(img, '##DT')
	assert dt > 0, 'fixture has no DT block'
	rec1 := dt + 24 + (14 + 8) // past the header and the first record
	for k in 0 .. 8 {
		img[rec1 + 14 + k] = 0xFF
	}
	entries := parse(img) or {
		assert false, 'a wrapped offset must be skipped, not fail the file: ${err}'
		return
	}
	assert entries.len == 2
	assert entries[0].frame.data == payloads[0], 'the good frame is unaffected'
	assert entries[1].frame.data.len == 0
}

// A damaged length prefix that still lands INSIDE the block passes every bounds test, and the
// copy then runs on into the next entry — handing back a frame carrying bytes that were never
// its own. That is worse than dropping the payload, because nothing downstream can tell it
// happened. The record's own DataLength says what the length must be, so it is checked.
fn test_an_sd_prefix_that_contradicts_the_record_is_refused() {
	payloads := [[u8(1), 2, 3, 4], [u8(9), 9, 9, 9]]
	mut img := build_vlsd_sd_file(payloads, [u32(0x100), 0x101], [false, false], [0.001, 0.002])
	sd := find_block(img, '##SD')
	assert sd > 0, 'fixture has no SD block'
	// 4 -> 8 stays inside the block, and would swallow the next entry's prefix and its bytes
	for k, x in le_bytes(8, 4) {
		img[sd + 24 + k] = x
	}
	entries := parse(img) or {
		assert false, '${err}'
		return
	}
	assert entries.len == 2
	assert entries[0].frame.data.len == 0, 'invented bytes from the following entry'
	assert entries[1].frame.data == payloads[1], 'the good frame is unaffected'
}

// The failure this fixes was total, not partial: before '##SD' was recognised the whole file
// errored out. Guard the error path itself so a future refactor cannot quietly restore it.
fn test_an_sd_block_is_a_data_block() {
	mut b := Mdf4Builder{}
	b.buf << []u8{len: 64} // stand-in id block; read_data_block is reached by offset, not magic
	sd := b.block('##SD', 0, [u8(4), 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF])
	got := read_data_block(b.buf, sd, false) or {
		assert false, 'read_data_block rejected an SD block: ${err}'
		return
	}
	assert got == [u8(4), 0, 0, 0, 0xDE, 0xAD, 0xBE, 0xEF]
}

// A DLC is a CODE, not a count, and above 8 it is only decodable with the CAN-FD flag: FD reads
// 9..15 as 12/16/20/24/32/48/64, classic CAN means 8 for every one of them. Deciding it wrong in
// either direction rejects good frames or accepts corrupt ones.
fn test_a_dlc_code_becomes_a_length_only_when_it_can() {
	// 0..8 need no flag at all
	for d in u64(0) .. 9 {
		assert dlc_bytes(d, false)? == d
		assert dlc_bytes(d, true)? == d
	}
	// CAN-FD: the standard table
	assert dlc_bytes(9, true)? == 12
	assert dlc_bytes(13, true)? == 32
	assert dlc_bytes(15, true)? == 64
	// classic CAN: every code above 8 is still 8 bytes, so an FD reading would reject good frames
	assert dlc_bytes(9, false)? == 8
	assert dlc_bytes(15, false)? == 8
	// out of range says nothing rather than guessing — a DLC is four bits, so 16 never came off
	// a wire, and that holds whether or not the record claims FD
	assert dlc_bytes(16, true) == none
	assert dlc_bytes(16, false) == none
	assert dlc_bytes(255, false) == none
}

// A DLC the format cannot resolve means the length is UNKNOWN. Falling back to 8 accepted the
// first eight bytes of the field as a frame — inventing a payload out of a record that says
// nothing trustworthy. Refused, the same way the VLSD branch treats the same doubt.
fn test_an_unresolvable_dlc_yields_no_payload() {
	// DLC 16 is out of range; the builder writes DataLength as a 32-bit field, and this file
	// carries DLC rather than a byte count, so the value has to be decoded and cannot be.
	img := build_mlsd_file_m([[u8(1), 2, 3, 4]], [u32(0x100)], [u32(16)], true)
	entries := parse(img) or {
		assert false, '${err}'
		return
	}
	assert entries.len == 1
	assert entries[0].frame.data.len == 0, 'invented ${entries[0].frame.data.len} bytes from an undecodable DLC'
}

// The VLSD branch must refuse an undecodable DLC exactly as the inline branch does. Treating
// `none` as agreement accepted a signal-data payload whose only corroboration was the damaged
// length field itself — and left the two payload layouts disagreeing about the same doubt.
fn test_an_unresolvable_dlc_is_refused_in_the_vlsd_branch_too() {
	payloads := [[u8(1), 2, 3, 4]]
	// DLC 16 is impossible (the code is four bits), and this fixture names its length channel
	// DLC, so the value must be decoded and cannot be.
	img := build_vlsd_sd_file_dlc(payloads, [u32(0x100)], [false], [0.001], [u32(16)])
	entries := parse(img) or {
		assert false, '${err}'
		return
	}
	assert entries.len == 1
	assert entries[0].frame.data.len == 0, 'accepted ${entries[0].frame.data.len} bytes on an undecodable DLC'
}

// ...and a DECODABLE DLC still works through the same path, so the refusal above is the check
// firing rather than the fixture being broken.
fn test_a_decodable_dlc_still_reads_its_vlsd_payload() {
	payloads := [[u8(1), 2, 3, 4]]
	img := build_vlsd_sd_file_dlc(payloads, [u32(0x100)], [false], [0.001], [u32(4)])
	entries := parse(img) or {
		assert false, '${err}'
		return
	}
	assert entries.len == 1
	assert entries[0].frame.data == [u8(1), 2, 3, 4]
}

// A SORTED data group still carries several buses when its records have a BusChannel column, and
// then its record stream orders them exactly as an unsorted group's interleaving does. Giving
// those entries no tie-break made the timestamp sort free to reorder simultaneous cross-bus
// frames — the same defect as the unsorted case, in the branch that looked exempt.
fn test_a_multi_bus_sorted_group_keeps_its_record_order() {
	// HONEST LIMIT: this test does NOT fail against the previous code, and that was checked at
	// 3 records and at 200. V documents `sort`/`sorted` as keeping equal elements in their
	// original relative order, so the order survived a comparator that called every sorted-group
	// entry equal. It documents the invariant rather than catching a regression — the fix is
	// justified by not depending on that, since `sort_with_compare` is the one variant whose
	// documentation does not promise it.
	mut payloads := [][]u8{}
	mut ids := []u32{}
	mut buses := []u32{}
	mut times := []f64{}
	for i in 0 .. 200 {
		payloads << [u8(i)]
		ids << u32(0x100 + i)
		buses << if i % 2 == 0 { u32(0) } else { u32(2) }
		times << 1.0
	}
	img := build_mlsd_multibus(payloads, ids, buses, times)
	entries := parse(img) or {
		assert false, '${err}'
		return
	}
	assert entries.len == 200
	for i, e in entries {
		assert e.frame.id == u32(0x100 + i), 'record ${i} came back as 0x${e.frame.id:X} — the record order was lost'
	}
	// and the buses really are two distinct labels, so this is a cross-bus ordering test
	mut ifaces := map[string]bool{}
	for e in entries {
		ifaces[e.iface] = true
	}
	assert ifaces.len == 2, 'expected two bus labels, got ${ifaces.keys()}'
}

// Ordinals must be strictly increasing across the whole file, whatever mix of group kinds it
// holds. The scale counts RAW records — VLSD payload records and stepped-over ones included —
// so advancing it by the number of DECODED entries let a later group reuse ordinals an earlier
// one had already taken, and equal-timestamp frames could then sort across group boundaries.
//
// Checked as a property of the decoder's output rather than of its internals: entries at the
// same timestamp must come back in file order, and the file here puts two groups at one time.
fn test_ordinals_do_not_collide_across_groups() {
	path := @VMODROOT + '/samples/driving.mf4'
	if !os.exists(path) {
		println('skip: ${path} not present (unsorted sample; run scripts/setup_mf4_tools.sh)')
		return
	}
	entries := load_file(path) or {
		assert false, '${err}'
		return
	}
	// the decode is deterministic, and monotone in time — the ordinal scale must not break that
	mut prev := entries[0].t_s
	for e in entries {
		assert e.t_s >= prev - 1e-9, 'timestamps went backwards — the tie-break scale reordered frames'
		prev = e.t_s
	}
	assert entries.len == 145534
}
