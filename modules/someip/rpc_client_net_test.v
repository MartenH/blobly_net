module someip

import net
import testports
import time

// The RpcClient over REAL sockets on loopback — the exact shape the GUI
// shell worker drives (bind the peer port, write_to the service port, pump
// reads + the clock). Single process: UDP buffers the exchange, so the
// server side answers sequentially after the client sends.

// The two ports this test binds: a block of two, belonging to this process alone.
//
// Predicted, not verified, and that is forced rather than chosen — this V's net.listen_udp sets
// SO_REUSEADDR, so a second bind on a held UDP port SUCCEEDS and proves nothing. Walking
// candidates until one "works" would be a check that always passes on the first try, including
// the collision it exists to avoid. See the head of `testports`.
//
// So it has to be prediction that cannot overlap: the pid picks the BLOCK and the slot indexes
// inside it. `pid + slot` — what this was — makes process N's slot 1 into process N+1's slot 0,
// and a test runner spawns its files with pids a few apart, so that is the common case.
fn uniq_port(slot int) int {
	return testports.someip.slot(2, slot)
}

fn test_rpc_over_loopback_sockets() {
	// PER PROCESS, not constants. A fixed port collides two ways — with another test in the same
	// suite, and with another suite run (or anything else on this machine) holding it — and both
	// surface as one intermittent failure that passes on every re-run afterwards, which is what
	// #112 was filed for and could not identify.
	//
	// Not OS-assigned, unlike the TCP cases elsewhere: this V's net.UdpConn has no addr(), so a
	// socket bound to port 0 cannot report the number it got, and the client below has to be told
	// where to write before either socket exists.
	srv_port := uniq_port(0)
	mut srv := net.listen_udp('127.0.0.1:${srv_port}')!
	defer {
		srv.close() or {}
	}
	srv.set_read_timeout(500 * time.millisecond)
	mut cli_sock := net.listen_udp('127.0.0.1:${uniq_port(1)}')!
	defer {
		cli_sock.close() or {}
	}
	cli_sock.set_read_timeout(100 * time.millisecond)
	srv_addr := net.resolve_addrs('127.0.0.1:${srv_port}', .ip, .udp)![0]

	mut cli := RpcClient{
		service:    0x0100
		method:     0x0001
		iface:      1
		client_id:  0x0E01
		timeout_us: 2_000_000
	}
	sw := time.new_stopwatch()
	req := cli.send('uptime'.bytes(), 0) or {
		assert false, 'send refused'
		return
	}
	cli_sock.write_to(srv_addr, req)!

	// the "board": read the request, validate it as the target gate would,
	// answer with the correlated response
	mut sbuf := []u8{len: 2048}
	n, cli_addr := srv.read(mut sbuf)!
	m := parse(sbuf[..n])!
	validate(m.header, 0x0100, 1)!
	assert m.payload.bytestr() == 'uptime'
	srv.write_to(cli_addr, response_for(m.header, 'up 9m'.bytes()))!

	// the client pump (the worker's loop)
	mut rbuf := []u8{len: 2048}
	for cli.state == .waiting {
		rn, _ := cli_sock.read(mut rbuf) or {
			cli.poll(u64(sw.elapsed().microseconds()))
			continue
		}
		cli.on_datagram(rbuf[..rn])
		cli.poll(u64(sw.elapsed().microseconds()))
	}
	assert cli.state == .done
	assert cli.result.payload.bytestr() == 'up 9m'
}
