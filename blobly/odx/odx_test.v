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

// layer is a diagnostic layer `tag` with an 8-bit 0x22 DID per entry of `dids` (service Read_<n>),
// its DTC-DOP `dtcs` and its PARENT-REFS `parents`, every ID prefixed with `id`.
fn layer(tag string, id string, name string, dids []int, dtcs string, parents string) string {
	mut comms := ''
	mut reqs := ''
	mut resps := ''
	sid := '<PARAM xsi:type="CODED-CONST"><SHORT-NAME>SID</SHORT-NAME><BYTE-POSITION>0</BYTE-POSITION><CODED-VALUE>SIDV</CODED-VALUE><DIAG-CODED-TYPE xsi:type="STANDARD-LENGTH-TYPE" BASE-DATA-TYPE="A_UINT32"><BIT-LENGTH>8</BIT-LENGTH></DIAG-CODED-TYPE></PARAM>'
	for n in dids {
		comms += '<DIAG-SERVICE ID="${id}_s${n}"><SHORT-NAME>Read_${n}</SHORT-NAME><REQUEST-REF ID-REF="${id}_q${n}"/><POS-RESPONSE-REFS><POS-RESPONSE-REF ID-REF="${id}_r${n}"/></POS-RESPONSE-REFS></DIAG-SERVICE>'
		reqs += '<REQUEST ID="${id}_q${n}"><SHORT-NAME>Q${n}</SHORT-NAME><PARAMS>${sid.replace('SIDV',
			'34')}<PARAM xsi:type="CODED-CONST"><SHORT-NAME>DID</SHORT-NAME><BYTE-POSITION>1</BYTE-POSITION><CODED-VALUE>${n}</CODED-VALUE><DIAG-CODED-TYPE xsi:type="STANDARD-LENGTH-TYPE" BASE-DATA-TYPE="A_UINT32"><BIT-LENGTH>16</BIT-LENGTH></DIAG-CODED-TYPE></PARAM></PARAMS></REQUEST>'
		resps += '<POS-RESPONSE ID="${id}_r${n}"><SHORT-NAME>R${n}</SHORT-NAME><PARAMS>${sid.replace('SIDV',
			'98')}<PARAM xsi:type="VALUE"><SHORT-NAME>V${n}</SHORT-NAME><BYTE-POSITION>3</BYTE-POSITION><DOP-REF ID-REF="${id}_dop"/></PARAM></PARAMS></POS-RESPONSE>'
	}
	return '<${tag} ID="${id}"><SHORT-NAME>${name}</SHORT-NAME><DIAG-DATA-DICTIONARY-SPEC><DATA-OBJECT-PROPS><DATA-OBJECT-PROP ID="${id}_dop"><SHORT-NAME>U8</SHORT-NAME><COMPU-METHOD><CATEGORY>IDENTICAL</CATEGORY></COMPU-METHOD><DIAG-CODED-TYPE xsi:type="STANDARD-LENGTH-TYPE" BASE-DATA-TYPE="A_UINT32"><BIT-LENGTH>8</BIT-LENGTH></DIAG-CODED-TYPE></DATA-OBJECT-PROP></DATA-OBJECT-PROPS>${dtcs}</DIAG-DATA-DICTIONARY-SPEC><DIAG-COMMS>${comms}</DIAG-COMMS><REQUESTS>${reqs}</REQUESTS><POS-RESPONSES>${resps}</POS-RESPONSES><PARENT-REFS>${parents}</PARENT-REFS></${tag}>'
}

// parent is a PARENT-REF to `id`, leaving out the services and DOPs named, with `extra` inside it.
fn parent_ref(id string, docref string, comms []string, dops []string, extra string) string {
	dr := if docref == '' { '' } else { ' DOCREF="${docref}"' }
	nc := comms.map('<NOT-INHERITED-DIAG-COMM><DIAG-COMM-SNREF SHORT-NAME="${it}"/></NOT-INHERITED-DIAG-COMM>').join('')
	nd := dops.map('<NOT-INHERITED-DOP><DOP-BASE-SNREF SHORT-NAME="${it}"/></NOT-INHERITED-DOP>').join('')
	return '<PARENT-REF ID-REF="${id}"${dr}><NOT-INHERITED-DIAG-COMMS>${nc}</NOT-INHERITED-DIAG-COMMS><NOT-INHERITED-DOPS>${nd}</NOT-INHERITED-DOPS>${extra}</PARENT-REF>'
}

