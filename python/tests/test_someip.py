"""SOME/IP from Python: someip.send, someip.call and someip.listen against a static peer on
loopback (a plain UDP socket answering from its own port, as a blobly_emb node does) — the coverage
of blobly/script's someip tests and blobly/someip's tester_test.v, through the C ABI."""
import os
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
# the source tree, unless the run is of an installed wheel (BLOBLY_TEST_INSTALLED)
if not os.environ.get("BLOBLY_TEST_INSTALLED"):
    sys.path.insert(0, os.path.join(HERE, ".."))
import blobly  # noqa: E402
from blobly import SomeipMessage, _lib, someip  # noqa: E402


def setUpModule():
    try:
        _lib.lib()
    except blobly.BloblyError as e:
        if os.environ.get("BLOBLY_LIB") or os.environ.get("BLOBLY_TEST_INSTALLED"):
            raise
        raise unittest.SkipTest(str(e))


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


class TestSendAndCall(unittest.TestCase):
    def setUp(self):
        self.peer = Peer()
        self.addCleanup(self.peer.close)
        self.port = free_port()

    def test_a_call_returns_the_mirrored_response(self):
        r = someip.call(self.peer.to, SomeipMessage(0x0100, 0x0001, b"abc", client=0x42, session=7), port=self.port)
        self.assertEqual((r.type, r.return_code, r.client, r.session, r.payload), ("response", 0, 0x42, 7, b"cba"))
        self.assertEqual((r.service, r.method, r.iface, r.source), (0x0100, 0x0001, 1, self.peer.to))
        self.assertFalse(r.event)
        self.assertGreaterEqual(r.at_ms, 0)

    def test_an_error_is_an_answer(self):
        r = someip.call(self.peer.to, SomeipMessage(0x0100, 0x0099), port=self.port)
        self.assertEqual((r.type, r.return_code, r.client), ("error", 3, 0x1234))

    def test_send_returns_everything_heard(self):
        heard, malformed = someip.send(self.peer.to, SomeipMessage(0x0100, 0x0001, b"\x05"), port=self.port,
                                       window_ms=300)
        self.assertEqual(malformed, 0)
        self.assertEqual([(m.method, m.type) for m in heard], [(0x8001, "notification"), (0x0001, "response")])
        self.assertTrue(heard[0].event)
        sent = self.peer.heard[-1]
        self.assertEqual((sent[2], sent[5]), (0x1234, 0x00), "a request goes out with a live client")

    def test_a_notification_goes_out_with_no_request_id(self):
        heard = someip.send(self.peer.to, [SomeipMessage(0x0100, 0x8002, b"\x09")], port=self.port,
                            window_ms=100)
        self.assertEqual(heard.messages, [])
        self.assertEqual(self.peer.heard[-1][1:6], (0x8002, 0, 0, 1, 0x02))

    def test_a_session_goes_out_once_per_run(self):
        someip.call(self.peer.to, SomeipMessage(0x0100, 0x0001, session=0x4321), port=self.port)
        for go in (lambda: someip.call(self.peer.to, SomeipMessage(0x0100, 0x0001, session=0x4321), port=self.port),
                   lambda: someip.send(self.peer.to, SomeipMessage(0x0100, 0x0001, session=0x4321), port=self.port,
                                       window_ms=0)):
            with self.assertRaises(blobly.Refused) as e:
                go()
            self.assertIn("already used", str(e.exception))

    def test_what_is_no_request_is_refused(self):
        for req, why in ((SomeipMessage(0x0100, 0x8001), "event id"), (SomeipMessage(0x0100, 1, client=0), "client 0"),
                         (SomeipMessage(0x0100, 1, type="notification"), "a call sends a request")):
            with self.subTest(why), self.assertRaises(blobly.Refused) as e:
                someip.call(self.peer.to, req, port=self.port)
            self.assertIn(why, str(e.exception))
        with self.assertRaises(blobly.Refused):
            someip.send(self.peer.to, SomeipMessage(1, 1, type="response"), port=self.port)

    def test_a_destination_is_an_ipv4_host_and_port(self):
        for to in ("127.0.0.1", "[::1]:30490"):
            with self.subTest(to), self.assertRaises(blobly.Refused) as e:
                someip.send(to, SomeipMessage(1, 1), port=self.port)
            self.assertIn("IPv4 \"host:port\"", str(e.exception))

    def test_bad_fields_are_refused_before_anything_goes_out(self):
        for m, err in ((SomeipMessage(0x10000, 1), ValueError), (SomeipMessage(1.5, 1), TypeError),
                       (SomeipMessage(1, 1, type="answer"), ValueError), (SomeipMessage(1, 1, payload="x"), TypeError)):
            with self.subTest(m), self.assertRaises(err):
                someip.send(self.peer.to, m, port=self.port)
        with self.assertRaises(ValueError):
            someip.call(self.peer.to, SomeipMessage(1, 1), port=0)

    def test_no_answer_is_a_timeout(self):
        start = time.monotonic()
        with self.assertRaises(blobly.Timeout):
            someip.call(f"127.0.0.1:{free_port()}", SomeipMessage(0x0100, 0x0001), port=self.port, timeout_ms=150)
        self.assertLess(time.monotonic() - start, 2)


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


class TestListen(unittest.TestCase):
    def test_a_port_heard_for_a_window(self):
        port = free_port()
        t = send_after(port, 0.2, [header(0x0100, 0x8001, 0, 0, 0x02, payload=b"\x11\x22"),
                                   header(0x0100, 0x8002, 0, 0, 0x02) + header(0x0100, 0x8003, 0, 0, 0x02),
                                   b"\x00\x01\x02"])
        heard = someip.listen(800, port=port)
        t.join()
        self.assertEqual([m.method for m in heard.messages], [0x8001, 0x8002, 0x8003])
        self.assertEqual(heard.messages[0].payload, b"\x11\x22")
        self.assertEqual(heard.malformed, 1, "a datagram that is no SOME/IP is counted")

    def test_a_channel_names_the_endpoint(self):
        port = free_port()
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "eth.blobnet")
            with open(path, "w") as f:
                f.write(ETH.format(port=port))
            with blobly.Project(path) as net:
                t = send_after(port, 0.2, [header(0x0100, 0x8001, 0, 0, 0x02)])
                heard = someip.listen(600, channel=net.channels.ETH1)
                t.join()
                self.assertEqual([m.method for m in heard.messages], [0x8001])
                for kw, why in (({"port": port + 1}, "contradicts"), ({"group": "239.1.2.3"}, "contradicts")):
                    with self.subTest(kw), self.assertRaises(blobly.Refused) as e:
                        someip.listen(10, channel=net.channels.ETH1, **kw)
                    self.assertIn(why, str(e.exception))
                with self.assertRaises(blobly.Refused) as e:
                    someip.listen(10, channel=net.channels.CAN1)
                self.assertIn("not a SOME/IP channel", str(e.exception))


if __name__ == "__main__":
    unittest.main()
