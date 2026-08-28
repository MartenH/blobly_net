module transport

import os
import time

// The response a CANsub.4 (firmware 02.04.00) gave to the PTR question, captured on
// 2026-08-28 with the device on a WSL bench's eth1 (#235). One packet carries PTR, TXT, SRV
// and A; the parser is pinned to these bytes so the browse cannot drift from the device.
const cansub_reply_vector = [
	u8(0x00),
	0x00,
	0x84,
	0x00,
	0x00,
	0x00,
	0x00,
	0x01,
	0x00,
	0x00,
	0x00,
	0x03,
	0x07,
	0x5f,
	0x63,
	0x61,
	0x6e,
	0x73,
	0x75,
	0x62,
	0x04,
	0x5f,
	0x74,
	0x63,
	0x70,
	0x05,
	0x6c,
	0x6f,
	0x63,
	0x61,
	0x6c,
	0x00,
	0x00,
	0x0c,
	0x00,
	0x01,
	0x00,
	0x00,
	0x11,
	0x94,
	0x00,
	0x0f,
	0x0c,
	0x65,
	0x35,
	0x61,
	0x31,
	0x36,
	0x61,
	0x64,
	0x66,
	0x2d,
	0x75,
	0x73,
	0x62,
	0xc0,
	0x0c,
	0xc0,
	0x2a,
	0x00,
	0x10,
	0x80,
	0x01,
	0x00,
	0x00,
	0x11,
	0x94,
	0x00,
	0x15,
	0x09,
	0x61,
	0x70,
	0x69,
	0x3d,
	0x30,
	0x34,
	0x2e,
	0x30,
	0x30,
	0x0a,
	0x63,
	0x68,
	0x61,
	0x6e,
	0x6e,
	0x65,
	0x6c,
	0x73,
	0x3d,
	0x34,
	0xc0,
	0x2a,
	0x00,
	0x21,
	0x80,
	0x01,
	0x00,
	0x00,
	0x00,
	0x78,
	0x00,
	0x15,
	0x00,
	0x00,
	0x00,
	0x00,
	0x01,
	0xbb,
	0x0c,
	0x65,
	0x35,
	0x61,
	0x31,
	0x36,
	0x61,
	0x64,
	0x66,
	0x2d,
	0x75,
	0x73,
	0x62,
	0xc0,
	0x19,
	0xc0,
	0x6c,
	0x00,
	0x01,
	0x80,
	0x01,
	0x00,
	0x00,
	0x00,
	0x78,
	0x00,
	0x04,
	0x0a,
	0xa5,
	0x7d,
	0x01,
]

