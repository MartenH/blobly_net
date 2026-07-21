module someip

import net
import telem
import time

// BoardLink on loopback against a fake board — the whole someip-channel rx
// path without hardware: events decode per the manifest ethlayout, a shell
// request through the SHARED socket correlates while events interleave, and
// foreign/malformed datagrams are counted and dropped. Ephemeral ports (:0)
// so nothing collides with a live bench (which owns 30491).

const test_manifest = '# someip: service,version,port,peer
someip,0x100,1,30490,192.168.0.190:45999
# eth modules: module,endpoint,id
ethmod,shell,method,0x1
# eth frames: frame,id,len,dir,mode,cycle_us,e2e_id
ethframe,BenchTelem,0x8001,9,tx,cyclic,300000,0x21
ethframe,BenchCmd,0x8010,1,rx,cyclic,100000,-
# eth layout: frame,signal,field,offset,width,type
ethlayout,BenchTelem,BenchLoad,load,0,1,u8
ethlayout,BenchTelem,BenchTicks,ticks,1,4,u32
ethlayout,BenchTelem,BenchTicks,wraps,5,2,u16
# fb.handlers
0,app,0,Bench,on_100ms,100000
'

// event_defs mirrors the GUI's manifest -> link conversion: only tx (board ->
// host) frames are expected events.
fn event_defs(m telem.Manifest) []EventDef {
	mut defs := []EventDef{}
	for f in m.eth_frames {
		if f.dir == 'tx' {
			defs << EventDef{f.id, f.name, f.length}
		}
	}
	return defs
}

fn test_board_link_loopback() {
	m := telem.parse_manifest(test_manifest)!
	// the fake board
	mut srv := net.listen_udp('127.0.0.1:0')!
	defer {
		srv.close() or {}
	}
	srv.set_read_timeout(500 * time.millisecond)
	board := srv.sock.address()!.str()

	mut link := open_board_link('127.0.0.1:0', board, m.someip.service, m.someip.version,
		event_defs(m))!
	defer {
		link.close()
	}
	peer := link.local_addr()!

	// (a) an event arrives and decodes per ethlayout (LE payload fields)
	payload := [u8(7), 0x44, 0x33, 0x22, 0x11, 0x02, 0x01, 0xAA, 0xBB]
	srv.write_to(peer, notification(0x100, 0x8001, 1, payload))!
	ev := link.poll() or {
		assert false, 'event not accepted'
		return
	}
	assert ev.def.name == 'BenchTelem'
	fields := m.eth_fields(ev.def.name)
	assert fields[0].decode(ev.payload)? == 7
	assert fields[1].decode(ev.payload)? == 0x11223344
	assert fields[2].decode(ev.payload)? == 0x0102
	assert link.rx_events == 1
	assert link.drops == 0

	// (b) a shell request through the SHARED socket gets its correlated
	// response while events interleave around it
	mut cli := RpcClient{
		service:    m.someip.service
		method:     m.shell_method
		iface:      m.someip.version
		client_id:  0x0E01
		timeout_us: 2_000_000
	}
	req := cli.send('uptime'.bytes(), 0) or {
		assert false, 'send refused'
		return
	}
	link.send(req)!
	mut sbuf := []u8{len: 2048}
	n, _ := srv.read(mut sbuf)!
	rm := parse(sbuf[..n])!
	validate(rm.header, 0x100, 1)! // the board's gate would accept it
	assert rm.payload.bytestr() == 'uptime'
	// board answers: event, response, event — from ITS endpoint (peer known)
	srv.write_to(peer, notification(0x100, 0x8001, 1, payload))!
	srv.write_to(peer, response_for(rm.header, 'up 9m'.bytes()))!
	srv.write_to(peer, notification(0x100, 0x8001, 1, payload))!
	ev1 := link.poll() or {
		assert false, 'interleaved event 1 lost'
		return
	}
	assert ev1.def.id == 0x8001
	assert link.poll() == none // the response routes to the slot, not the trace
	ev2 := link.poll() or {
		assert false, 'interleaved event 2 lost'
		return
	}
	assert ev2.def.id == 0x8001
	rsp := link.take_response() or {
		assert false, 'response not parked'
		return
	}
	assert cli.on_datagram(rsp)
	assert cli.state == .done
	assert cli.result.payload.bytestr() == 'up 9m'
	assert link.take_response() == none // slot is consumed
	assert link.drops == 0

	// (c) foreign/malformed datagrams: counted + dropped, never surfaced
	mut stranger := net.listen_udp('127.0.0.1:0')!
	defer {
		stranger.close() or {}
	}
	stranger.write_to(peer, notification(0x100, 0x8001, 1, payload))! // wrong source
	srv.write_to(peer, [u8(0xDE), 0xAD])! // not even a header
	srv.write_to(peer, notification(0x999, 0x8001, 1, payload))! // foreign service
	srv.write_to(peer, notification(0x100, 0x8004, 1, [u8(1)]))! // id not in the manifest
	srv.write_to(peer, notification(0x100, 0x8001, 1, [u8(1), 2]))! // wrong length
	for _ in 0 .. 5 {
		assert link.poll() == none
	}
	assert link.drops == 5
	assert link.rx_events == 3 // the accepted events above, unchanged
}