fn dtc_dop(name string, codes []int) string {
	ds := codes.map('<DTC ID="${name}_${it}"><SHORT-NAME>D${it}</SHORT-NAME><TROUBLE-CODE>${it}</TROUBLE-CODE></DTC>').join('')
	return '<DTC-DOPS><DTC-DOP ID="${name}"><SHORT-NAME>${name}</SHORT-NAME><DTCS>${ds}</DTCS></DTC-DOP></DTC-DOPS>'
}

fn odx_doc(container string, layers string) string {
	return '<ODX xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><DIAG-LAYER-CONTAINER ID="${container}"><SHORT-NAME>${container}</SHORT-NAME>${layers}</DIAG-LAYER-CONTAINER></ODX>'
}

// load_docs reads `docs` (file name -> text) as a folder of ODX files.
fn load_docs(tag string, docs map[string]string) !Db {
	dir := os.join_path(os.temp_dir(), 'odx_${tag}_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	for name, text in docs {
		os.write_file(os.join_path(dir, name), text)!
	}
	return load(dir)
}

fn test_a_service_left_out_is_left_out_of_what_its_parent_inherited() {
	p := layer('PROTOCOL', 'P', 'Proto', [1], '', '')
	bv := layer('BASE-VARIANT', 'BV', 'Base', [2], '', parent_ref('P', '', [], [], ''))
	bv2 := layer('BASE-VARIANT', 'BV2', 'Base2', [4], '', parent_ref('P', '', [], [], ''))
	ev := layer('ECU-VARIANT', 'EV', 'Ecu', [3], '', parent_ref('BV', '', ['Read_1'], [],
		'<NOT-INHERITED-VARIABLES/>'))
	// reached on a second way that does not leave it out, the service is inherited
	ev2 := layer('ECU-VARIANT', 'EV2', 'Ecu2', [], '', parent_ref('BV', '', ['Read_1'], [], '') +
		parent_ref('BV2', '', [], [], ''))
	db := load_docs('excl', {
		'a.odx-d': odx_doc('DLC', p + bv + bv2 + ev + ev2)
	})!
	v := db.variant('Ecu')!
	assert v.dids.map(it.id) == [u16(2), 3]
	assert v.notes.any(it.contains('1 x PARENT-REF/NOT-INHERITED-VARIABLES'))
	assert db.variant('Ecu2')!.dids.map(it.id) == [u16(1), 2, 4]
}

fn test_a_dtc_dop_is_overridden_and_left_out_by_name() {
	bv := layer('BASE-VARIANT', 'BV', 'Base', [], dtc_dop('Faults', [0x10101, 0x20202]), '')
	ev := layer('ECU-VARIANT', 'EV', 'Ecu', [], dtc_dop('Own', [0x30303]), parent_ref('BV',
		'', [], ['Faults'], ''))
	ev2 := layer('ECU-VARIANT', 'EV2', 'Ecu2', [], dtc_dop('Faults', [0x30303]), parent_ref('BV',
		'', [], [], ''))
	db := load_docs('dtc', {
		'a.odx-d': odx_doc('DLC', bv + ev + ev2)
	})!
	assert db.variant('Base')!.dtcs.map(it.code) == [u32(0x10101), 0x20202]
	assert db.variant('Ecu')!.dtcs.map(it.code) == [u32(0x30303)]
	assert db.variant('Ecu2')!.dtcs.map(it.code) == [u32(0x30303)]
}

fn test_an_id_is_its_documents_and_a_docref_names_another() {
	// both documents number their IDs alike; a reference stays in its own document unless DOCREF
	a := odx_doc('DLC_A', layer('BASE-VARIANT', 'BV', 'A_Base', [0x10], '', ''))
	b := odx_doc('DLC_B', layer('BASE-VARIANT', 'BV', 'B_Base', [0x20], '', '') +
		layer('ECU-VARIANT', 'EV', 'B_Ecu', [], '', parent_ref('BV', '', [], [], '')) +
		layer('ECU-VARIANT', 'EV2', 'B_Ecu2', [], '', parent_ref('BV', 'DLC_A', [], [], '')))
	db := load_docs('docref', {
		'a.odx-d': a
		'b.odx-d': b
	})!
	assert !db.notes.any(it.contains('given twice'))
	assert db.variant('B_Ecu')!.dids.map(it.id) == [u16(0x20)]
	assert db.variant('B_Ecu2')!.dids.map(it.id) == [u16(0x10)]
}