fn test_the_query_is_one_ptr_question_for_the_service() {
	q := cansub_mdns_query()
	assert q[..12] == [u8(0), 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
	assert q[12..] == [u8(7), `_`, `c`, `a`, `n`, `s`, `u`, `b`, 4, `_`, `t`, `c`, `p`, 5, `l`,
		`o`, `c`, `a`, `l`, 0, 0, 12, 0, 1]
}

fn test_the_bench_reply_parses_to_one_device_with_four_channels() {
	devices := cansub_mdns_parse(cansub_reply_vector)!
	assert devices.len == 1
	d := devices[0]
	assert d.id == 'e5a16adf'
	assert d.host == 'e5a16adf-usb.local'
	assert d.addr == '10.165.125.1'
	assert d.port == 443
	assert d.api == '04.00'
	assert d.channels == 4
}

fn test_the_bench_reply_becomes_four_rows_the_address_parser_accepts() {
	rows := cansub_rows(cansub_mdns_parse(cansub_reply_vector)!)
	assert rows.map(it.iface) == ['cansub:e5a16adf/1', 'cansub:e5a16adf/2', 'cansub:e5a16adf/3',
		'cansub:e5a16adf/4']
	assert rows[0].name == 'CANsub e5a16adf channel 1 (api 04.00)'
	assert rows[0].kind == 'cansub'
	for r in rows {
		spec := parse_cansub_iface(r.iface)!
		assert spec.id == 'e5a16adf'
	}
}

fn test_a_query_or_a_truncated_packet_is_refused_not_misread() {
	if _ := cansub_mdns_parse(cansub_mdns_query()) {
		assert false, 'a question is not an answer'
	}
	if _ := cansub_mdns_parse(cansub_reply_vector[..40]) {
		assert false, 'a truncated response must not yield a device'
	}
	if _ := cansub_mdns_parse([]u8{}) {
		assert false, 'an empty packet must not yield a device'
	}
}

// A PTR-only answer: header + question + one PTR record whose target is written out in the
// given case, no SRV/TXT/A.
fn ptr_only_reply(instance string) []u8 {
	mut p := cansub_mdns_query()
	p[2] = 0x84
	p[7] = 1
	mut rdata := []u8{}
	rdata << u8(instance.len)
	rdata << instance.bytes()
	rdata << [u8(0xC0), 12]
	p << [u8(0xC0), 12, 0, 12, 0, 1, 0, 0, 0x11, 0x94, u8(rdata.len >> 8), u8(rdata.len & 0xFF)]
	p << rdata
	return p
}

fn test_a_reply_with_the_ptr_alone_yields_the_id_and_one_row() {
	devices := cansub_mdns_parse(ptr_only_reply('e5a16adf-usb'))!
	assert devices.len == 1
	assert devices[0].id == 'e5a16adf'
	assert devices[0].host == 'e5a16adf-usb.local'
	assert devices[0].channels == 0
	assert cansub_rows(devices).map(it.iface) == ['cansub:e5a16adf/1']
}

fn test_names_are_matched_without_case_and_ids_come_out_lower_cased() {
	devices := cansub_mdns_parse(ptr_only_reply('E5A16ADF-USB'))!
	assert devices.len == 1
	assert devices[0].id == 'e5a16adf'
}

fn test_an_instance_this_backend_could_not_open_is_not_offered() {
	assert cansub_instance_id('e5a16adf-usb') or { '' } == 'e5a16adf'
	assert cansub_instance_id('e5a16adf-usb._cansub._tcp.local') or { '' } == 'e5a16adf'
	assert cansub_instance_id('e5a16adf-eth') == none
	assert cansub_instance_id('e5a16adf-usb (2)') == none
	assert cansub_instance_id('-usb') == none
	assert cansub_mdns_parse(ptr_only_reply('e5a16adf-eth'))!.len == 0
}

fn test_a_later_packet_fills_what_an_earlier_one_lacked_and_replaces_nothing() {
	mut found := []CansubService{}
	cansub_merge(mut found, cansub_mdns_parse(ptr_only_reply('e5a16adf-usb'))![0])
	assert found[0].channels == 0
	cansub_merge(mut found, cansub_mdns_parse(cansub_reply_vector)![0])
	assert found.len == 1
	assert found[0].channels == 4
	assert found[0].port == 443
	cansub_merge(mut found, CansubService{ id: 'e5a16adf', channels: 2, api: '99' })
	assert found[0].channels == 4, 'a later, different answer does not overwrite one already had'
	assert found[0].api == '04.00'
}

fn test_the_label_prefilter_ignores_case_and_never_allocates_a_string() {
	assert has_label_ci('xx_CANSub._tcp'.bytes(), '_cansub')
	assert has_label_ci(cansub_reply_vector, '_cansub')
	assert !has_label_ci('_cansu'.bytes(), '_cansub')
	assert !has_label_ci('printer._ipp._tcp.local'.bytes(), '_cansub')
}

fn test_a_malformed_record_from_another_service_does_not_discard_the_cansub_answer() {
	// The bench reply plus one more answer: an SRV for some other name whose target is a
	// compression pointer past the packet end. Framing is intact, so the CANsub records beside
	// it must still be read.
	mut pkt := cansub_reply_vector.clone()
	pkt[7] += 1 // one more answer
	pkt << [u8(5), `o`, `t`, `h`, `e`, `r`, 5, `l`, `o`, `c`, `a`, `l`, 0] // name
	pkt << [u8(0), 33, 0x80, 0x01, 0, 0, 0, 120, 0, 8] // SRV, rdlen 8
	pkt << [u8(0), 0, 0, 0, 1, 0xbb, 0xc0, 0xff] // prio, weight, port, target -> pointer past end
	devices := cansub_mdns_parse(pkt)!
	assert devices.len == 1
	assert devices[0].id == 'e5a16adf'
	assert devices[0].addr == '10.165.125.1'
}

fn test_channel_counts_are_clamped_to_what_the_address_parser_accepts() {
	rows := cansub_rows([CansubService{ id: 'aa11', channels: 99 }])
	assert rows.len == cansub_channels
	for r in rows {
		_ := parse_cansub_iface(r.iface)!
	}
}

// Live, only where a device is attached: CANSUB_LIVE=<id> names what the bench expects to find.
// Says so when it did not run, so a green run is never mistaken for a browse that happened.
fn test_live_browse_finds_the_bench_device() {
	want := os.getenv('CANSUB_LIVE')
	if want == '' {
		eprintln('SKIPPED test_live_browse_finds_the_bench_device: set CANSUB_LIVE=<device id> on a bench with a CANsub attached')
		return
	}
	b := cansub_browse(1500 * time.millisecond)!
	assert b.devices.any(it.id == want), 'browse found ${b.devices.map(it.id)}, not ${want} (${b.note})'
	rows := cansub_rows(b.devices)
	assert rows.any(it.iface == 'cansub:${want}/1')
}
