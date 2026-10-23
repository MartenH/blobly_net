"""SOME/IP from Python: someip.send, someip.call and someip.listen against a static peer on
loopback (a plain UDP socket answering from its own port, as a blobly_emb node does) — the coverage
of blobly/script's someip tests and blobly/someip's tester_test.v, through the C ABI."""
import socket
import struct
import threading
import time

import pytest

import blobly
from blobly import SomeipMessage, someip

pytestmark = pytest.mark.usefixtures("engine")


def free_port():
    """A UDP port nothing holds now."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def header(service, method, client, session, mtype, rc=0, iface=1, payload=b""):
    return struct.pack(">HHIHHBBBB", service, method, 8 + len(payload), client, session, 1, iface, mtype,
                       rc) + payload


class Peer:
    """A static peer on loopback: each request heard is answered from its own socket — method
    0x0099 with an ERROR (unknown method), any other with an event first and then the RESPONSE,
    its payload reversed."""

    def __init__(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.settimeout(0.05)
        self.to = f"127.0.0.1:{self.sock.getsockname()[1]}"
        self.heard = []
        self.done = threading.Event()
        self.t = threading.Thread(target=self.serve, daemon=True)
        self.t.start()

    def serve(self):
        while not self.done.is_set():
            try:
                data, src = self.sock.recvfrom(2048)
            except socket.timeout:
                continue
            svc, mth, _, client, session, _, iface, mtype, _ = struct.unpack(">HHIHHBBBB", data[:16])
            self.heard.append((svc, mth, client, session, iface, mtype, data[16:]))
            if mtype != 0x00:
                continue
            if mth == 0x0099:
                self.sock.sendto(header(svc, mth, client, session, 0x81, rc=0x03, iface=iface), src)
            else:
                self.sock.sendto(header(svc, 0x8001, 0, 0, 0x02, payload=b"\x01"), src)
                self.sock.sendto(header(svc, mth, client, session, 0x80, iface=iface, payload=data[16:][::-1]), src)

    def close(self):
        self.done.set()
        self.t.join()
        self.sock.close()


@pytest.fixture
def peer():
    p = Peer()
    yield p
    p.close()


@pytest.fixture
def port():
    """The local port a test sends from."""
    return free_port()


def test_a_call_returns_the_mirrored_response(peer, port):
    r = someip.call(peer.to, SomeipMessage(0x0100, 0x0001, b"abc", client=0x42, session=7), port=port)
    assert (r.type, r.return_code, r.client, r.session, r.payload) == ("response", 0, 0x42, 7, b"cba")
    assert (r.service, r.method, r.iface, r.source, r.protocol) == (0x0100, 0x0001, 1, peer.to, 1)
    assert not r.event
    assert r.at_ms >= 0


def test_the_answer_names_who_sent_it(peer, port):
    p = peer.to.split(":")[1]
    assert someip.call(f"localhost:{p}", SomeipMessage(0x0100, 0x0001), port=port).source == f"127.0.0.1:{p}"


def test_an_error_is_an_answer(peer, port):
    r = someip.call(peer.to, SomeipMessage(0x0100, 0x0099), port=port)
    assert (r.type, r.return_code, r.client) == ("error", 3, 0x1234)


def test_send_returns_everything_heard(peer, port):
    heard, malformed = someip.send(peer.to, SomeipMessage(0x0100, 0x0001, b"\x05"), port=port, window_ms=300)
    assert malformed == 0
    assert [(m.method, m.type) for m in heard] == [(0x8001, "notification"), (0x0001, "response")]
    assert heard[0].event
    assert (peer.heard[-1][2], peer.heard[-1][5]) == (0x1234, 0x00), "a request goes out with a live client"


def test_a_notification_goes_out_with_no_request_id(peer, port):
    heard = someip.send(peer.to, [SomeipMessage(0x0100, 0x8002, b"\x09")], port=port, window_ms=100)
    assert heard.messages == []
    assert peer.heard[-1][1:6] == (0x8002, 0, 0, 1, 0x02)


def test_a_session_goes_out_once_per_run(peer, port):
    someip.call(peer.to, SomeipMessage(0x0100, 0x0001, session=0x4321), port=port)
    with pytest.raises(blobly.Refused, match="already used"):
        someip.call(peer.to, SomeipMessage(0x0100, 0x0001, session=0x4321), port=port)
    with pytest.raises(blobly.Refused, match="already used"):
        someip.send(peer.to, SomeipMessage(0x0100, 0x0001, session=0x4321), port=port, window_ms=0)


@pytest.mark.parametrize("req, why", [
    (SomeipMessage(0x0100, 0x8001), "event id"),
    (SomeipMessage(0x0100, 1, client=0), "client 0"),
    (SomeipMessage(0x0100, 1, type="notification"), "a call sends a request"),
])
def test_what_is_no_request_is_refused(peer, port, req, why):
    with pytest.raises(blobly.Refused, match=why):
        someip.call(peer.to, req, port=port)


def test_only_requests_and_notifications_are_sent(peer, port):
    with pytest.raises(blobly.Refused):
        someip.send(peer.to, SomeipMessage(1, 1, type="response"), port=port)


@pytest.mark.parametrize("to", ["127.0.0.1", "[::1]:30490"])
def test_a_destination_is_an_ipv4_host_and_port(port, to):
    with pytest.raises(blobly.Refused, match='IPv4 "host:port"'):
        someip.send(to, SomeipMessage(1, 1), port=port)


@pytest.mark.parametrize("m, err", [
    (SomeipMessage(0x10000, 1), ValueError), (SomeipMessage(1.5, 1), TypeError),
    (SomeipMessage(None, 1), TypeError), (SomeipMessage(1, 1, type="answer"), ValueError),
    (SomeipMessage(1, 1, payload="x"), TypeError), (SomeipMessage(0x0100, 0x8001, return_code=3), ValueError),
])
def test_bad_fields_are_refused_before_anything_goes_out(peer, port, m, err):
    with pytest.raises(err):
        someip.send(peer.to, m, port=port)


@pytest.mark.parametrize("kw", [{"port": 0}, {"timeout_ms": 0}, {"timeout_ms": 0.9}])
def test_a_call_needs_a_port_and_a_wait(peer, port, kw):
    with pytest.raises(ValueError):
        someip.call(peer.to, SomeipMessage(0x0100, 0x0001), **{"port": port, **kw})


def test_no_answer_is_a_timeout(port):
    start = time.monotonic()
    with pytest.raises(blobly.Timeout):
        someip.call(f"127.0.0.1:{free_port()}", SomeipMessage(0x0100, 0x0001), port=port, timeout_ms=150)
    assert time.monotonic() - start < 2


def send_after(port, delay, datagrams):
    def go():
        time.sleep(delay)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            for d in datagrams:
                s.sendto(d, ("127.0.0.1", port))
    t = threading.Thread(target=go, daemon=True)
    t.start()
    return t


ETH = """project:
  name: someip
  version: 8
