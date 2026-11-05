module lindb

import os
import math

fn fixture() Ldf {
	return load_ldf(os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'lin_demo.ldf')) or { panic(err) }
}

// ldfparser's answers (sut/ldf_oracle.py, ldfparser 0.26.0) to encode and decode requests on
// dbc/lin_demo.ldf: every encoding range at its ends and middle, every logical value, raw
// values at a scalar's limits and one past, byte arrays, and every signal of a frame at once.
// Each line is `<request> -> <answer>`; `query` must give the same line.
const oracle_answers = 'decode CEM_Frm1 FC -> InternalLightsRequest=raw:0 text:off NightMode=raw:1 text:night
encode|CEM_Frm1|InternalLightsRequest=raw:0 -> FC
decode CEM_Frm1 FC -> InternalLightsRequest=raw:0 text:off NightMode=raw:1 text:night
encode|CEM_Frm1|InternalLightsRequest=raw:1 -> FD
decode CEM_Frm1 FD -> InternalLightsRequest=raw:1 text:on NightMode=raw:1 text:night
encode|CEM_Frm1|InternalLightsRequest=raw:3 -> FF
decode CEM_Frm1 FF -> InternalLightsRequest=raw:3 text:void NightMode=raw:1 text:night
encode|CEM_Frm1|InternalLightsRequest=raw:4 -> error
encode|CEM_Frm1|InternalLightsRequest=text:off -> FC
decode CEM_Frm1 FC -> InternalLightsRequest=raw:0 text:off NightMode=raw:1 text:night
encode|CEM_Frm1|InternalLightsRequest=text:on -> FD
decode CEM_Frm1 FD -> InternalLightsRequest=raw:1 text:on NightMode=raw:1 text:night
encode|CEM_Frm1|InternalLightsRequest=text:error -> FE
decode CEM_Frm1 FE -> InternalLightsRequest=raw:2 text:error NightMode=raw:1 text:night
encode|CEM_Frm1|InternalLightsRequest=text:void -> FF
decode CEM_Frm1 FF -> InternalLightsRequest=raw:3 text:void NightMode=raw:1 text:night
encode|CEM_Frm1|InternalLightsRequest=text:no such value -> error
encode|CEM_Frm1|NightMode=raw:0 -> F8
decode CEM_Frm1 F8 -> InternalLightsRequest=raw:0 text:off NightMode=raw:0 text:day
encode|CEM_Frm1|NightMode=raw:1 -> FC
decode CEM_Frm1 FC -> InternalLightsRequest=raw:0 text:off NightMode=raw:1 text:night
encode|CEM_Frm1|NightMode=raw:2 -> error
encode|CEM_Frm1|NightMode=text:day -> F8
decode CEM_Frm1 F8 -> InternalLightsRequest=raw:0 text:off NightMode=raw:0 text:day
encode|CEM_Frm1|NightMode=text:night -> FC
decode CEM_Frm1 FC -> InternalLightsRequest=raw:0 text:off NightMode=raw:1 text:night
encode|CEM_Frm1|NightMode=text:no such value -> error
encode|CEM_Frm1|InternalLightsRequest=raw:1|NightMode=raw:1 -> FD
decode CEM_Frm1 FD -> InternalLightsRequest=raw:1 text:on NightMode=raw:1 text:night
decode CEM_Frm2 78EBC3 -> CabinTemp=raw:120 phys:20 unit:degC VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=raw:0 -> 00EBC3
decode CEM_Frm2 00EBC3 -> CabinTemp=raw:0 phys:-40 unit:degC VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=raw:127 -> 7FEBC3
decode CEM_Frm2 7FEBC3 -> CabinTemp=raw:127 phys:23.5 unit:degC VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=raw:255 -> FFEBC3
decode CEM_Frm2 FFEBC3 -> CabinTemp=raw:255 text:sensor fault VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=raw:256 -> error
encode|CEM_Frm2|CabinTemp=phys:-40 -> 00EBC3
decode CEM_Frm2 00EBC3 -> CabinTemp=raw:0 phys:-40 unit:degC VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=phys:9.5 -> 63EBC3
decode CEM_Frm2 63EBC3 -> CabinTemp=raw:99 phys:9.5 unit:degC VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=phys:59.5 -> C7EBC3
decode CEM_Frm2 C7EBC3 -> CabinTemp=raw:199 phys:59.5 unit:degC VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=phys:260 -> C8EBC3
decode CEM_Frm2 C8EBC3 -> CabinTemp=raw:200 phys:260 unit:degC VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=phys:285 -> E1EBC3
decode CEM_Frm2 E1EBC3 -> CabinTemp=raw:225 phys:285 unit:degC VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=phys:310 -> FAEBC3
decode CEM_Frm2 FAEBC3 -> CabinTemp=raw:250 phys:310 unit:degC VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=text:sensor fault -> FFEBC3
decode CEM_Frm2 FFEBC3 -> CabinTemp=raw:255 text:sensor fault VehicleSpeed=raw:250 phys:15.625 unit:km/h
encode|CEM_Frm2|CabinTemp=phys:1e9 -> error
encode|CEM_Frm2|CabinTemp=text:no such value -> error
encode|CEM_Frm2|VehicleSpeed=raw:0 -> 7803C0
decode CEM_Frm2 7803C0 -> CabinTemp=raw:120 phys:20 unit:degC VehicleSpeed=raw:0 phys:0 unit:km/h
encode|CEM_Frm2|VehicleSpeed=raw:2047 -> 78FFDF
decode CEM_Frm2 78FFDF -> CabinTemp=raw:120 phys:20 unit:degC VehicleSpeed=raw:2047 phys:127.9375 unit:km/h
encode|CEM_Frm2|VehicleSpeed=raw:4095 -> 78FFFF
decode CEM_Frm2 78FFFF -> CabinTemp=raw:120 phys:20 unit:degC VehicleSpeed=raw:4095 text:invalid
encode|CEM_Frm2|VehicleSpeed=raw:4096 -> error
encode|CEM_Frm2|VehicleSpeed=phys:0 -> 7803C0
decode CEM_Frm2 7803C0 -> CabinTemp=raw:120 phys:20 unit:degC VehicleSpeed=raw:0 phys:0 unit:km/h
encode|CEM_Frm2|VehicleSpeed=phys:125 -> 7843DF
decode CEM_Frm2 7843DF -> CabinTemp=raw:120 phys:20 unit:degC VehicleSpeed=raw:2000 phys:125 unit:km/h
encode|CEM_Frm2|VehicleSpeed=phys:250 -> 7883FE
decode CEM_Frm2 7883FE -> CabinTemp=raw:120 phys:20 unit:degC VehicleSpeed=raw:4000 phys:250 unit:km/h
encode|CEM_Frm2|VehicleSpeed=text:invalid -> 78FFFF
decode CEM_Frm2 78FFFF -> CabinTemp=raw:120 phys:20 unit:degC VehicleSpeed=raw:4095 text:invalid
encode|CEM_Frm2|VehicleSpeed=phys:1e9 -> error
encode|CEM_Frm2|VehicleSpeed=text:no such value -> error
encode|CEM_Frm2|CabinTemp=raw:127|VehicleSpeed=raw:2047 -> 7FFFDF
decode CEM_Frm2 7FFFDF -> CabinTemp=raw:127 phys:23.5 unit:degC VehicleSpeed=raw:2047 phys:127.9375 unit:km/h
decode LSM_Frm1 1100 -> LeftIntLightsSwitch=raw:0 text:Off
encode|LSM_Frm1|LeftIntLightsSwitch=raw:0 -> 1100
decode LSM_Frm1 1100 -> LeftIntLightsSwitch=raw:0 text:Off
encode|LSM_Frm1|LeftIntLightsSwitch=raw:127 -> 117F
decode LSM_Frm1 117F -> LeftIntLightsSwitch=raw:127 phys:227 unit:lux
encode|LSM_Frm1|LeftIntLightsSwitch=raw:255 -> 11FF
decode LSM_Frm1 11FF -> LeftIntLightsSwitch=raw:255 text:error
encode|LSM_Frm1|LeftIntLightsSwitch=raw:256 -> error
encode|LSM_Frm1|LeftIntLightsSwitch=text:Off -> 1100
decode LSM_Frm1 1100 -> LeftIntLightsSwitch=raw:0 text:Off
encode|LSM_Frm1|LeftIntLightsSwitch=phys:101 -> 1101
decode LSM_Frm1 1101 -> LeftIntLightsSwitch=raw:1 phys:101 unit:lux
encode|LSM_Frm1|LeftIntLightsSwitch=phys:227 -> 117F
decode LSM_Frm1 117F -> LeftIntLightsSwitch=raw:127 phys:227 unit:lux
encode|LSM_Frm1|LeftIntLightsSwitch=phys:354 -> 11FE
decode LSM_Frm1 11FE -> LeftIntLightsSwitch=raw:254 phys:354 unit:lux
encode|LSM_Frm1|LeftIntLightsSwitch=text:error -> 11FF
decode LSM_Frm1 11FF -> LeftIntLightsSwitch=raw:255 text:error
encode|LSM_Frm1|LeftIntLightsSwitch=phys:1e9 -> error
encode|LSM_Frm1|LeftIntLightsSwitch=text:no such value -> error
encode|LSM_Frm1|LeftIntLightsSwitch=raw:127 -> 117F
decode LSM_Frm1 117F -> LeftIntLightsSwitch=raw:127 phys:227 unit:lux
decode LSM_Frm2 F8 -> LSMerror=raw:0 text:OK IntTest=raw:0 text:No test result
encode|LSM_Frm2|LSMerror=raw:0 -> F8
decode LSM_Frm2 F8 -> LSMerror=raw:0 text:OK IntTest=raw:0 text:No test result
encode|LSM_Frm2|LSMerror=raw:1 -> F9
decode LSM_Frm2 F9 -> LSMerror=raw:1 text:error IntTest=raw:0 text:No test result
encode|LSM_Frm2|LSMerror=raw:2 -> error
encode|LSM_Frm2|LSMerror=text:OK -> F8
decode LSM_Frm2 F8 -> LSMerror=raw:0 text:OK IntTest=raw:0 text:No test result
encode|LSM_Frm2|LSMerror=text:error -> F9
decode LSM_Frm2 F9 -> LSMerror=raw:1 text:error IntTest=raw:0 text:No test result
encode|LSM_Frm2|LSMerror=text:no such value -> error
encode|LSM_Frm2|IntTest=raw:0 -> F8
decode LSM_Frm2 F8 -> LSMerror=raw:0 text:OK IntTest=raw:0 text:No test result
encode|LSM_Frm2|IntTest=raw:1 -> FA
decode LSM_Frm2 FA -> LSMerror=raw:0 text:OK IntTest=raw:1 text:failed
encode|LSM_Frm2|IntTest=raw:3 -> FE
decode LSM_Frm2 FE -> LSMerror=raw:0 text:OK IntTest=raw:3 text:not used
encode|LSM_Frm2|IntTest=raw:4 -> error
encode|LSM_Frm2|IntTest=text:No test result -> F8
decode LSM_Frm2 F8 -> LSMerror=raw:0 text:OK IntTest=raw:0 text:No test result
encode|LSM_Frm2|IntTest=text:failed -> FA
decode LSM_Frm2 FA -> LSMerror=raw:0 text:OK IntTest=raw:1 text:failed
encode|LSM_Frm2|IntTest=text:passed -> FC
decode LSM_Frm2 FC -> LSMerror=raw:0 text:OK IntTest=raw:2 text:passed
encode|LSM_Frm2|IntTest=text:not used -> FE
decode LSM_Frm2 FE -> LSMerror=raw:0 text:OK IntTest=raw:3 text:not used
encode|LSM_Frm2|IntTest=text:no such value -> error
encode|LSM_Frm2|LSMerror=raw:1|IntTest=raw:1 -> FB
decode LSM_Frm2 FB -> LSMerror=raw:1 text:error IntTest=raw:1 text:failed
decode LSM_Frm3 4C534D31 -> LSM_Ident=bytes:4C534D31 text:LSM1
encode|LSM_Frm3|LSM_Ident=bytes:01020304 -> 01020304
decode LSM_Frm3 01020304 -> LSM_Ident=bytes:01020304 text:
encode|LSM_Frm3|LSM_Ident=text:ABCD -> 41424344
decode LSM_Frm3 41424344 -> LSM_Ident=bytes:41424344 text:ABCD
encode|LSM_Frm3|LSM_Ident=text:ABC -> error
encode|LSM_Frm3|LSM_Ident=text:ABCD -> 41424344
decode LSM_Frm3 41424344 -> LSM_Ident=bytes:41424344 text:ABCD
decode RSM_Frm1 6100 -> RightIntLightsSwitch=raw:0 text:Off
encode|RSM_Frm1|RightIntLightsSwitch=raw:0 -> 6100
decode RSM_Frm1 6100 -> RightIntLightsSwitch=raw:0 text:Off
encode|RSM_Frm1|RightIntLightsSwitch=raw:127 -> 617F
decode RSM_Frm1 617F -> RightIntLightsSwitch=raw:127 phys:227 unit:lux
encode|RSM_Frm1|RightIntLightsSwitch=raw:255 -> 61FF
decode RSM_Frm1 61FF -> RightIntLightsSwitch=raw:255 text:error
encode|RSM_Frm1|RightIntLightsSwitch=raw:256 -> error
encode|RSM_Frm1|RightIntLightsSwitch=text:Off -> 6100
decode RSM_Frm1 6100 -> RightIntLightsSwitch=raw:0 text:Off
encode|RSM_Frm1|RightIntLightsSwitch=phys:101 -> 6101
decode RSM_Frm1 6101 -> RightIntLightsSwitch=raw:1 phys:101 unit:lux
encode|RSM_Frm1|RightIntLightsSwitch=phys:227 -> 617F
decode RSM_Frm1 617F -> RightIntLightsSwitch=raw:127 phys:227 unit:lux
encode|RSM_Frm1|RightIntLightsSwitch=phys:354 -> 61FE
decode RSM_Frm1 61FE -> RightIntLightsSwitch=raw:254 phys:354 unit:lux
encode|RSM_Frm1|RightIntLightsSwitch=text:error -> 61FF
decode RSM_Frm1 61FF -> RightIntLightsSwitch=raw:255 text:error
encode|RSM_Frm1|RightIntLightsSwitch=phys:1e9 -> error
encode|RSM_Frm1|RightIntLightsSwitch=text:no such value -> error
encode|RSM_Frm1|RightIntLightsSwitch=raw:127 -> 617F
decode RSM_Frm1 617F -> RightIntLightsSwitch=raw:127 phys:227 unit:lux
decode RSM_Frm2 FE010203 -> RSMerror=raw:0 text:OK RSM_PartNo=bytes:010203 text:123
encode|RSM_Frm2|RSMerror=raw:0 -> FE010203
decode RSM_Frm2 FE010203 -> RSMerror=raw:0 text:OK RSM_PartNo=bytes:010203 text:123
encode|RSM_Frm2|RSMerror=raw:1 -> FF010203
decode RSM_Frm2 FF010203 -> RSMerror=raw:1 text:error RSM_PartNo=bytes:010203 text:123
encode|RSM_Frm2|RSMerror=raw:2 -> error
encode|RSM_Frm2|RSMerror=text:OK -> FE010203
decode RSM_Frm2 FE010203 -> RSMerror=raw:0 text:OK RSM_PartNo=bytes:010203 text:123
encode|RSM_Frm2|RSMerror=text:error -> FF010203
decode RSM_Frm2 FF010203 -> RSMerror=raw:1 text:error RSM_PartNo=bytes:010203 text:123
encode|RSM_Frm2|RSMerror=text:no such value -> error
encode|RSM_Frm2|RSM_PartNo=bytes:010203 -> FE010203
decode RSM_Frm2 FE010203 -> RSMerror=raw:0 text:OK RSM_PartNo=bytes:010203 text:123
encode|RSM_Frm2|RSM_PartNo=text:987 -> FE090807
decode RSM_Frm2 FE090807 -> RSMerror=raw:0 text:OK RSM_PartNo=bytes:090807 text:987
encode|RSM_Frm2|RSM_PartNo=raw:87 -> FE000807
decode RSM_Frm2 FE000807 -> RSMerror=raw:0 text:OK RSM_PartNo=bytes:000807 text:087
encode|RSM_Frm2|RSMerror=raw:1|RSM_PartNo=text:987 -> FF090807
decode RSM_Frm2 FF090807 -> RSMerror=raw:1 text:error RSM_PartNo=bytes:090807 text:987
decode RSM_Frm3 1020304050607080 -> RSM_Serial=bytes:1020304050607080
encode|RSM_Frm3|RSM_Serial=bytes:0102030405060708 -> 0102030405060708
decode RSM_Frm3 0102030405060708 -> RSM_Serial=bytes:0102030405060708
encode|RSM_Frm3|RSM_Serial=bytes:0102030405060708 -> 0102030405060708
decode RSM_Frm3 0102030405060708 -> RSM_Serial=bytes:0102030405060708
'

