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
	n11 := addressing_of(table('req = 0x7A0\nrsp = 0x7A8\n'), 'req', 'rsp')
	assert n11 == Addressing{
		req: 0x7A0
		rsp: 0x7A8
	}
	n29 := addressing_of(table('rx_id = 0x123\ntx_id = 0x124\next = true\n'), 'rx_id', 'tx_id')
	assert n29 == Addressing{
		req: 0x123
		rsp: 0x124
		ext: true
	}
	// "normal" is the default spelled out
	assert addressing_of(table('addressing = "normal"\nreq = 0x7A0\nrsp = 0x7A8\n'), 'req', 'rsp') == n11
	// normal fixed addressing derives the ids, always 29-bit
	nf := addressing_of(table('addressing = "normal_fixed"\nsa = 0x10\nta = 0xF1\n'), 'req', 'rsp')
	assert nf == Addressing{
		req: 0x18DA10F1
		rsp: 0x18DAF110
		ext: true
	}
}

// What blobly_emb refuses is said, never read as something else: an address pair that cannot be
// read addresses nothing (its ids 0, `unreadable`), an addressing it does not know addresses
// nothing, and a key of the other addressing is said and not read.
fn test_a_table_blobly_emb_refuses_is_said() {
	unreadable := {
		'addressing = "normal_fixed"\nta = 0xF1\n':          ['addressing = "normal_fixed" needs sa (the node\'s own address, 0..255); it addresses nothing']
		'addressing = "normal_fixed"\nsa = 0x10\nta = "x"\n': ['ta = "x" is not an address (0..255); it addresses nothing']
		'addressing = "normal_fixed"\nsa = 256\nta = 0xF1\n':  ['sa = 256 is not an address (0..255); it addresses nothing']
		'addressing = "normal_fixed"\n':                      ['addressing = "normal_fixed" needs sa (the node\'s own address, 0..255); it addresses nothing',
			'addressing = "normal_fixed" needs ta (the tester\'s address, 0..255); it addresses nothing']
		'addressing = "extended"\nreq = 0x7A0\nrsp = 0x7A8\n': ['addressing "extended" is not "normal" or "normal_fixed" (extended and mixed addressing are not supported); it addresses nothing']
		'addressing = "mixed"\nreq = 0x7A0\nrsp = 0x7A8\n':    ['addressing "mixed" is not "normal" or "normal_fixed" (extended and mixed addressing are not supported); it addresses nothing']
		'addressing = 3\nreq = 0x7A0\nrsp = 0x7A8\n':          ['addressing 3 is not "normal" or "normal_fixed" (extended and mixed addressing are not supported); it addresses nothing']
		'req = 0x7A0\nrsp = 0x7A8\next = "yes"\n':            ['ext = "yes" is not a boolean (true: the ids are 29-bit); it addresses nothing']
		'req = "0x7A0"\nrsp = "0x7A8"\n':                    ['req = "0x7A0" is not an integer CAN id; it addresses nothing',
			'rsp = "0x7A8" is not an integer CAN id; it addresses nothing']
		'rsp = 0x7A8\n':                                     ['gives rsp without req (normal addressing states both); it addresses nothing']
		'req = 0x7A0\next = true\n':                         ['gives req without rsp (normal addressing states both); it addresses nothing']
		'req = 0x7A0\nrsp = 0x800\n':                        ['rsp = 0x800 is above 0x7FF, an 11-bit id (ext = true makes the ids 29-bit); it addresses nothing']
		'req = -1\nrsp = 0x20000000\next = true\n':          ['req = -1 is out of range (0x0..0x1FFFFFFF); it addresses nothing',
			'rsp = 0x20000000 is out of range (0x0..0x1FFFFFFF); it addresses nothing']
	}
	for src, errs in unreadable {
		a := addressing_of(table(src), 'req', 'rsp')
		assert a.unreadable && a.req == 0 && a.rsp == 0, src
		assert a.errs == errs, src
	}
	// keys of the other addressing: said, the ids read by the addressing the table states
	f := addressing_of(table('addressing = "normal_fixed"\nsa = 0x10\nta = 0xF1\nrx_id = 0x7A0\nfunctional_id = 0x7DF\next = false\n'),
		'rx_id', 'tx_id')
	assert !f.unreadable && f.req == 0x18DA10F1 && f.rsp == 0x18DAF110 && f.ext
	assert f.errs == ['rx_id is given with addressing = "normal_fixed", whose ids derive from sa and ta; not read',
		'functional_id is given with addressing = "normal_fixed", whose ids derive from sa and ta; not read',
		'ext is given with addressing = "normal_fixed", whose ids derive from sa and ta; not read']
	// a table stating neither id states none (a diag that allocates nothing, a dissolved node's
	// [isotp]), and is not unreadable
	e := addressing_of(table('bus = "can0"\n'), 'rx_id', 'tx_id')
	assert !e.unreadable && e.req == 0 && e.rsp == 0 && e.errs.len == 0
		n := addressing_of(table('rx_id = 0x123\ntx_id = 0x124\nsa = 0x10\n'), 'rx_id', 'tx_id')
	assert !n.unreadable && n.req == 0x123 && n.rsp == 0x124 && !n.ext
	assert n.errs == ['sa is for addressing = "normal_fixed"; normal addressing states rx_id and tx_id; not read']
}

// A pair as a tester reads it: its width where it is 29-bit, so two targets of one number on two
// widths read apart, and an 11-bit pair as its numbers alone.
fn test_a_pair_reads_with_its_width() {
	assert pair_text(0x7E0, 0x7E8, false, '→') == '0x7E0→0x7E8'
	assert pair_text(0x123, 0x124, true, '/') == '0x123/0x124 (29-bit)'
	assert pair_text(0x18DA10F1, 0x18DAF110, false, ' / ') == '0x18DA10F1 / 0x18DAF110 (29-bit)'
}