fn test_a_nearer_parent_overrides_an_ancestor_another_parent_shares() {
	// Ecu -> BaseA -> Proto and Ecu -> BaseB -> Proto: BaseB's Faults overrides Proto's, though
	// the walk reaches Proto through BaseA first
	p := layer('PROTOCOL', 'P', 'Proto', [], dtc_dop('Faults', [0x10101]), '')
	a := layer('BASE-VARIANT', 'BA', 'BaseA', [], '', parent_ref('P', '', [], [], ''))
	b := layer('BASE-VARIANT', 'BB', 'BaseB', [], dtc_dop('Faults', [0x20202]), parent_ref('P',
		'', [], [], ''))
	ev := layer('ECU-VARIANT', 'EV', 'Ecu', [], '', parent_ref('BA', '', [], [], '') +
		parent_ref('BB', '', [], [], ''))
	db := load_docs('prec', {
		'a.odx-d': odx_doc('DLC', p + a + b + ev)
	})!
	assert db.variant('Ecu')!.dtcs.map(it.code) == [u32(0x20202)]
}

// coded_param is a CODED-CONST parameter of `bits` at `pos` holding `value`.
fn coded_param(name string, pos int, value int, bits int) string {
	return '<PARAM xsi:type="CODED-CONST"><SHORT-NAME>${name}</SHORT-NAME><BYTE-POSITION>${pos}</BYTE-POSITION><CODED-VALUE>${value}</CODED-VALUE><DIAG-CODED-TYPE xsi:type="STANDARD-LENGTH-TYPE" BASE-DATA-TYPE="A_UINT32"><BIT-LENGTH>${bits}</BIT-LENGTH></DIAG-CODED-TYPE></PARAM>'
}

// raw_layer is a base variant `name` with U8 and U16 DOPs and the services, requests and
// responses given.
fn raw_layer(name string, comms string, reqs string, resps string) string {
	u := '<COMPU-METHOD><CATEGORY>IDENTICAL</CATEGORY></COMPU-METHOD>'
	return '<BASE-VARIANT ID="${name}"><SHORT-NAME>${name}</SHORT-NAME><DIAG-DATA-DICTIONARY-SPEC><DATA-OBJECT-PROPS><DATA-OBJECT-PROP ID="u8"><SHORT-NAME>U8</SHORT-NAME>${u}<DIAG-CODED-TYPE xsi:type="STANDARD-LENGTH-TYPE" BASE-DATA-TYPE="A_UINT32"><BIT-LENGTH>8</BIT-LENGTH></DIAG-CODED-TYPE></DATA-OBJECT-PROP><DATA-OBJECT-PROP ID="u16"><SHORT-NAME>U16</SHORT-NAME>${u}<DIAG-CODED-TYPE xsi:type="STANDARD-LENGTH-TYPE" BASE-DATA-TYPE="A_UINT32"><BIT-LENGTH>16</BIT-LENGTH></DIAG-CODED-TYPE></DATA-OBJECT-PROP></DATA-OBJECT-PROPS></DIAG-DATA-DICTIONARY-SPEC><DIAG-COMMS>${comms}</DIAG-COMMS><REQUESTS>${reqs}</REQUESTS><POS-RESPONSES>${resps}</POS-RESPONSES></BASE-VARIANT>'
}

fn service_xml(name string, req string, resp string) string {
	r := if resp == '' {
		''
	} else {
		'<POS-RESPONSE-REFS><POS-RESPONSE-REF ID-REF="${resp}"/></POS-RESPONSE-REFS>'
	}
	return '<DIAG-SERVICE ID="s_${name}"><SHORT-NAME>${name}</SHORT-NAME><REQUEST-REF ID-REF="${req}"/>${r}</DIAG-SERVICE>'
}

fn value_param(name string, dop string) string {
	return '<PARAM xsi:type="VALUE"><SHORT-NAME>${name}</SHORT-NAME><BYTE-POSITION>3</BYTE-POSITION><DOP-REF ID-REF="${dop}"/></PARAM>'
}

fn test_a_did_is_laid_out_as_read_whatever_the_service_order() {
	// the 0x2E service (two bytes) comes before the 0x22 service (one byte)
	comms := service_xml('Write_5', 'qw', '') + service_xml('Read_5', 'qr', 'rr')
	reqs := '<REQUEST ID="qw"><SHORT-NAME>QW</SHORT-NAME><PARAMS>' + coded_param('SID', 0,
		0x2E, 8) + coded_param('DID', 1, 5, 16) + value_param('Wide', 'u16') +
		'</PARAMS></REQUEST><REQUEST ID="qr"><SHORT-NAME>QR</SHORT-NAME><PARAMS>' +
		coded_param('SID', 0, 0x22, 8) + coded_param('DID', 1, 5, 16) + '</PARAMS></REQUEST>'
	resps := '<POS-RESPONSE ID="rr"><SHORT-NAME>RR</SHORT-NAME><PARAMS>' + coded_param('SID',
		0, 0x62, 8) + coded_param('DID', 1, 5, 16) + value_param('Narrow', 'u8') +
		'</PARAMS></POS-RESPONSE>'
	db := load_docs('order', {
		'a.odx-d': odx_doc('DLC', raw_layer('Base', comms, reqs, resps))
	})!
	d := did_of(db.variant('Base')!, 5)
	assert d.readable && !d.writable
	assert d.size == 1 && d.name == 'Narrow'
	assert d.parts.map(it.name) == ['Narrow']
}