fn test_encode_and_decode_answer_as_the_oracle_does() {
	l := fixture()
	mut n := 0
	for line in oracle_answers.split_into_lines() {
		mut req := line.all_before(' -> ')
		if req.starts_with('decode ') {
			f := req.split(' ')
			req = 'decode|${f[1]}|${f[2]}'
		}
		assert l.query(req) == line
		n++
	}
	assert n == 177
}

// A multi-byte scalar crossing a byte boundary at an unaligned offset, by raw and physical value.
fn test_a_signal_across_bytes_round_trips() {
	l := fixture()
	f := l.frame('CEM_Frm2') or { panic('no CEM_Frm2') }
	for raw in [u64(0), 1, 0x3F, 0x40, 0xABC, 0xFFF] {
		data := l.encode(f, {
			'VehicleSpeed': Value(raw)
		})!
		// VehicleSpeed is bits 10..21: byte 1 bits 2..7 and byte 2 bits 0..5, the rest recessive
		assert data[0] == 120 // CabinTemp keeps its init
		assert data[1] == u8(((raw & 0x3F) << 2) | 0x03)
		assert data[2] == u8((raw >> 6) | 0xC0)
		got := l.decode(f, data)
		assert got[1].name == 'VehicleSpeed' && got[1].raw == raw
	}
	data := l.encode(f, {
		'VehicleSpeed': Value(f64(125.5))
		'CabinTemp':    Value(f64(21.5))
	})!
	got := l.decode(f, data)
	assert got[0].raw == 123 && (got[0].physical or { 0 }) == 21.5 && got[0].unit == 'degC'
	assert got[1].raw == 2008 && (got[1].physical or { 0 }) == 125.5 && got[1].unit == 'km/h'
	// the second physical range of the same encoding
	hot := l.decode(f, l.encode(f, {
		'CabinTemp': Value(f64(270))
	})!)
	assert hot[0].raw == 210 && (hot[0].physical or { 0 }) == 270
	// a logical value inside an encoding with physical ranges
	inv := l.decode(f, l.encode(f, {
		'VehicleSpeed': Value('invalid')
	})!)
	assert inv[1].raw == 4095 && inv[1].text == 'invalid' && inv[1].physical == none
}

