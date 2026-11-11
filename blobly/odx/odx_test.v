module odx

import os
import compress.deflate
import encoding.binary
import hash.crc32

const fixture = os.join_path(@VMODROOT, 'dbc', 'odx_demo.odx-d')

fn did_of(v Variant, id u16) Did {
	for d in v.dids {
		if d.id == id {
			return d
		}
	}
	assert false, 'no DID 0x${id:04X}'
	return Did{}
}

fn test_base_variant_lays_out_each_did() {
	db := load(fixture)!
	assert db.variants() == ['BodyController_Base', 'BodyController_V2']
	v := db.variant('BodyController_Base')!
	assert v.layer == 'BASE-VARIANT'
	assert v.dids.map(it.id) == [u16(0x0110), 0x0120, 0x0130, 0xF18C, 0xF190]
	vin := did_of(v, 0xF190)
	assert vin.name == 'VIN' && vin.readable && vin.writable && vin.size == 17
	assert vin.parts == [Part{'VIN', .text, 0, 17}]
	lamp := did_of(v, 0x0110)
	assert lamp.name == 'LampConfig' && lamp.size == 3 && lamp.writable
	assert lamp.parts == [Part{'Brightness', .unsigned, 0, 1}, Part{'DelayMs', .unsigned, 1, 2}]
	trim := did_of(v, 0x0120)
	assert trim.parts == [Part{'TrimOffset', .signed, 0, 2}]
	serial := did_of(v, 0xF18C)
	assert serial.parts == [Part{'EcuSerial', .bytes, 0, 4}] && !serial.writable
}

fn test_a_scaling_not_read_is_bytes_and_said() {
	v := load(fixture)!.variant('BodyController_Base')!
	temp := did_of(v, 0x0130)
	// LINEAR is a later step: the value is its two bytes, never a number read as if identical
	assert temp.name == 'Temperature' && temp.size == 2 && temp.parts.len == 0
	assert v.notes.any(it.contains('0x0130') && it.contains('COMPU-METHOD LINEAR')
		&& it.contains('read as 2 bytes'))
	// the service of another kind and the state chart are counted, not dropped in silence
	assert v.notes.any(it.starts_with('not read:') && it.contains('1 x DIAG-SERVICE 0x11')
		&& it.contains('1 x STATE-CHARTS'))
}

fn test_ecu_variant_inherits_but_what_it_excludes() {
	v := load(fixture)!.variant('BodyController_V2')!
	assert v.layer == 'ECU-VARIANT'
	ids := v.dids.map(it.id)
	assert 0x0200 in ids && 0xF190 in ids && 0x0110 in ids
	assert u16(0xF18C) !in ids // NOT-INHERITED-DIAG-COMM Serial_Read
	assert did_of(v, 0x0200).parts == [Part{'Mileage', .unsigned, 0, 4}]
	assert v.dtcs.map(it.name) == ['CrashSensorFault', 'LampOpenCircuit', 'SupplyLow']
	assert v.dtcs[1] == Dtc{'LampOpenCircuit', 0x912301, 'B1123-01', 'Lamp open circuit'}
}

fn test_an_unknown_variant_names_those_there_are() {
	db := load(fixture)!
	db.variant('Nope') or {
		assert err.msg().contains('BodyController_Base, BodyController_V2')
		return
	}
	assert false
}

fn test_malformed_values_are_refused_never_zero() {
	src := os.read_file(fixture)!
	dir := os.join_path(os.temp_dir(), 'odx_test_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	// a DTC whose code is not a number, and a structure position that is not one
	bad := src.replace('<TROUBLE-CODE>13697046</TROUBLE-CODE>', '<TROUBLE-CODE>x12</TROUBLE-CODE>').replace('DelayMs</SHORT-NAME>
                  <BYTE-POSITION>1<', 'DelayMs</SHORT-NAME>
                  <BYTE-POSITION>one<')
	assert bad.contains('x12') && bad.contains('>one<')
	p := os.join_path(dir, 'bad.odx-d')
	os.write_file(p, bad)!
	v := load(p)!.variant('BodyController_Base')!
	assert v.dtcs.map(it.name) == ['LampOpenCircuit']
	assert v.notes.any(it.contains('SupplyLow') && it.contains('"x12"'))
	lamp := did_of(v, 0x0110)
	assert lamp.parts.len == 0 && lamp.size == -1
	assert v.notes.any(it.contains('0x0110') && it.contains('"one" is not an integer'))
}

// zip_of builds a ZIP archive of `files`, the first stored and the rest deflated.
fn zip_of(files map[string][]u8) []u8 {
	mut out := []u8{}
	mut central := []u8{}
	mut i := 0
	for name, data in files {
		method := if i == 0 { u16(0) } else { u16(8) }
		body := if method == 0 { data } else { deflate.compress_raw(data) or { panic(err) } }
		off := out.len
		mut h := []u8{len: 30}
		binary.little_endian_put_u32_at(mut h, zip_local_sig, 0)
		binary.little_endian_put_u16_at(mut h, method, 8)
		binary.little_endian_put_u32_at(mut h, crc32.sum(data), 14)
		binary.little_endian_put_u32_at(mut h, u32(body.len), 18)
		binary.little_endian_put_u32_at(mut h, u32(data.len), 22)
		binary.little_endian_put_u16_at(mut h, u16(name.len), 26)
		out << h
		out << name.bytes()
		out << body
		mut c := []u8{len: 46}
		binary.little_endian_put_u32_at(mut c, zip_central_sig, 0)
		binary.little_endian_put_u16_at(mut c, method, 10)
		binary.little_endian_put_u32_at(mut c, crc32.sum(data), 16)
		binary.little_endian_put_u32_at(mut c, u32(body.len), 20)
		binary.little_endian_put_u32_at(mut c, u32(data.len), 24)
		binary.little_endian_put_u16_at(mut c, u16(name.len), 28)
		binary.little_endian_put_u32_at(mut c, u32(off), 42)
		central << c
		central << name.bytes()
		i++
	}
	cd_off := out.len
	out << central
	mut e := []u8{len: 22}
	binary.little_endian_put_u32_at(mut e, zip_eocd_sig, 0)
	binary.little_endian_put_u16_at(mut e, u16(files.len), 8)
	binary.little_endian_put_u16_at(mut e, u16(files.len), 10)
	binary.little_endian_put_u32_at(mut e, u32(central.len), 12)
	binary.little_endian_put_u32_at(mut e, u32(cd_off), 16)
	out << e
	return out
}

fn test_a_pdx_is_read_from_its_zip() {
	dir := os.join_path(os.temp_dir(), 'odx_pdx_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	p := os.join_path(dir, 'body.pdx')
	os.write_file_array(p, zip_of({
		'index.xml':            '<CATALOG/>'.bytes()
		'BodyController.odx-d': os.read_bytes(fixture)!
	}))!
	db := load(p)!
	assert db.files == [p]
	assert db.notes.any(it.contains('1 file(s) of the PDX are not ODX'))
	v := db.variant('BodyController_V2')!
	assert did_of(v, 0xF190).parts == [Part{'VIN', .text, 0, 17}]
}

fn test_a_broken_zip_is_refused() {
	good := zip_of({
		'a.odx': '<ODX/>'.bytes()
		'b.odx': '<ODX/>'.bytes()
	})
	assert read_zip(good)!.len == 2
	mut bad := good.clone()
	bad[bad.len - 22 - 2 * (46 + 5) - 1] ^= 0xFF // the deflated entry's last byte
	read_zip(bad) or { return }
	assert false, 'a corrupted entry was read'
}