fn test_a_read_of_several_dids_is_refused_not_read_as_the_first() {
	comms := service_xml('Read_Both', 'q', 'r')
	reqs := '<REQUEST ID="q"><SHORT-NAME>Q</SHORT-NAME><PARAMS>' + coded_param('SID', 0, 0x22,
		8) + coded_param('DID1', 1, 5, 16) + coded_param('DID2', 3, 6, 16) + '</PARAMS></REQUEST>'
	resps := '<POS-RESPONSE ID="r"><SHORT-NAME>R</SHORT-NAME><PARAMS>' + coded_param('SID',
		0, 0x62, 8) + coded_param('DID1', 1, 5, 16) + value_param('A', 'u8') +
		coded_param('DID2', 4, 6, 16) + '</PARAMS></POS-RESPONSE>'
	db := load_docs('multi', {
		'a.odx-d': odx_doc('DLC', raw_layer('Base', comms, reqs, resps))
	})!
	v := db.variant('Base')!
	assert v.dids.len == 0
	assert v.notes.any(it.contains('Read_Both') && it.contains('not read'))
}

fn test_a_did_two_services_lay_out_differently_is_never_written() {
	// a one-byte read, a two-byte write, then a one-byte write matching the read
	comms := service_xml('Read_5', 'qr', 'rr') + service_xml('Write_5', 'qw', '') +
		service_xml('Write_5b', 'qn', '')
	reqs := '<REQUEST ID="qr"><SHORT-NAME>QR</SHORT-NAME><PARAMS>' + coded_param('SID', 0, 0x22,
		8) + coded_param('DID', 1, 5, 16) + '</PARAMS></REQUEST><REQUEST ID="qw"><SHORT-NAME>QW</SHORT-NAME><PARAMS>' +
		coded_param('SID', 0, 0x2E, 8) + coded_param('DID', 1, 5, 16) + value_param('Wide', 'u16') +
		'</PARAMS></REQUEST><REQUEST ID="qn"><SHORT-NAME>QN</SHORT-NAME><PARAMS>' +
		coded_param('SID', 0, 0x2E, 8) + coded_param('DID', 1, 5, 16) + value_param('Narrow', 'u8') +
		'</PARAMS></REQUEST>'
	resps := '<POS-RESPONSE ID="rr"><SHORT-NAME>RR</SHORT-NAME><PARAMS>' + coded_param('SID',
		0, 0x62, 8) + coded_param('DID', 1, 5, 16) + value_param('Narrow', 'u8') +
		'</PARAMS></POS-RESPONSE>'
	db := load_docs('clash', {
		'a.odx-d': odx_doc('DLC', raw_layer('Base', comms, reqs, resps))
	})!
	d := did_of(db.variant('Base')!, 5)
	assert d.readable && !d.writable && d.size == 1
}

fn test_a_value_at_a_bit_position_spans_the_bytes_it_reaches() {
	// an 8-bit value starting 4 bits into byte 3 occupies two bytes
	comms := service_xml('Read_5', 'qr', 'rr')
	reqs := '<REQUEST ID="qr"><SHORT-NAME>QR</SHORT-NAME><PARAMS>' + coded_param('SID', 0, 0x22,
		8) + coded_param('DID', 1, 5, 16) + '</PARAMS></REQUEST>'
	resps := '<POS-RESPONSE ID="rr"><SHORT-NAME>RR</SHORT-NAME><PARAMS>' + coded_param('SID',
		0, 0x62, 8) + coded_param('DID', 1, 5, 16) +
		'<PARAM xsi:type="VALUE"><SHORT-NAME>Shifted</SHORT-NAME><BYTE-POSITION>3</BYTE-POSITION><BIT-POSITION>4</BIT-POSITION><DOP-REF ID-REF="u8"/></PARAM></PARAMS></POS-RESPONSE>'
	db := load_docs('bitpos', {
		'a.odx-d': odx_doc('DLC', raw_layer('Base', comms, reqs, resps))
	})!
	v := db.variant('Base')!
	d := did_of(v, 5)
	assert d.size == 2 && d.parts.len == 0
	assert v.notes.any(it.contains('BIT-POSITION') && it.contains('2 bytes'))
}
