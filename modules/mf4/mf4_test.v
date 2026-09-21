module mf4

import math
import compress.zlib
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
	for label in [bus_iface(0, 0), bus_iface(3, 0), bus_iface(-1, 0),
		bus_iface(-1, 2)] {
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
	img := build_vlsd_sd_file(payloads, [u32(0x123), 0x1ABCDEF, 0x456], [false, true, false], [
		0.001,
		0.002,
		0.003,
	])
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
	mut img := build_vlsd_sd_file(payloads, [u32(0x100), 0x101], [false, false], [
		0.001,
		0.002,
	])
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
	mut img := build_vlsd_sd_file(payloads, [u32(0x100), 0x101], [false, false], [
		0.001,
		0.002,
	])
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
	return build_mlsd_file_x(payloads, ids,
		[]u32{len: payloads.len, init: u32(payloads[index].len)}, false, buses, times)
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
		recs << le_bytes(math.f64_bits(if times.len > i { times[i] } else { 0.001 * f64(i + 1) }), 8)
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
	img := build_mlsd_file([[u8(1), 2, 3, 4], [u8(5), 6, 7, 8]], [u32(0x100), 0x101], [
		u32(0xFFFFFFF0),
		4,
	])
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
	mut img := build_vlsd_sd_file_w(payloads, [u32(0x100), 0x101], [false, false], [
		0.001,
		0.002,
	], 64)
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
	mut img := build_vlsd_sd_file(payloads, [u32(0x100), 0x101], [false, false], [
		0.001,
		0.002,
	])
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
	mut sd_src := MemSource{
		buf: b.buf
	}
	got := read_data_block(mut sd_src, sd, false) or {
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

// build_remote_frame_file writes one sorted CAN_RemoteFrame group. Records are 14 bytes:
// time f64 @0, ID @8, IDE @12, DLC @13. NO DataBytes and no DataLength channel — a remote frame
// requests data and carries none, which is exactly why the DataFrame lookups missed the group
// and it was skipped in silence (#131).
fn build_remote_frame_file(ids []u32, ides []bool, dlcs []u32, times []f64) []u8 {
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
	for i, x in le_bytes(u64(ids.len), 8) {
		cg_d[8 + i] = x
	}
	for i, x in le_bytes(u64(14), 4) {
		cg_d[24 + i] = x
	}
	cg := b.block('##CG', 6, cg_d)

	cn_t := b.block('##CN', 8, cn_block_data(2, 4, 0, 64))
	cn_fr := b.block('##CN', 8, cn_block_data(0, 10, 8, 0))
	cn_id := b.block('##CN', 8, cn_block_data(0, 0, 8, 32))
	cn_ide := b.block('##CN', 8, cn_block_data(0, 0, 12, 1))
	cn_dlc := b.block('##CN', 8, cn_block_data(0, 0, 13, 8))

	tx_t := b.text('time')
	tx_fr := b.text('CAN_RemoteFrame')
	tx_id := b.text('CAN_RemoteFrame.ID')
	tx_ide := b.text('CAN_RemoteFrame.IDE')
	tx_dlc := b.text('CAN_RemoteFrame.DLC')

	mut recs := []u8{}
	for i, id in ids {
		recs << le_bytes(math.f64_bits(if times.len > i { times[i] } else { 0.001 * f64(i + 1) }), 8)
		recs << le_bytes(u64(id), 4)
		recs << u8(if ides.len > i && ides[i] { 1 } else { 0 })
		recs << u8(dlcs[i])
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
	b.set_link(cn_ide, 0, cn_dlc)
	b.set_link(cn_ide, 2, tx_ide)
	b.set_link(cn_dlc, 2, tx_dlc)
	return b.buf
}

// A remote frame REQUESTS a payload of a stated length and carries none. It used to vanish: the
// group's channels are named CAN_RemoteFrame.*, every CAN_DataFrame lookup missed, and parse_cg
// returned without a word — so identical traffic showed rtr rows when imported from a candump
// and nothing at all from an .mf4 (#131).
fn test_remote_frames_are_imported_not_skipped() {
	buf := build_remote_frame_file([u32(0x123), 0x1ABCDEF], [false, true], [u32(8), 3], [
		0.001,
		0.002,
	])
	es := parse(buf) or {
		assert false, 'a CAN_RemoteFrame group must parse: ${err}'
		return
	}
	assert es.len == 2, 'both remote frames must arrive, got ${es.len}'
	assert es[0].frame.id == 0x123
	assert es[0].frame.rtr, 'a CAN_RemoteFrame group produces remote frames'
	assert !es[0].frame.extended
	assert !es[0].frame.fd, 'CAN-FD has no remote frames'
	// ZERO-FILLED to the requested DLC — the live representation, and what modules/canlog
	// builds from `123#R8`. The two importers must agree about the same traffic.
	assert es[0].frame.data.len == 8
	assert es[0].frame.data == []u8{len: 8}
	assert es[1].frame.id == 0x1ABCDEF
	assert es[1].frame.extended, 'the IDE channel must still be read under the other prefix'
	assert es[1].frame.rtr
	assert es[1].frame.data.len == 3
}

// A DLC above 8 is read the way CLASSIC CAN defines it: codes 9..15 all mean 8 bytes. Read as
// CAN-FD they would mean 12..64, and that reading has to be refused here rather than merely
// avoided — FD has no remote frames at all, so a 64-byte request describes a frame that cannot
// exist on any wire. Decoding it as 8 keeps the frame; decoding it as FD would invent one.
//
// This is the one place the two importers differ, and deliberately: modules/canlog REJECTS the
// whole line for `R9`..`R15`, because there the digit is free text a writer chose and a value
// out of range is evidence the line is malformed. Here the DLC is a fixed-width field a
// recorder filled from the controller, where 9..15 is the ordinary encoding of a frame that
// requested 8 — dropping it would lose a real frame over a legal code.
fn test_a_remote_dlc_above_eight_reads_as_eight() {
	buf := build_remote_frame_file([u32(0x200), 0x201], [false, false], [u32(15), 9], [
		0.001,
		0.002,
	])
	es := parse(buf) or {
		assert false, 'the group must still parse: ${err}'
		return
	}
	assert es.len == 2
	assert es[0].frame.rtr && es[1].frame.rtr
	assert es[0].frame.data.len == 8, 'classic DLC 15 requests 8 bytes'
	assert es[1].frame.data.len == 8, 'and so does 9'
	assert !es[0].frame.fd, 'and neither is FD — that reading is what must never happen'
}

// A DLC that is not a four-bit code at all did not come off a wire, so the requested length is
// unknown — and for a remote frame that means the whole message is unknown, not merely one field
// of it. DROPPED, for the same reason an invalidated DLC is: `R0` is a real request, and
// emitting one here would replay a request the recording never contained.
fn test_a_remote_dlc_outside_the_code_range_drops_the_frame() {
	buf := build_remote_frame_file([u32(0x202)], [false], [u32(200)], [0.001])
	es := parse(buf) or {
		assert false, '${err}'
		return
	}
	assert es.len == 0, 'an unresolvable DLC must not become a request for zero bytes'
}

// Timestamps and ordering come from the same machinery as a data group — the point of
// parameterising the prefix rather than writing a second parser beside it.
fn test_remote_frame_timestamps_are_read() {
	buf := build_remote_frame_file([u32(0x300), 0x301], [false, false], [u32(1), 2], [
		0.25,
		0.75,
	])
	es := parse(buf) or {
		assert false, '${err}'
		return
	}
	assert es.len == 2
	assert es[0].t_s > 0.2 && es[0].t_s < 0.3, 'got ${es[0].t_s}'
	assert es[1].t_s > 0.7 && es[1].t_s < 0.8, 'got ${es[1].t_s}'
	assert es[0].t_s < es[1].t_s
}

// cn_block_data_inval is cn_block_data with an INVALIDATION BIT declared (cn_flags bit 1, and
// the bit's index in the record's invalidation area).
fn cn_block_data_inval(cn_type u8, dtype u8, byte_off u32, bits u32, inval_bit u32) []u8 {
	mut d := cn_block_data(cn_type, dtype, byte_off, bits)
	for i, x in le_bytes(u32(0x02), 4) {
		d[12 + i] = x
	}
	for i, x in le_bytes(inval_bit, 4) {
		d[16 + i] = x
	}
	return d
}

// build_remote_frame_file_both writes a CAN_RemoteFrame group carrying BOTH length channels —
// DLC and DataLength — which is what the standard schemas define. Records are 18 bytes plus one
// invalidation byte: time f64 @0, ID @8, IDE @12, DLC @13, DataLength u32 @14. When
// `dlc_invalid` is set the DLC channel declares invalidation bit 0 and every record sets it.
fn build_remote_frame_file_both(ids []u32, dlcs []u32, datalens []u32, inval string) []u8 {
	dlc_invalid := inval == 'dlc'
	id_invalid := inval == 'id'
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
	for i, x in le_bytes(u64(ids.len), 8) {
		cg_d[8 + i] = x
	}
	for i, x in le_bytes(u64(18), 4) {
		cg_d[24 + i] = x // data bytes per record
	}
	for i, x in le_bytes(u64(1), 4) {
		cg_d[28 + i] = x // one invalidation byte after them
	}
	cg := b.block('##CG', 6, cg_d)

	cn_t := b.block('##CN', 8, cn_block_data(2, 4, 0, 64))
	cn_fr := b.block('##CN', 8, cn_block_data(0, 10, 8, 0))
	cn_id := if id_invalid {
		b.block('##CN', 8, cn_block_data_inval(0, 0, 8, 32, 1))
	} else {
		b.block('##CN', 8, cn_block_data(0, 0, 8, 32))
	}
	cn_ide := b.block('##CN', 8, cn_block_data(0, 0, 12, 1))
	cn_dlc := if dlc_invalid {
		b.block('##CN', 8, cn_block_data_inval(0, 0, 13, 8, 0))
	} else {
		b.block('##CN', 8, cn_block_data(0, 0, 13, 8))
	}
	cn_dl := b.block('##CN', 8, cn_block_data(0, 0, 14, 32))

	tx_t := b.text('time')
	tx_fr := b.text('CAN_RemoteFrame')
	tx_id := b.text('CAN_RemoteFrame.ID')
	tx_ide := b.text('CAN_RemoteFrame.IDE')
	tx_dlc := b.text('CAN_RemoteFrame.DLC')
	tx_dl := b.text('CAN_RemoteFrame.DataLength')

	mut recs := []u8{}
	for i, id in ids {
		recs << le_bytes(math.f64_bits(0.001 * f64(i + 1)), 8)
		recs << le_bytes(u64(id), 4)
		recs << u8(0)
		recs << u8(dlcs[i])
		recs << le_bytes(u64(datalens[i]), 4)
		recs << u8(if dlc_invalid {
			0x01
		} else if id_invalid {
			0x02
		} else {
			0x00
		}) // invalidation area
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
	b.set_link(cn_ide, 0, cn_dlc)
	b.set_link(cn_ide, 2, tx_ide)
	b.set_link(cn_dlc, 0, cn_dl)
	b.set_link(cn_dlc, 2, tx_dlc)
	b.set_link(cn_dl, 2, tx_dl)
	return b.buf
}

// A writer that emits BOTH length channels can record DataLength as 0 — a remote frame carries
// no payload, so there is nothing for a byte count to describe — while the length being REQUESTED
// sits in DLC. Preferring DataLength there imported an `R8` as an `R0` and replayed it as one: a
// request for eight bytes turned into a request for none, which an ECU answers differently or
// not at all (codex #175 r1).
fn test_a_remote_frame_prefers_its_dlc_over_a_zero_datalength() {
	buf := build_remote_frame_file_both([u32(0x400), 0x401], [u32(8), 3], [u32(0), 0], '')
	es := parse(buf) or {
		assert false, '${err}'
		return
	}
	assert es.len == 2
	assert es[0].frame.rtr && es[1].frame.rtr
	assert es[0].frame.data.len == 8, 'DLC 8 is the requested length, not DataLength 0'
	assert es[1].frame.data.len == 3
}

// A record may declare its DLC INVALID, and the bits then hold whatever the writer left there.
// The frame is DROPPED, not emitted with an empty payload: for a remote frame the DLC IS the
// message, so `R0` is not "an R8 with the length withheld" — it is a different request, and one
// an ECU answers differently or not at all. These entries get replayed onto real buses, so an
// invented request is traffic no recording ever contained. Emitting it empty was this branch's
// first attempt, and it turned a stale R8 into a confident R0 (codex #175 r2).
fn test_a_remote_frame_with_an_invalid_dlc_is_dropped() {
	buf := build_remote_frame_file_both([u32(0x402)], [u32(8)], [u32(0)], 'dlc')
	es := parse(buf) or {
		assert false, '${err}'
		return
	}
	assert es.len == 0, 'an unknown requested length must not become a request for none'
}

// The same rule for the frame's IDENTITY, and it is not a remote-frame question: an id is not
// something a frame can lack, and IDE decides whether it is 11 or 29 bits. An invalidated one
// read anyway puts a frame on the bus under an id the recording never stated.
fn test_a_frame_with_an_invalid_id_is_dropped() {
	buf := build_remote_frame_file_both([u32(0x403)], [u32(8)], [u32(0)], 'id')
	es := parse(buf) or {
		assert false, '${err}'
		return
	}
	assert es.len == 0, 'an undefined id must not be replayed as a plausible one'
}

// ---- the stream (docs/streaming_replay.md, PR 1) ----
//
// The golden rule: whatever image or file the loader reads, the stream yields the same rows in
// the same order. Bus labels are compared by NAME — the stream interns them as its merge meets
// them, the loader as it walks groups, so the indices differ while the rows do not.

fn same_log(a canlog.Log, b canlog.Log) bool {
	if a.len() != b.len() {
		eprintln('lengths differ: ${a.len()} vs ${b.len()}')
		return false
	}
	for i in 0 .. a.len() {
		x := a.at(i)
		y := b.at(i)
		if x.t_s != y.t_s || x.iface != y.iface || x.dir != y.dir || x.frame.id != y.frame.id
			|| x.frame.extended != y.frame.extended || x.frame.rtr != y.frame.rtr
			|| x.frame.fd != y.frame.fd || x.frame.brs != y.frame.brs || x.frame.esi != y.frame.esi
			|| x.frame.data != y.frame.data {
			eprintln('row ${i} differs: ${x} vs ${y}')
			return false
		}
	}
	return true
}

fn stream_image(buf []u8) canlog.Log {
	mut src := MemSource{
		buf: buf
	}
	return stream_log(mut src) or { panic('stream: ${err}') }
}

// mlsd_records spells the 25-byte inline-payload records build_mlsd_file writes.
fn mlsd_records(payloads [][]u8, ids []u32, times []f64) []u8 {
	mut recs := []u8{}
	for i, p in payloads {
		recs << le_bytes(math.f64_bits(times[i]), 8)
		recs << le_bytes(u64(ids[i]), 4)
		recs << u8(0)
		recs << le_bytes(u64(p.len), 4)
		mut pad := p.clone()
		for pad.len < 8 {
			pad << 0
		}
		recs << pad[..8]
	}
	return recs
}

// mlsd_group adds the HD/DG/CG and the CAN_DataFrame channel chain of a 25-byte MLSD group,
// leaving the data link (DG link 2) for the caller; returns the DG block.
fn mlsd_group(mut b Mdf4Builder, cycles int, rec_id_size u8) (u64, u64) {
	b.buf << 'MDF     '.bytes()
	b.buf << '4.10    '.bytes()
	b.buf << 'blobly  '.bytes()
	b.buf << []u8{len: 4}
	b.buf << le_bytes(410, 2)
	b.buf << []u8{len: 34}
	hd := b.block('##HD', 6, []u8{len: 32})
	mut dg_d := []u8{len: 8}
	dg_d[0] = rec_id_size
	dg := b.block('##DG', 4, dg_d)
	cg := mlsd_cg(mut b, cycles, 0)
	b.set_link(hd, 0, dg)
	b.set_link(dg, 1, cg)
	return hd, dg
}

// mlsd_cg is one 25-byte MLSD channel group with its channel chain; `rec_id` for an unsorted DG.
fn mlsd_cg(mut b Mdf4Builder, cycles int, rec_id u64) u64 {
	mut cg_d := []u8{len: 32}
	for i, x in le_bytes(rec_id, 8) {
		cg_d[i] = x
	}
	for i, x in le_bytes(u64(cycles), 8) {
		cg_d[8 + i] = x
	}
	for i, x in le_bytes(25, 4) {
		cg_d[24 + i] = x
	}
	cg := b.block('##CG', 6, cg_d)
	cn_t := b.block('##CN', 8, cn_block_data(2, 4, 0, 64))
	cn_fr := b.block('##CN', 8, cn_block_data(0, 10, 8, 0))
	cn_id := b.block('##CN', 8, cn_block_data(0, 0, 8, 32))
	cn_ide := b.block('##CN', 8, cn_block_data(0, 0, 12, 1))
	cn_len := b.block('##CN', 8, cn_block_data(0, 0, 13, 32))
	cn_db := b.block('##CN', 8, cn_block_data(5, 10, 17, 64))
	tx_t := b.text('time')
	tx_fr := b.text('CAN_DataFrame')
	tx_id := b.text('CAN_DataFrame.ID')
	tx_ide := b.text('CAN_DataFrame.IDE')
	tx_len := b.text('CAN_DataFrame.DataLength')
	tx_db := b.text('CAN_DataFrame.DataBytes')
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
	return cg
}

// build_dl_file: the record stream split over TWO DT blocks reached through a DL list, cut at
// byte `split` — inside a record, so one record straddles the blocks.
fn build_dl_file(payloads [][]u8, ids []u32, times []f64, split int) []u8 {
	mut b := Mdf4Builder{}
	_, dg := mlsd_group(mut b, payloads.len, 0)
	recs := mlsd_records(payloads, ids, times)
	dt1 := b.block('##DT', 0, recs[..split])
	dt2 := b.block('##DT', 0, recs[split..])
	// DLBLOCK: links [next, data 1, data 2]; data section: flags u8, reserved[3], count u32
	mut dl_d := []u8{len: 8}
	for i, x in le_bytes(2, 4) {
		dl_d[4 + i] = x
	}
	dl := b.block('##DL', 3, dl_d)
	b.set_link(dl, 1, dt1)
	b.set_link(dl, 2, dt2)
	b.set_link(dg, 2, dl)
	return b.buf
}

// build_dz_file: the record stream in one DZ block, deflated — zip_type 0 as is, zip_type 1
// after the byte-column transposition MDF applies with the record size as the column count.
fn build_dz_file(payloads [][]u8, ids []u32, times []f64, zip_type u8) []u8 {
	mut b := Mdf4Builder{}
	_, dg := mlsd_group(mut b, payloads.len, 0)
	recs := mlsd_records(payloads, ids, times)
	mut plain := recs.clone()
	cols := 25
	if zip_type == 1 {
		rows := recs.len / cols
		for r := 0; r < rows; r++ {
			for c := 0; c < cols; c++ {
				plain[c * rows + r] = recs[r * cols + c]
			}
		}
	}
	comp := zlib.compress(plain) or { panic(err) }
	mut dz_d := []u8{}
	dz_d << 'DT'.bytes()
	dz_d << zip_type
	dz_d << 0
	dz_d << le_bytes(u64(cols), 4)
	dz_d << le_bytes(u64(recs.len), 8)
	dz_d << le_bytes(u64(comp.len), 8)
	dz_d << comp
	dz := b.block('##DZ', 0, dz_d)
	b.set_link(dg, 2, dz)
	return b.buf
}

// URec is one record of an unsorted fixture: which channel group, and its frame.
struct URec {
	cg      int
	t       f64
	id      u32
	payload []u8
}

// build_unsorted_file: one DG with rec_id_size 1 and two 25-byte MLSD channel groups (record ids
// 1 and 2), the records interleaved in the order given — which may skew the groups in time.
fn build_unsorted_file(recs []URec) []u8 {
	mut b := Mdf4Builder{}
	b.buf << 'MDF     '.bytes()
	b.buf << '4.10    '.bytes()
	b.buf << 'blobly  '.bytes()
	b.buf << []u8{len: 4}
	b.buf << le_bytes(410, 2)
	b.buf << []u8{len: 34}
	hd := b.block('##HD', 6, []u8{len: 32})
	mut dg_d := []u8{len: 8}
	dg_d[0] = 1
	dg := b.block('##DG', 4, dg_d)
	mut n0 := 0
	mut n1 := 0
	for r in recs {
		if r.cg == 0 {
			n0++
		} else {
			n1++
		}
	}
	cg0 := mlsd_cg(mut b, n0, 1)
	cg1 := mlsd_cg(mut b, n1, 2)
	mut stream := []u8{}
	for r in recs {
		stream << u8(r.cg + 1)
		stream << mlsd_records([r.payload], [r.id], [r.t])
	}
	dt := b.block('##DT', 0, stream)
	b.set_link(hd, 0, dg)
	b.set_link(dg, 1, cg0)
	b.set_link(cg0, 0, cg1)
	b.set_link(dg, 2, dt)
	return b.buf
}

// unfinalize marks an image UnFinMF with a stale (understated) length on its last DT block —
// the shape a logger that lost power leaves behind.
fn unfinalize(buf []u8) []u8 {
	mut out := buf.clone()
	for i, x in 'UnFinMF '.bytes() {
		out[i] = x
	}
	dt := find_block(out, '##DT')
	for i, x in le_bytes(24, 8) {
		out[dt + 8 + i] = x
	}
	return out
}

fn three() ([][]u8, []u32, []f64) {
	return [[u8(1), 2, 3], [u8(4), 5, 6, 7, 8], [u8(9)]], [u32(0x100), 0x200, 0x300], [
		0.010,
		0.020,
		0.030,
	]
}

fn test_the_stream_reproduces_the_loader_on_every_image() {
	p, ids, ts := three()
	images := [
		build_mlsd_file(p, ids, [u32(3), 5, 1]),
		build_mlsd_multibus(p, ids, [u32(0), 2, 0], [0.010, 0.010, 0.020]),
		build_vlsd_sd_file(p, ids, [false, true, false], ts),
		build_remote_frame_file([u32(0x200), 0x201], [false, true], [u32(8), 3], [0.010, 0.011]),
		build_dl_file(p, ids, ts, 30), // cut inside the second record
		build_dz_file(p, ids, ts, 0),
		build_dz_file(p, ids, ts, 1),
		unfinalize(build_mlsd_file(p, ids, [u32(3), 5, 1])),
	]
	for k, img in images {
		want := parse_log(img) or { panic('image ${k}: ${err}') }
		assert want.len() > 0, 'image ${k} decodes to nothing'
		got := stream_image(img)
		assert same_log(got, want), 'image ${k}'
	}
}

fn test_the_stream_reproduces_the_loader_on_the_samples() {
	for path in [demo_path, two_bus_path, @VMODROOT + '/samples/both_dirs.mf4',
		@VMODROOT + '/samples/driving.mf4'] {
		if !os.exists(path) {
			println('skip: ${path} not present')
			continue
		}
		buf := os.read_bytes(path) or { panic(err) }
		want := parse_log(buf) or { panic(err) }
		// through the file, as the player will read it
		mut src := open_source(path) or { panic(err) }
		got := stream_log(mut src) or { panic(err) }
		src.close()
		assert same_log(got, want), path
		assert got.len() > 0
	}
}

fn test_an_unsorted_group_is_merged_in_time_order_with_ties_by_position() {
	// group 0 skews ahead of group 1 in the stream; two records share 0.040 and the stream
	// order — group 1's first — must decide it
	recs := [
		URec{0, 0.010, 0x100, [u8(1)]},
		URec{0, 0.030, 0x101, [u8(2)]},
		URec{1, 0.020, 0x200, [u8(3)]},
		URec{1, 0.040, 0x201, [u8(4)]},
		URec{0, 0.040, 0x102, [u8(5)]},
		URec{1, 0.050, 0x202, [u8(6)]},
	]
	img := build_unsorted_file(recs)
	want := parse_log(img) or { panic(err) }
	got := stream_image(img)
	assert same_log(got, want)
	mut ids := []u32{}
	for i in 0 .. got.len() {
		ids << got.at(i).frame.id
	}
	assert ids == [u32(0x100), 0x200, 0x101, 0x201, 0x102, 0x202]
	// the two groups of one data group are two buses, named by group ordinal
	assert got.at(0).iface == 'mf4:group0'
	assert got.at(1).iface == 'mf4:group1'
}

fn test_a_record_straddling_blocks_and_chunks_is_read_whole() {
	p, ids, ts := three()
	img := build_dl_file(p, ids, ts, 30)
	mut src := MemSource{
		buf: img
	}
	mut s := open_stream(mut src) or { panic(err) }
	// force the sequential reader to fetch a few bytes at a time, so every record crosses a
	// chunk boundary as well as the block boundary
	mut c0 := s.cursors[0]
	if mut c0 is SortedCursor {
		c0.recs.chunk = 7
	}
	mut log := canlog.Log{}
	mut n := 0
	for {
		r := s.next(mut log) or { break }
		log.rows << r
		n++
	}
	assert n == 3
	want := parse_log(img) or { panic(err) }
	assert same_log(log, want)
}

fn test_the_chain_view_reads_across_block_boundaries() {
	bytes := []u8{len: 40, init: u8(index)}
	mut src := MemSource{
		buf: bytes
	}
	blocks := [
		ChainBlock{
			off:     0
			len:     16
			logical: 0
		},
		ChainBlock{
			off:     16
			len:     24
			logical: 16
		},
	]
	mut v := new_chain_view(mut src, blocks)
	assert v.at(14, 4)? == [u8(14), 15, 16, 17]
	assert v.at(0, 40)?.len == 40
	assert v.at(38, 2)? == [u8(38), 39]
	assert v.at(38, 3) == none // past the chain
	assert v.at(40, 1) == none
	assert v.at(41, 0) == none
}

fn test_the_vlsd_ring_releases_its_front_and_counts_what_it_lost() {
	mut r := RingVlsd{
		cap: 16
	}
	r.append([]u8{len: 10, init: u8(index)})
	assert r.at(2, 3)? == [u8(2), 3, 4]
	r.append([]u8{len: 10, init: u8(10 + index)})
	// 20 bytes over a cap of 16: the front half went
	assert r.base == 10
	assert r.at(2, 3) == none
	assert r.evicted == 1
	assert r.at(12, 2)? == [u8(12), 13]
	assert r.at(19, 2) == none // past the end
}

fn test_reading_ahead_past_the_cap_is_forced_and_counted() {
	// group 1's only record comes after more group-0 records than the merge will queue: the
	// merge emits group 0 anyway, counts that it had to, and the order is still the loader's
	mut recs := []URec{}
	for i in 0 .. unsorted_readahead + 100 {
		recs << URec{0, 0.001 * f64(i + 1), 0x100, [u8(i)]}
	}
	recs << URec{1, 100.0, 0x200, [u8(9)]}
	img := build_unsorted_file(recs)
	mut src := MemSource{
		buf: img
	}
	mut s := open_stream(mut src) or { panic(err) }
	mut log := canlog.Log{}
	for {
		r := s.next(mut log) or { break }
		log.rows << r
	}
	assert s.forced > 0
	want := parse_log(img) or { panic(err) }
	assert same_log(log, want)
}

fn test_the_stream_rejects_what_is_not_an_mdf() {
	mut src := MemSource{
		buf: []u8{len: 100}
	}
	if _ := open_stream(mut src) {
		assert false, 'opened'
	}
	mut tiny := MemSource{
		buf: []u8{len: 10}
	}
	if _ := open_stream(mut tiny) {
		assert false, 'opened'
	}
}

// ---- the stream, continued: the paths the first golden list missed (self-review of step 1) ----

// vlsd_layout_cg adds an 18-byte VLSD-offset channel group (time f64 @0, ID u32 @8, IDE @12,
// DataLength @13, DataBytes offset u32 @14) with its channel chain; `rec_id` for an unsorted
// group. Returns the CG block and the DataBytes channel, whose cn_data the caller links.
fn vlsd_layout_cg(mut b Mdf4Builder, cycles int, rec_id u64) (u64, u64) {
	mut cg_d := []u8{len: 32}
	for i, x in le_bytes(rec_id, 8) {
		cg_d[i] = x
	}
	for i, x in le_bytes(u64(cycles), 8) {
		cg_d[8 + i] = x
	}
	for i, x in le_bytes(18, 4) {
		cg_d[24 + i] = x
	}
	cg := b.block('##CG', 6, cg_d)
	cn_t := b.block('##CN', 8, cn_block_data(2, 4, 0, 64))
	cn_fr := b.block('##CN', 8, cn_block_data(0, 10, 8, 0))
	cn_id := b.block('##CN', 8, cn_block_data(0, 0, 8, 32))
	cn_ide := b.block('##CN', 8, cn_block_data(0, 0, 12, 1))
	cn_len := b.block('##CN', 8, cn_block_data(0, 0, 13, 8))
	cn_db := b.block('##CN', 8, cn_block_data(1, 10, 14, 32))
	tx_t := b.text('time')
	tx_fr := b.text('CAN_DataFrame')
	tx_id := b.text('CAN_DataFrame.ID')
	tx_ide := b.text('CAN_DataFrame.IDE')
	tx_len := b.text('CAN_DataFrame.DataLength')
	tx_db := b.text('CAN_DataFrame.DataBytes')
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
	return cg, cn_db
}

fn vlsd_record(t f64, id u32, ext bool, len int, off u32) []u8 {
	mut r := []u8{}
	r << le_bytes(math.f64_bits(t), 8)
	r << le_bytes(u64(id), 4)
	r << u8(if ext { 1 } else { 0 })
	r << u8(len)
	r << le_bytes(u64(off), 4)
	return r
}

// build_unsorted_vlsd_file: the CANedge shape — one unsorted data group whose frame group
// (record id 1) keeps its payloads in a VLSD channel group (record id 2) of the same stream,
// each payload record written immediately before the frame record that names it by offset into
// the concatenation of the VLSD group's records (length prefixes included).
fn build_unsorted_vlsd_file(payloads [][]u8, ids []u32, times []f64) []u8 {
	mut b := Mdf4Builder{}
	b.buf << 'MDF     '.bytes()
	b.buf << '4.10    '.bytes()
	b.buf << 'blobly  '.bytes()
	b.buf << []u8{len: 4}
	b.buf << le_bytes(410, 2)
	b.buf << []u8{len: 34}
	hd := b.block('##HD', 6, []u8{len: 32})
	mut dg_d := []u8{len: 8}
	dg_d[0] = 1
	dg := b.block('##DG', 4, dg_d)
	cg_frames, cn_db := vlsd_layout_cg(mut b, payloads.len, 1)
	// the VLSD group: record id 2, cg_flags bit 0
	mut vcg_d := []u8{len: 32}
	vcg_d[0] = 2
	vcg_d[16] = 1
	cg_vlsd := b.block('##CG', 6, vcg_d)
	mut stream := []u8{}
	mut off := u32(0)
	for i, p in payloads {
		stream << u8(2)
		stream << le_bytes(u64(p.len), 4)
		stream << p
		stream << u8(1)
		stream << vlsd_record(times[i], ids[i], false, p.len, off)
		off += u32(4 + p.len)
	}
	dt := b.block('##DT', 0, stream)
	b.set_link(hd, 0, dg)
	b.set_link(dg, 1, cg_frames)
	b.set_link(cg_frames, 0, cg_vlsd)
	b.set_link(cn_db, 5, cg_vlsd) // cn_data names the VLSD channel GROUP
	b.set_link(dg, 2, dt)
	return b.buf
}

// build_vlsd_dz_chain_file: a sorted VLSD group whose signal data is a DL list of two DZ blocks,
// the cut at byte `split` of the payload stream — inside a payload, so one payload is read
// across two inflated blocks.
fn build_vlsd_dz_chain_file(payloads [][]u8, ids []u32, times []f64, split int) []u8 {
	mut b := Mdf4Builder{}
	b.buf << 'MDF     '.bytes()
	b.buf << '4.10    '.bytes()
	b.buf << 'blobly  '.bytes()
	b.buf << []u8{len: 4}
	b.buf << le_bytes(410, 2)
	b.buf << []u8{len: 34}
	hd := b.block('##HD', 6, []u8{len: 32})
	dg := b.block('##DG', 4, []u8{len: 8})
	cg, cn_db := vlsd_layout_cg(mut b, payloads.len, 0)
	mut sd := []u8{}
	mut offs := []u32{}
	for p in payloads {
		offs << u32(sd.len)
		sd << le_bytes(u64(p.len), 4)
		sd << p
	}
	dz1 := dz_block(mut b, 'SD', sd[..split])
	dz2 := dz_block(mut b, 'SD', sd[split..])
	mut dl_d := []u8{len: 8}
	for i, x in le_bytes(2, 4) {
		dl_d[4 + i] = x
	}
	dl := b.block('##DL', 3, dl_d)
	b.set_link(dl, 1, dz1)
	b.set_link(dl, 2, dz2)
	mut recs := []u8{}
	for i, p in payloads {
		recs << vlsd_record(times[i], ids[i], i % 2 == 1, p.len, offs[i])
	}
	dt := b.block('##DT', 0, recs)
	b.set_link(hd, 0, dg)
	b.set_link(dg, 1, cg)
	b.set_link(dg, 2, dt)
	b.set_link(cn_db, 5, dl)
	return b.buf
}

// dz_block appends a zip_type-0 DZ block over `plain`.
fn dz_block(mut b Mdf4Builder, org string, plain []u8) u64 {
	comp := zlib.compress(plain) or { panic(err) }
	mut d := []u8{}
	d << org.bytes()
	d << 0
	d << 0
	d << le_bytes(0, 4)
	d << le_bytes(u64(plain.len), 8)
	d << le_bytes(u64(comp.len), 8)
	d << comp
	return b.block('##DZ', 0, d)
}

fn test_the_stream_reproduces_the_loader_on_the_rest_of_the_builders() {
	p, ids, ts := three()
	images := [
		build_vlsd_sd_file_w(p, ids, [false, true, false], ts, 64), // 64-bit offsets
		build_vlsd_sd_file_dlc(p, ids, [false, true, false], ts, [u32(3), 5, 1]), // DLC, not DataLength
		build_mlsd_file_m(p, ids, [u32(3), 5, 1], true),
		build_remote_frame_file_both([u32(0x400), 0x401], [u32(8), 3], [u32(0), 0], ''),
		build_remote_frame_file_both([u32(0x402)], [u32(8)], [u32(0)], 'dlc'), // invalidated: refused
		build_unsorted_vlsd_file(p, ids, ts),
		build_vlsd_dz_chain_file(p, ids, ts, 10), // the cut inside the second payload's bytes
	]
	for k, img in images {
		want := parse_log(img) or { panic('image ${k}: ${err}') }
		got := stream_image(img)
		assert same_log(got, want), 'image ${k}'
	}
	// and the two shapes above decoded payloads, not just identities
	un := stream_image(build_unsorted_vlsd_file(p, ids, ts))
	assert un.len() == 3
	assert un.at(1).frame.data == [u8(4), 5, 6, 7, 8]
	dz := stream_image(build_vlsd_dz_chain_file(p, ids, ts, 10))
	assert dz.len() == 3
	assert dz.at(1).frame.data == [u8(4), 5, 6, 7, 8]
	assert dz.at(2).frame.data == [u8(9)]
}

fn test_a_corrupt_vlsd_length_in_an_unsorted_stream_costs_the_tail_not_the_process() {
	p, ids, ts := three()
	mut img := build_unsorted_vlsd_file(p, ids, ts)
	// the second payload record's length prefix: 0xFFFFFFF0, the filler an unfinalized file's
	// extended block decodes as records
	dt := find_block(img, '##DT')
	d := dt + 24 // data section of a DT with no links
	// record 1: id(1) + len(4) + 3 bytes + id(1) + 18 = 27 bytes; record 2's prefix follows
	for i, x in le_bytes(0xFFFFFFF0, 4) {
		img[d + 27 + 1 + i] = x
	}
	want := parse_log(img) or { panic(err) }
	mut src := MemSource{
		buf: img
	}
	mut s := open_stream(mut src) or { panic(err) }
	mut log := canlog.Log{}
	for {
		r := s.next(mut log) or { break }
		log.rows << r
	}
	assert same_log(log, want) // the loader stops at the same record
	assert log.len() == 1
	assert s.err == '' // a corrupt tail is where the recording ends, not a failure
}

fn test_a_duplicate_record_id_is_read_as_the_loader_reads_it() {
	recs := [
		URec{0, 0.010, 0x100, [u8(1)]},
		URec{1, 0.020, 0x200, [u8(2)]},
	]
	mut img := build_unsorted_file(recs)
	// make the second channel group claim record id 1 too: cg_record_id is the first u64 of
	// the CG data section; the second CG is the second '##CG' in the image
	first := find_block(img, '##CG')
	mut second := first + 4
	for img[second..second + 4].bytestr() != '##CG' {
		second++
	}
	img[second + 24 + 8 * 6] = 1
	want := parse_log(img) or { panic(err) }
	got := stream_image(img)
	assert same_log(got, want)
}

fn test_a_broken_block_is_an_error_not_a_clean_end() {
	p, ids, ts := three()
	mut img := build_dz_file(p, ids, ts, 0)
	// corrupt the compressed bytes: zlib fails, the loader fails whole, the stream says why
	dz := find_block(img, '##DZ')
	img[dz + 24 + 24 + 2] = 0xFF
	img[dz + 24 + 24 + 3] = 0xFF
	if _ := parse_log(img) {
		assert false, 'the loader accepted a broken DZ block'
	}
	mut src := MemSource{
		buf: img
	}
	if _ := stream_log(mut src) {
		assert false, 'the stream accepted a broken DZ block'
	}
	mut src2 := MemSource{
		buf: img
	}
	mut s := open_stream(mut src2) or { panic(err) }
	mut log := canlog.Log{}
	for {
		_ := s.next(mut log) or { break }
	}
	assert s.err.contains('DZ') || s.err.contains('zlib') || s.err != ''
}

fn test_a_group_whose_time_runs_backwards_is_counted() {
	p, ids, _ := three()
	img := build_mlsd_multibus(p, ids, [u32(0), 0, 0], [0.030, 0.010, 0.020])
	mut src := MemSource{
		buf: img
	}
	mut s := open_stream(mut src) or { panic(err) }
	mut log := canlog.Log{}
	for {
		r := s.next(mut log) or { break }
		log.rows << r
	}
	assert log.len() == 3
	assert s.out_of_order == 1 // 0.030 then 0.010; the loader would have sorted it
}

// ---- the stream, round 1 of #342: what a loader that demuxes the whole stream never notices ----

// build_unsorted_vlsd_raw is build_unsorted_vlsd_file with the record stream spelled by the
// caller, so a test can write a payload record AFTER the frame that names it, a record too large
// to be a payload in the middle, or more frame records than the group declares.
fn build_unsorted_vlsd_raw(stream []u8, cycles int) []u8 {
	return build_unsorted_vlsd_raw_x(stream, cycles, 0, false)
}

// build_unsorted_vlsd_raw_x adds a third fixed group (record id 3, `junk` bytes a record, no
// channels — a group this reader does not decode) when junk > 0, and puts the stream in a DL of
// two DZ blocks split at its midpoint when dz is set.
fn build_unsorted_vlsd_raw_x(stream []u8, cycles int, junk int, dz bool) []u8 {
	mut b := Mdf4Builder{}
	b.buf << 'MDF     '.bytes()
	b.buf << '4.10    '.bytes()
	b.buf << 'blobly  '.bytes()
	b.buf << []u8{len: 4}
	b.buf << le_bytes(410, 2)
	b.buf << []u8{len: 34}
	hd := b.block('##HD', 6, []u8{len: 32})
	mut dg_d := []u8{len: 8}
	dg_d[0] = 1
	dg := b.block('##DG', 4, dg_d)
	cg_frames, cn_db := vlsd_layout_cg(mut b, cycles, 1)
	mut vcg_d := []u8{len: 32}
	vcg_d[0] = 2
	vcg_d[16] = 1
	cg_vlsd := b.block('##CG', 6, vcg_d)
	if junk > 0 {
		mut jcg_d := []u8{len: 32}
		jcg_d[0] = 3
		for i, x in le_bytes(u64(junk), 4) {
			jcg_d[24 + i] = x
		}
		jcg := b.block('##CG', 6, jcg_d)
		b.set_link(cg_vlsd, 0, jcg)
	}
	data := if dz {
		half := stream.len / 2
		dz1 := dz_block(mut b, 'DT', stream[..half])
		dz2 := dz_block(mut b, 'DT', stream[half..])
		mut dl_d := []u8{len: 8}
		for i, x in le_bytes(2, 4) {
			dl_d[4 + i] = x
		}
		dl := b.block('##DL', 3, dl_d)
		b.set_link(dl, 1, dz1)
		b.set_link(dl, 2, dz2)
		dl
	} else {
		b.block('##DT', 0, stream)
	}
	b.set_link(hd, 0, dg)
	b.set_link(dg, 1, cg_frames)
	b.set_link(cg_frames, 0, cg_vlsd)
	b.set_link(cn_db, 5, cg_vlsd)
	b.set_link(dg, 2, data)
	return b.buf
}

// vjunk is one record of the third group: id 3 and `n` zero bytes.
fn vjunk(n int) []u8 {
	mut r := [u8(3)]
	r << []u8{len: n}
	return r
}

// vpay is one VLSD record (record id 2) in that stream; vframe one frame record (record id 1).
fn vpay(p []u8) []u8 {
	mut r := [u8(2)]
	r << le_bytes(u64(p.len), 4)
	r << p
	return r
}

fn vframe(t f64, id u32, len int, off u32) []u8 {
	mut r := [u8(1)]
	r << vlsd_record(t, id, false, len, off)
	return r
}

fn drain(img []u8) (canlog.Log, Stream) {
	mut src := MemSource{
		buf: img
	}
	mut s := open_stream(mut src) or { panic(err) }
	mut log := canlog.Log{}
	for {
		r := s.next(mut log) or { break }
		log.rows << r
	}
	return log, s
}

fn test_a_frame_whose_payload_comes_later_waits_for_it() {
	p, ids, ts := three()
	// frames 0 and 1 name payloads written after them; frame 2 names one written before it
	mut stream := []u8{}
	stream << vframe(ts[0], ids[0], p[0].len, 0)
	stream << vframe(ts[1], ids[1], p[1].len, u32(4 + p[0].len))
	stream << vpay(p[0])
	stream << vpay(p[1])
	stream << vpay(p[2])
	stream << vframe(ts[2], ids[2], p[2].len, u32(8 + p[0].len + p[1].len))
	img := build_unsorted_vlsd_raw(stream, 3)
	want := parse_log(img) or { panic(err) }
	assert want.len() == 3 // the loader demuxes the whole stream first and has every payload
	assert want.at(0).frame.data == p[0]
	assert want.at(1).frame.data == p[1]
	log, s := drain(img)
	assert same_log(log, want)
	assert s.unresolved == 0
	assert s.evicted == 0
	assert s.err == ''
}

fn test_a_payload_that_never_arrives_is_counted_at_the_end() {
	p, ids, ts := three()
	mut stream := []u8{}
	stream << vpay(p[0])
	stream << vframe(ts[0], ids[0], p[0].len, 0)
	stream << vframe(ts[1], ids[1], p[1].len, 1000) // names bytes the stream never carries
	img := build_unsorted_vlsd_raw(stream, 2)
	want := parse_log(img) or { panic(err) }
	assert want.len() == 2
	assert want.at(1).frame.data.len == 0 // the loader finds nothing at that offset either
	log, s := drain(img)
	assert same_log(log, want)
	assert s.unresolved == 1
	assert s.err == ''
}

fn test_a_record_too_large_to_be_a_payload_is_stepped_over_not_buffered() {
	p, ids, ts := three()
	big := int(max_vlsd_record)
	mut stream := []u8{}
	stream << vpay(p[0])
	stream << vframe(ts[0], ids[0], p[0].len, 0)
	off1 := u32(4 + p[0].len)
	stream << vpay([]u8{len: big}) // some other signal's record, in the payload group's stream
	stream << vframe(ts[1], ids[1], 8, off1) // names it: no CAN payload, in either reader
	off2 := off1 + u32(4 + big)
	stream << vpay(p[2])
	stream << vframe(ts[2], ids[2], p[2].len, off2)
	img := build_unsorted_vlsd_raw(stream, 3)
	want := parse_log(img) or { panic(err) }
	assert want.len() == 3
	assert want.at(1).frame.data.len == 0
	assert want.at(2).frame.data == p[2] // the offsets after the big record are the writer's
	log, s := drain(img)
	assert same_log(log, want)
	assert s.evicted == 1 // the stream released it instead of holding it; said, not hidden
	assert s.err == ''
}

fn test_an_unsorted_group_honours_the_declared_cycle_count_as_the_loader_does() {
	p, ids, ts := three()
	mut stream := []u8{}
	mut off := u32(0)
	for i, x in p {
		stream << vpay(x)
		stream << vframe(ts[i], ids[i], x.len, off)
		off += u32(4 + x.len)
	}
	img := build_unsorted_vlsd_raw(stream, 2) // declares two records, carries three; finalized
	want := parse_log(img) or { panic(err) }
	assert want.len() == 2
	log, s := drain(img)
	assert same_log(log, want)
	assert s.err == ''
	// the same stream unfinalized reads every record, in both
	unfin := unfinalize(img)
	want2 := parse_log(unfin) or { panic(err) }
	assert want2.len() == 3
	log2, _ := drain(unfin)
	assert same_log(log2, want2)
}

fn test_a_broken_signal_data_block_stops_the_cursor() {
	p, ids, ts := three()
	mut img := build_vlsd_dz_chain_file(p, ids, ts, 5)
	dz := find_block(img, '##DZ')
	img[dz + 24 + 24 + 2] = 0xFF
	img[dz + 24 + 24 + 3] = 0xFF
	if _ := parse_log(img) {
		assert false, 'the loader accepted a broken signal-data block'
	}
	mut src := MemSource{
		buf: img
	}
	if _ := stream_log(mut src) {
		assert false, 'the stream accepted a broken signal-data block'
	}
	log, s := drain(img)
	assert log.len() == 0 // the first frame's payload is in the broken block: nothing was stated
	assert s.err.contains('signal data')
}

// ShortSource claims a whole image but reads nothing past `limit`: a file truncated under the
// reader, or a read that failed.
struct ShortSource {
mut:
	buf   []u8
	limit u64
}

fn (mut s ShortSource) read_at(off u64, mut dst []u8) !int {
	if off >= s.limit {
		return 0
	}
	mut n := dst.len
	if u64(n) > s.limit - off {
		n = int(s.limit - off)
	}
	if n > 0 {
		unsafe { vmemcpy(dst.data, &s.buf[int(off)], n) }
	}
	return n
}

fn (mut s ShortSource) size() u64 {
	return u64(s.buf.len)
}

fn test_a_short_read_inside_a_block_is_an_error_not_the_end() {
	p, ids, _ := three()
	img := build_mlsd_file(p, ids, [u32(1), 2, 3])
	dt := find_block(img, '##DT')
	mut src := ShortSource{
		buf:   img
		limit: u64(dt + 24 + 30) // inside the second record
	}
	if _ := stream_log(mut src) {
		assert false, 'a short read was read as the end of the recording'
	}
	mut src2 := ShortSource{
		buf:   img
		limit: u64(dt + 24 + 30)
	}
	mut s := open_stream(mut src2) or { panic(err) }
	mut log := canlog.Log{}
	for {
		r := s.next(mut log) or { break }
		log.rows << r
	}
	assert log.len() == 0 // the first chunk failed whole; nothing was handed out as read
	assert s.err.contains('short read')
}

// ---- the stream, round 2 of #342 ----

// build_unsorted_vlsd_dz_chain_file: build_vlsd_dz_chain_file as an UNSORTED data group — the
// frame records prefixed with record id 1, the payloads in a DL-of-DZ signal-data chain the
// DataBytes channel names directly. The format allows it, the loader reads it, and the stream
// reads it through a view (UnsortedCursor.views).
fn build_unsorted_vlsd_dz_chain_file(payloads [][]u8, ids []u32, times []f64, split int) []u8 {
	mut b := Mdf4Builder{}
	b.buf << 'MDF     '.bytes()
	b.buf << '4.10    '.bytes()
	b.buf << 'blobly  '.bytes()
	b.buf << []u8{len: 4}
	b.buf << le_bytes(410, 2)
	b.buf << []u8{len: 34}
	hd := b.block('##HD', 6, []u8{len: 32})
	mut dg_d := []u8{len: 8}
	dg_d[0] = 1
	dg := b.block('##DG', 4, dg_d)
	cg, cn_db := vlsd_layout_cg(mut b, payloads.len, 1)
	mut sd := []u8{}
	mut offs := []u32{}
	for p in payloads {
		offs << u32(sd.len)
		sd << le_bytes(u64(p.len), 4)
		sd << p
	}
	dz1 := dz_block(mut b, 'SD', sd[..split])
	dz2 := dz_block(mut b, 'SD', sd[split..])
	mut dl_d := []u8{len: 8}
	for i, x in le_bytes(2, 4) {
		dl_d[4 + i] = x
	}
	dl := b.block('##DL', 3, dl_d)
	b.set_link(dl, 1, dz1)
	b.set_link(dl, 2, dz2)
	mut recs := []u8{}
	for i, p in payloads {
		recs << u8(1)
		recs << vlsd_record(times[i], ids[i], i % 2 == 1, p.len, offs[i])
	}
	dt := b.block('##DT', 0, recs)
	b.set_link(hd, 0, dg)
	b.set_link(dg, 1, cg)
	b.set_link(dg, 2, dt)
	b.set_link(cn_db, 5, dl)
	return b.buf
}

fn test_an_unsorted_group_reading_a_signal_data_chain_equals_the_loader_and_stops_on_a_broken_block() {
	p, ids, ts := three()
	img := build_unsorted_vlsd_dz_chain_file(p, ids, ts, 5)
	want := parse_log(img) or { panic(err) }
	assert want.len() == 3
	assert want.at(0).frame.data == p[0]
	log, s := drain(img)
	assert same_log(log, want)
	assert s.err == ''
	// the FIRST block broken: the frame whose payload it holds is never queued — a row this
	// path queued after recording the failure was round 2's P1
	mut bad := img.clone()
	dz := find_block(bad, '##DZ')
	bad[dz + 24 + 24 + 2] = 0xFF
	bad[dz + 24 + 24 + 3] = 0xFF
	if _ := parse_log(bad) {
		assert false, 'the loader accepted a broken signal-data block'
	}
	log2, s2 := drain(bad)
	assert log2.len() == 0
	assert s2.err.contains('signal data')
}

fn test_a_fixed_record_nobody_decodes_is_stepped_over_not_buffered() {
	p, ids, ts := three()
	junk := (1 << 20) + 17 // wider than a chunk, and than max_record_stride
	mut stream := []u8{}
	stream << vpay(p[0])
	stream << vframe(ts[0], ids[0], p[0].len, 0)
	stream << vjunk(junk)
	stream << vpay(p[1])
	stream << vframe(ts[1], ids[1], p[1].len, u32(4 + p[0].len))
	stream << vjunk(junk)
	stream << vpay(p[2])
	stream << vframe(ts[2], ids[2], p[2].len, u32(8 + p[0].len + p[1].len))
	img := build_unsorted_vlsd_raw_x(stream, 3, junk, false)
	want := parse_log(img) or { panic(err) }
	assert want.len() == 3
	log, s := drain(img)
	assert same_log(log, want)
	assert s.err == ''
}

fn test_a_frame_group_with_an_absurd_stride_is_dropped_by_both_readers() {
	p, ids, _ := three()
	mut img := build_mlsd_file(p, ids, [u32(1), 2, 3])
	// cg_data_bytes is the u32 at +24 of the CG data section
	cg := find_block(img, '##CG')
	for i, x in le_bytes(u64(max_record_stride) + 1, 4) {
		img[cg + 24 + 8 * 6 + 24 + i] = x
	}
	want := parse_log(img) or { panic(err) }
	assert want.len() == 0
	log, s := drain(img)
	assert log.len() == 0
	assert s.err == ''
}

fn test_skipping_an_oversized_record_still_validates_the_compressed_blocks_it_crosses() {
	p, ids, ts := three()
	big := int(max_vlsd_record)
	mut stream := []u8{}
	stream << vpay(p[0])
	stream << vframe(ts[0], ids[0], p[0].len, 0)
	off1 := u32(4 + p[0].len)
	stream << vpay([]u8{len: big}) // spans the midpoint, where the DZ chain is cut
	off2 := off1 + u32(4 + big)
	stream << vpay(p[2])
	stream << vframe(ts[2], ids[2], p[2].len, off2)
	img := build_unsorted_vlsd_raw_x(stream, 2, 0, true)
	want := parse_log(img) or { panic(err) }
	assert want.len() == 2
	log, s := drain(img)
	assert same_log(log, want)
	assert s.err == ''
	// the second DZ block broken: the loader fails; the stream, which steps over that block
	// inside the big record, must fail too rather than finish clean
	mut bad := img.clone()
	first := find_block(bad, '##DZ')
	mut second := first + 4
	for bad[second..second + 4].bytestr() != '##DZ' {
		second++
	}
	bad[second + 24 + 24 + 2] = 0xFF
	bad[second + 24 + 24 + 3] = 0xFF
	if _ := parse_log(bad) {
		assert false, 'the loader accepted a broken DZ block'
	}
	mut src := MemSource{
		buf: bad
	}
	if _ := stream_log(mut src) {
		assert false, 'the stream skipped past a broken DZ block'
	}
	_, s2 := drain(bad)
	assert s2.err != ''
}

fn test_a_block_length_that_wraps_the_address_space_is_clamped_like_any_over_long_one() {
	p, ids, _ := three()
	img := build_mlsd_file(p, ids, [u32(1), 2, 3])
	want := parse_log(img) or { panic(err) }
	mut bad := img.clone()
	dt := find_block(bad, '##DT')
	for i, x in le_bytes(~u64(0xF), 8) {
		bad[dt + 8 + i] = x // block length
	}
	got := parse_log(bad) or { panic(err) }
	assert same_log(got, want) // the block runs to the end of the file, as an over-long block does
	assert got.len() == 3
	log, s := drain(bad)
	assert same_log(log, want)
	assert s.err == ''
}
