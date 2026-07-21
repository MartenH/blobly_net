module someip

import net
import time

// The RpcClient over REAL sockets on loopback — the exact shape the vgui
// shell worker drives (bind the peer port, write_to the service port, pump
// reads + the clock). Single process: UDP buffers the exchange, so the
// server side answers sequentially after the client sends.

fn test_rpc_over_loopback_sockets() {
	mut srv := net.listen_udp('127.0.0.1:47654')!
	defer {
		srv.close() or {}
	}
	srv.set_read_timeout(500 * time.millisecond)
	mut cli_sock := net.listen_udp('127.0.0.1:47655')!
	defer {
		cli_sock.close() or {}
	}
	cli_sock.set_read_timeout(100 * time.millisecond)
	srv_addr := net.resolve_addrs('127.0.0.1:47654', .ip, .udp)![0]

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
