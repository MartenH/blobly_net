module someip

import net
import testports
import time

// The RpcClient over REAL sockets on loopback — the exact shape the GUI
// shell worker drives (bind the peer port, write_to the service port, pump
// reads + the clock). Single process: UDP buffers the exchange, so the
// server side answers sequentially after the client sends.

// A port derived from this process, with a slot to keep two sockets in one test apart. The
// arithmetic and this file's band live in `testports`, which states why they are what they are;
// see the note at the use below for why these are not OS-assigned instead.
fn uniq_port(slot int) int {
	return testports.someip.port(slot)
}

fn test_rpc_over_loopback_sockets() {
	// PER PROCESS, not constants. A fixed port collides two ways — with another test in the same
	// suite, and with another suite run (or anything else on this machine) holding it — and both
	// surface as one intermittent failure that passes on every re-run afterwards, which is what
	// #112 was filed for and could not identify.
	//
	// Derived from the pid rather than assigned by the OS, unlike the TCP cases elsewhere: this V's
	// net.UdpConn has no addr(), so a socket bound to port 0 cannot report the number it got, and
	// the client below has to be told where to write. A pid-derived pair is the next best thing —
	// two concurrent runs cannot meet, and the two sockets in this one test differ by their slot.
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