fn test_byte_arrays_round_trip() {
	l := fixture()
	serial := l.frame('RSM_Frm3') or { panic('no RSM_Frm3') }
	bytes := [u8(0xDE), 0xAD, 0xBE, 0xEF, 0x01, 0x23, 0x45, 0x67]
	data := l.encode(serial, {
		'RSM_Serial': Value(bytes)
	})!
	assert data == bytes
	got := l.decode(serial, data)
	assert got.len == 1 && got[0].is_array && got[0].bytes == bytes && got[0].text == ''

	ident := l.frame('LSM_Frm3') or { panic('no LSM_Frm3') }
	assert l.decode(ident, l.template(ident))[0].text == 'LSM1'
	assert l.encode(ident, {
		'LSM_Ident': Value('WXYZ')
	})! == 'WXYZ'.bytes()

	part := l.frame('RSM_Frm2') or { panic('no RSM_Frm2') }
	d := l.encode(part, {
		'RSM_PartNo': Value('45')
	})!
	assert d == [u8(0xFE), 0, 4, 5] // one digit per byte, most significant first, zero-padded
	v := l.decode(part, d)[1]
	assert v.text == '045' && v.raw == 45 && v.bytes == [u8(0), 4, 5]
	// a byte that is no decimal digit is not a bcd reading
	assert l.decode(part, [u8(0xFE), 1, 0x0A, 3])[1].text == ''
}

