module someip

import net
import time
import transport

// call runs ONE request through `cli` over UDP: the local `port` claimed and bound (a node with a
// static peer endpoint accepts requests only from that port and answers it), the request sent to
// `to` ("host:port", IPv4 like the bind), and only `to` heard — on a shared bench another node
// could otherwise forge matching correlation fields. Returns once `cli` is done or failed (its
// deadline); an error is only for what kept the request from going out. The GUI's eth shell and
// Lua's someip.call both go through here, so correlation, the drain, the version check and the
// sender filter have one home. The session `cli` used stays burned in `cli.session` either way.
pub fn call(port int, to string, mut cli RpcClient, payload []u8, owner string) ! {
	// claimed like every other listener in this process: two sockets on one UDP port split the
	// answers between them (transport/udpclaims.v)
	canon := transport.claim_endpoint('', port, owner, .tool, '')!
	defer {
		transport.release_endpoint(canon, port, owner)
	}
	// bound on what was claimed, the IPv4 wildcard — so the peer is resolved as IPv4 too
	mut sock := net.listen_udp(bind_addr(canon, port)) or {
		return error('bind :${port}: ${err} — the node answers only its configured peer endpoint')
	}
	defer {
		sock.close() or {}
	}
	addrs := net.resolve_addrs(to, .ip, .udp) or { return error('resolve ${to}: ${err}') }
	if addrs.len == 0 {
		return error('${to} has no IPv4 address')
	}
	sw := time.new_stopwatch()
	req := cli.send(payload, 0) or { return error('a request is already in flight') }
	sock.write_to(addrs[0], req) or { return error('send to ${to}: ${err}') }
	// one FULL UDP datagram: a truncated read would fail the header-length check and read as a
	// timeout, not as truncation
	mut buf := []u8{len: 65536}
	want := addrs[0].str()
	for cli.state == .waiting {
		// each read bounded by what is left of the deadline, so a short one is honoured
		left := i64(cli.timeout_us) - sw.elapsed().microseconds()
		sock.set_read_timeout(time.Duration(if left > 50_000 {
			50_000
		} else if left > 1000 {
			left
		} else {
			1000
		}) * time.microsecond)
		n, from := sock.read(mut buf) or {
			cli.poll(u64(sw.elapsed().microseconds()))
			continue
		}
		if from.str() == want {
			// a datagram may pack several messages (vsomeip does under load): any may be ours
			msgs, _ := split(buf[..n])
			for msg in msgs {
				if cli.on_message(msg) {
					break
				}
			}
		}
		cli.poll(u64(sw.elapsed().microseconds()))
	}
}
