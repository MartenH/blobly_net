module uds

import isotp
import transport

// A test ECU shaped like blobly_emb's comm/diag.Connection: it answers on its PHYSICAL channel,
// and a raw tap hands it the functional Single Frames. As ISO 14229-1 has a server do for a
// functional request, it keeps quiet rather than refuse with 0x11, 0x12, 0x31, 0x7E or 0x7F.
// `pend` answers 0x78 before the real answer. Its channels are opened before it is spawned, so a
// request sent before it reaches its loop is queued for it, not lost.
struct TestEcu {
mut:
	phys isotp.Channel
	tap  transport.Bus
	pend bool
}

fn functional_ecu(mut e TestEcu, stop chan bool) {
	mut phys := e.phys
	mut tap := e.tap
	pend := e.pend
	mut srv := default_server()
	for {
		select {
			_ := <-stop {
				phys.close()
				tap.close()
				return
			}
			else {}
		}
		f := tap.recv(20) or { continue }
		n := if f.data.len > 0 { int(f.data[0] & 0x0F) } else { 0 }
		if f.id != 0x7DF || f.data.len < 1 + n || f.data[0] >> 4 != 0 || n == 0 {
			continue
		}
		req := f.data[1..1 + n].clone()
		resp := srv.handle(req)
		if resp.len == 3 && resp[0] == 0x7F && resp[2] in [u8(0x11), 0x12, 0x31, 0x7E, 0x7F] {
			continue
		}
		if pend && resp.len > 0 {
			phys.send([u8(0x7F), req[0], 0x78]) or {}
		}
		if resp.len > 0 {
			phys.send(resp) or {}
		}
	}
}

fn ecu_on(bus string, req_id u32, rsp_id u32, pend bool, stop chan bool) thread {
	mut e := &TestEcu{
		phys: isotp.open_software(bus, rsp_id, req_id, false) or { panic(err) }
		tap:  transport.open(bus) or { panic(err) }
		pend: pend
	}
	return spawn functional_ecu(mut e, stop)
}

fn client_on(bus string, req_id u32, rsp_id u32) &Client {
	ch := isotp.open_software(bus, req_id, rsp_id, false) or { panic(err) }
	return &Client{
		ch: ch
	}
}

fn test_functional_collects_every_answer_on_its_physical_id() {
	bus := 'inproc:FUNC1'
	stop := chan bool{cap: 2}
	a := ecu_on(bus, 0x7E0, 0x7E8, false, stop)
	b := ecu_on(bus, 0x7E1, 0x7E9, true, stop)
	defer {
		stop <- true
		stop <- true
		a.wait()
		b.wait()
	}
	targets := [
		FunctionalTarget{
			client: client_on(bus, 0x7E0, 0x7E8)
			rsp_id: 0x7E8
		},
		FunctionalTarget{
			client: client_on(bus, 0x7E1, 0x7E9)
			rsp_id: 0x7E9
		},
		FunctionalTarget{ // nobody behind it
			client: client_on(bus, 0x7E2, 0x7EA)
			rsp_id: 0x7EA
		},
	]
	mut fch := isotp.Channel(isotp.open_software(bus, 0x7DF, 0x7DE, false) or { panic(err) })
	mut tap := transport.open(bus) or { panic(err) }

	// the VIN is multi-frame from BOTH: each answer's Flow Control goes to its own physical id
	vin := functional(mut fch, mut tap, targets, [u8(0x22), 0xF1, 0x90], 300) or { panic(err) }
	assert vin.len == 3
	assert vin[0].outcome == .positive && !vin[0].pended
	assert vin[0].resp[3..].bytestr() == 'BLOBLYNETV0SUT001'
	assert vin[1].outcome == .positive && vin[1].pended // 0x78, then its answer
	assert vin[1].resp == vin[0].resp
	assert vin[2].outcome == .silent

	// a refusal ISO suppresses to a functional request is silence; one it does not is reported
	nf := functional(mut fch, mut tap, targets, [u8(0x22), 0xAB, 0xCD], 300) or { panic(err) }
	assert nf.all(it.outcome == .silent)
	bad := functional(mut fch, mut tap, targets[..1], [u8(0x19), 0x01], 300) or { panic(err) }
	assert bad[0].outcome == .negative && bad[0].nrc == 0x13

	// a suppressed positive response: quiet all round is success
	tp := functional(mut fch, mut tap, targets[..2], [u8(0x3E), 0x80], 200) or { panic(err) }
	assert tp.all(it.outcome == .silent)
}

