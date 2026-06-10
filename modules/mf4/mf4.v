// Native-V reader for ASAM MDF4 (.mf4) CAN bus-logging files — no Python/asammdf.
//
// Targets the common automotive case: ASAM MDF exports (MDF 4.x),
// where each bus is a "CAN_DataFrame" channel group. Handles DZ-compressed data
// blocks (zlib deflate, incl. zip_type 1 byte-transposition), DL/HL data lists,
// and the MLSD (Maximum Length Signal Data) payload layout where DataBytes live
// inline in each record (length given by DataLength) — so there is no separate
// VLSD signal-data block to chase.
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

// load_file parses an .mf4 file and returns its CAN frames as canlog entries,
// sorted by timestamp (each bus group is internally time-sorted; merging many
// groups needs the final sort). Errors on I/O or a non-MDF file.
pub fn load_file(path string) ![]canlog.LogEntry {
	buf := os.read_bytes(path)!
	return parse(buf)!
}

// parse reads an in-memory MDF4 image. Split out from load_file so callers/tests
// can feed bytes directly.
pub fn parse(buf []u8) ![]canlog.LogEntry {
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
	for dg != 0 {
		dgl := block_links(buf, dg)
		dg_data_off := data_off(buf, dg)
		rec_id_size := buf[dg_data_off]
		cg_first := if dgl.len > 1 { dgl[1] } else { u64(0) }
		data_link := if dgl.len > 2 { dgl[2] } else { u64(0) }
		if cg_first != 0 {
			raw := read_data_block(buf, data_link, unfin)!
			if rec_id_size == 0 {
				// Sorted: one CG per DG, the data block is its record stream.
				parse_cg(buf, cg_first, raw, unfin, map[u64][]u8{}, mut out)!
			} else {
				demux_unsorted(buf, cg_first, raw, int(rec_id_size), unfin, mut out)!
			}
		}
		dg = if dgl.len > 0 { dgl[0] } else { u64(0) }
	}
	out.sort(a.t_s < b.t_s)
	return out
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
fn demux_unsorted(buf []u8, cg_first u64, raw []u8, rec_id_size int, unfin bool,
	mut out []canlog.LogEntry) ! {
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
	for c in cgs {
		if !c.vlsd {
			parse_cg(buf, c.link, streams[c.rec_id] or { []u8{} }, unfin, vlsd_streams, mut
				out)!
		}
	}
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
}

fn parse_cg(buf []u8, cg u64, recs []u8, unfin bool, vlsd_streams map[u64][]u8,
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
	// The time master is identified by cn_type==2, not its name (Vector calls it
	// 't', python-can 'time'); fall back to a 't' lookup just in case.
	c_t := find_master(chans) or { find_chan(chans, 't') or { Chan{} } }
	// Vector packs the IDE flag into ID bit 31; CANedge gives it its own 1-bit
	// channel (the 29-bit ID is masked to its declared bit count, so bit 31 is 0).
	c_ide := find_chan(chans, 'CAN_DataFrame.IDE') or { Chan{} }

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
		if is_vlsd {
			off := int(read_uint(raw, base + c_db.byte_off, int(c_db.bit_off), int(c_db.bit_count)))
			if off + 4 <= vlsd.len {
				n := int(binary.little_endian_u32_at(vlsd, off))
				end := off + 4 + n
				if end <= vlsd.len {
					data = vlsd[off + 4..end].clone()
				}
			}
		} else {
			n := int(read_uint(raw, base + c_len.byte_off, int(c_len.bit_off), int(c_len.bit_count)))
			dstart := base + c_db.byte_off
			mut dend := dstart + n
			if dend > base + data_bytes {
				dend = base + data_bytes
			}
			data = raw[dstart..dend].clone()
		}
		out << canlog.LogEntry{
			t_s:   ts
			iface: 'can'
			frame: transport.CanFrame{
				id:       u32(rid) & 0x1FFFFFFF
				extended: ide
				data:     data
			}
		}
	}
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
		}
		comp := if cnl.len > 1 { cnl[1] } else { u64(0) }
		if comp != 0 && block_id(buf, comp) == '##CN' {
			collect_channels(buf, comp, mut chans)
		}
		cn = if cnl.len > 0 { cnl[0] } else { u64(0) }
	}
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
		'##DT', '##DV', '##DI', '##RD' {
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