struct BadValue {
	frame  string
	signal string
	v      Value
}

fn test_a_value_its_signal_cannot_take_is_refused_by_name() {
	l := fixture()
	for c in [
		BadValue{'CEM_Frm2', 'VehicleSpeed', Value(u64(4096))},
		BadValue{'CEM_Frm2', 'CabinTemp', Value(f64(-41))},
		BadValue{'CEM_Frm2', 'CabinTemp', Value('freezing')},
		BadValue{'CEM_Frm2', 'CabinTemp', Value([u8(1)])},
		BadValue{'LSM_Frm3', 'LSM_Ident', Value('TOOLONG')},
		BadValue{'LSM_Frm3', 'LSM_Ident', Value([u8(1), 2])},
		BadValue{'LSM_Frm3', 'LSM_Ident', Value(u64(7))},
		BadValue{'RSM_Frm2', 'RSM_PartNo', Value('1234')},
		BadValue{'RSM_Frm2', 'RSM_PartNo', Value(u64(1000))},
		BadValue{'CEM_Frm1', 'CabinTemp', Value(u64(1))},
	] {
		f := l.frame(c.frame) or { panic(c.frame) }
		if _ := l.encode(f, {
			c.signal: c.v
		})
		{
			assert false, '${c.frame}.${c.signal} took a value it cannot hold'
		} else {
			assert err.msg().contains(c.signal), err.msg()
		}
	}
}

