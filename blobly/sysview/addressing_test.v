module sysview

import toml

// Normal fixed addressing's ids, as golden vectors — blobly_emb's comm/isotp addressing_test.v pins
// the same ones, so the tester and the node derive one id from one pair of addresses — and how a
// table states its ids and their format (blobly_emb tools/ecumodel addressing.v).

fn test_normal_fixed_ids_match_blobly_emb() {
	assert fixed_id(false, 0x10, 0xF1) == u32(0x18DA10F1)
	assert fixed_id(false, 0xF1, 0x10) == u32(0x18DAF110)
	assert fixed_id(true, 0x33, 0xF1) == u32(0x18DB33F1)
	assert fixed_id(false, 0x00, 0xFF) == u32(0x18DA00FF)
	assert fixed_id(false, 0xFF, 0x00) == u32(0x18DAFF00)
	for f in [false, true] {
		for t in [u8(0), 0x10, 0xFF] {
			id := fixed_id(f, t, 0xF1)
			assert id >> 26 == 6 && id <= 0x1FFF_FFFF
		}
	}
}

fn table(src string) map[string]toml.Any {
	return (toml.parse_text(src) or { panic(err) }).to_any().as_map()
}

fn test_a_tables_ids_and_their_format() {
	// normal addressing, 11-bit and 29-bit
	a, b, ext := addressing_of(table('req = 0x7A0\nrsp = 0x7A8\n'), 'req', 'rsp')
	assert a == 0x7A0 && b == 0x7A8 && !ext
	c, d, ext2 := addressing_of(table('rx_id = 0x123\ntx_id = 0x124\next = true\n'), 'rx_id', 'tx_id')
	assert c == 0x123 && d == 0x124 && ext2
	// ext counts only as the boolean true
	_, _, ext3 := addressing_of(table('req = 0x7A0\nrsp = 0x7A8\next = "yes"\n'), 'req', 'rsp')
	assert !ext3
	// normal fixed addressing derives the ids, always 29-bit
	e, f, ext4 := addressing_of(table('addressing = "normal_fixed"\nsa = 0x10\nta = 0xF1\n'), 'req',
		'rsp')
	assert e == 0x18DA10F1 && f == 0x18DAF110 && ext4
	// ... and invents nothing from half an address pair, or an address that is not one
	for src in ['addressing = "normal_fixed"\nta = 0xF1\n', 'addressing = "normal_fixed"\nsa = 0x10\nta = "x"\n',
		'addressing = "normal_fixed"\nsa = 256\nta = 0xF1\n'] {
		g, h, ext5 := addressing_of(table(src), 'req', 'rsp')
		assert g == 0 && h == 0 && !ext5, src
	}
}