channels:
  - name: ETH1
    adapter: someip
    address: "127.0.0.1:{port}"
  - name: CAN1
    type: can
    interface: inproc:PY_SOMEIP
"""


def test_a_port_heard_for_a_window(port):
    t = send_after(port, 0.2, [header(0x0100, 0x8001, 0, 0, 0x02, payload=b"\x11\x22"),
                               header(0x0100, 0x8002, 0, 0, 0x02) + header(0x0100, 0x8003, 0, 0, 0x02),
                               b"\x00\x01\x02"])
    heard = someip.listen(800, port=port)
    t.join()
    assert [m.method for m in heard.messages] == [0x8001, 0x8002, 0x8003]
    assert heard.messages[0].payload == b"\x11\x22"
    assert heard.malformed == 1, "a datagram that is no SOME/IP is counted"


def test_a_channel_names_the_endpoint(tmp_path, port):
    path = tmp_path / "eth.blobnet"
    path.write_text(ETH.format(port=port), encoding="utf-8")
    with blobly.Project(str(path)) as net:
        t = send_after(port, 0.2, [header(0x0100, 0x8001, 0, 0, 0x02)])
        heard = someip.listen(600, channel=net.channels.ETH1)
        t.join()
        assert [m.method for m in heard.messages] == [0x8001]
        for kw in ({"port": port + 1}, {"group": "239.1.2.3"}):
            with pytest.raises(blobly.Refused, match="contradicts"):
                someip.listen(10, channel=net.channels.ETH1, **kw)
        with pytest.raises(blobly.Refused, match="not a SOME/IP channel"):
            someip.listen(10, channel=net.channels.CAN1)