fn test_refusal_messages() {
	l := fixture()
	f2 := l.frame('CEM_Frm2') or { panic('no CEM_Frm2') }
	for values, want in {
		'VehicleSpeed=raw:4096': 'signal VehicleSpeed: raw 4096 does not fit 12 bits'
		'CabinTemp=phys:-41':    'signal CabinTemp: -41 is in no physical range of encoding TempEncoding'
		'CabinTemp=text:hot':    'signal CabinTemp: no logical value "hot" in encoding TempEncoding'
		'NightMode=raw:1':       'frame CEM_Frm2 carries no signal NightMode'
	} {
		mut m := map[string]Value{}
		name := values.all_before('=')
		v := values.all_after(':')
		m[name] = match values.all_after('=').all_before(':') {
			'raw' { Value(v.u64()) }
			'phys' { Value(v.f64()) }
			else { Value(v) }
		}
		if _ := l.encode(f2, m) {
			assert false, values
		} else {
			assert err.msg() == want
		}
	}
}

// decode reads only the signals the data holds whole; a short response is not padded.
fn test_decode_of_short_data_reads_what_is_there() {
	l := fixture()
	f := l.frame('CEM_Frm2') or { panic('no CEM_Frm2') }
	got := l.decode(f, [u8(0x7B), 0xFF])
	assert got.len == 1 && got[0].name == 'CabinTemp' && got[0].raw == 123
	assert l.decode(f, []).len == 0
}