fn test_board_link_response_fifo() {
	mut srv := net.listen_udp('127.0.0.1:0')!
	defer {
		srv.close() or {}
	}
	srv.set_read_timeout(500 * time.millisecond)
	board := srv.sock.address()!.str()
	mut link := open_board_link('127.0.0.1:0', board, 0x100, 1, [
		EventDef{0x8001, 'BenchTelem', 9},
	])!
	defer {
		link.close()
	}
	peer := link.local_addr()!

	// the real response immediately followed by a stale-session one: both
	// must reach the taker IN ORDER (a single slot would let the stale
	// overwrite the real one between shell polls -> timeout)
	mut cli := RpcClient{
		service:    0x100
		method:     0x0001
		iface:      1
		client_id:  0x0E01
		timeout_us: 2_000_000
	}
	req := cli.send('uptime'.bytes(), 0) or {
		assert false, 'send refused'
		return
	}
	link.send(req)!
	mut sbuf := []u8{len: 2048}
	n, _ := srv.read(mut sbuf)!
	rm := parse(sbuf[..n])!
	srv.write_to(peer, response_for(rm.header, 'up 9m'.bytes()))!
	stale := Header{
		service:           rm.header.service
		method:            rm.header.method
		client:            rm.header.client
		session:           0x7777 // an abandoned session's late answer
		protocol_version:  protocol_version
		interface_version: rm.header.interface_version
		msg_type:          mt_response
	}
	srv.write_to(peer, encode(stale, 'old'.bytes()))!
	assert link.poll() == none // both routed to the FIFO
	assert link.poll() == none
	first := link.take_response() or {
		assert false, 'real response lost'
		return
	}
	assert parse(first)!.header.session == rm.header.session // arrival order kept
	assert cli.on_datagram(first)
	assert cli.result.payload.bytestr() == 'up 9m'
	second := link.take_response() or {
		assert false, 'stale response lost'
		return
	}
	assert parse(second)!.header.session == 0x7777
	assert !cli.on_datagram(second) // the client drains it
	assert link.take_response() == none
	assert link.drops == 0

	// overflow: beyond the cap the OLDEST is dropped and counted
	for i in 0 .. 10 {
		mut h := stale
		srv.write_to(peer, encode(Header{
			...h
			session: u16(0x100 + i)
		}, []u8{}))!
		assert link.poll() == none
	}
	assert link.drops == 2 // 10 parked into a cap of 8
	mut got := []u16{}
	for {
		r := link.take_response() or { break }
		got << parse(r)!.header.session
	}
	assert got.len == 8
	assert got[0] == 0x102 // the two oldest were dropped
	assert got[7] == 0x109
}