fn test_functional_refuses_what_it_cannot_send_or_tell_apart() {
	bus := 'inproc:FUNC2'
	t := FunctionalTarget{
		client: client_on(bus, 0x7E0, 0x7E8)
		rsp_id: 0x7E8
	}
	mut fch := isotp.Channel(isotp.open_software(bus, 0x7DF, 0x7DE, false) or { panic(err) })
	mut tap := transport.open(bus) or { panic(err) }
	functional(mut fch, mut tap, [t], [u8(0x2E), 0xF1, 0x90, 1, 2, 3, 4, 5], 100) or {
		assert err.msg().contains('one Single Frame')
		functional(mut fch, mut tap, [t, t], [u8(0x3E), 0x00], 100) or {
			assert err.msg().contains('two functional targets')
			return
		}
		assert false, 'two targets on one response id were accepted'
		return
	}
	assert false, 'an 8-byte functional request was accepted'
}

// A carrier for functional_addressed: what send_to was asked, and the answers recv hands back in
// order — an error string as `!` followed by the message, a timeout once they run out.
struct ScriptedCarrier {
	iface string = 'scripted'
	tx_id u32
	rx_id u32
mut:
	sent    []u32
	answers []string
	queued  int // answers already waiting before the request: what the drain must take
}

fn (mut s ScriptedCarrier) send(data []u8) ! {}

fn (mut s ScriptedCarrier) send_to(target u32, data []u8) ! {
	s.sent << target
}

fn (mut s ScriptedCarrier) recv(timeout_ms int) ![]u8 {
	if timeout_ms <= 0 && s.queued == 0 {
		return error('timeout')
	}
	if s.answers.len == 0 {
		return error('timeout')
	}
	if s.queued > 0 {
		s.queued--
	}
	a := s.answers[0]
	s.answers.delete(0)
	if a.starts_with('!') {
		return error(a[1..])
	}
	return a.bytes()
}

fn (mut s ScriptedCarrier) close() {}

fn (mut s ScriptedCarrier) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn addressed(answers []string, queued int, req []u8) (FunctionalReply, []u32) {
	mut sc := &ScriptedCarrier{
		answers: answers
		queued:  queued
	}
	mut cl := new_client(sc)
	cl.p2_star_ms = 50
	cl.margin_ms = 0
	mut via := AddressedSend(sc)
	r := functional_addressed(mut cl, mut via, 0xE400, req, 100) or { panic(err) }
	return r, sc.sent
}

fn test_functional_addressed_follows_the_shared_rules() {
	// sent once, to the functional address
	r, sent := addressed(['\x7E\x00'], 0, [u8(0x3E), 0x00])
	assert sent == [u32(0xE400)]
	assert r.outcome == .positive
	// an answer already queued is drained, not taken for this request's
	q, _ := addressed(['\x62\xF1\x90old', '\x62\xF1\x90new'], 1, [u8(0x22), 0xF1, 0x90])
	assert q.resp.bytestr() == '\x62\xF1\x90new'
	// an answer to another request is skipped; responsePending is waited for and remembered
	p, _ := addressed(['\x50\x01', '\x7F\x22\x78', '\x62\xF1\x90x'], 0, [u8(0x22), 0xF1, 0x90])
	assert p.outcome == .positive && p.pended
	// pending and then nothing within its P2*
	n, _ := addressed(['\x7F\x22\x78'], 0, [u8(0x22), 0xF1, 0x90])
	assert n.outcome == .pending
	// nothing at all is silence; a refusal is negative; a carrier failure is failed
	s, _ := addressed([], 0, [u8(0x3E), 0x80])
	assert s.outcome == .silent
	g, _ := addressed(['\x7F\x19\x13'], 0, [u8(0x19), 0x01])
	assert g.outcome == .negative && g.nrc == 0x13
	f, _ := addressed(['!DoIP: diagnostic message negative ack (0x03)'], 0, [u8(0x3E), 0x00])
	assert f.outcome == .failed && f.err.contains('negative ack')
}