// Unused bits are recessive, so a frame whose signals leave gaps has ones there.
fn test_template_fills_unused_bits_with_ones() {
	l := fixture()
	assert l.template(l.frame('CEM_Frm1') or { panic('') }) == [u8(0xFC)]
	// LSM_Frm1 is tied to Node_Status_Event: byte 0 is its own protected id, 0x11
	assert l.template(l.frame('LSM_Frm1') or { panic('') }) == [u8(0x11), 0x00]
	assert l.template(l.frame('LSM_Frm2') or { panic('') }) == [u8(0xF8)]
	assert l.template(l.frame('RSM_Frm2') or { panic('') }) == [u8(0xFE), 1, 2, 3]
}

fn test_query_refuses_a_malformed_request() {
	l := fixture()
	assert l.query('encode|CEM_Frm2|CabinTemp=raw:x') == 'encode|CEM_Frm2|CabinTemp=raw:x -> bad request'
	assert l.query('decode|CEM_Frm2|zz') == 'decode|CEM_Frm2|zz -> bad request'
	assert l.query('decode|Nope|00') == 'decode|Nope|00 -> no frame'
	assert l.query('frob|CEM_Frm2|00') == 'frob|CEM_Frm2|00 -> bad request'
}

fn test_a_physical_value_that_is_no_number_is_refused() {
	l := fixture()
	f := l.frame('CEM_Frm2') or { panic('no CEM_Frm2') }
	for v in [math.nan(), math.inf(1), math.inf(-1)] {
		if _ := l.encode(f, {
			'CabinTemp': Value(v)
		})
		{
			assert false, '${v} was encoded'
		} else {
			assert err.msg().starts_with('signal CabinTemp: ') && err.msg().ends_with(' is not a finite number')
		}
	}
}
