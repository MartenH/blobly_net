"""DoIP from Python: UDS over projects/sim-demo.blobnet's DoIP1 entity, the coverage of the Lua suite
tests/diag_doip.lua (sessions, DIDs, the VIN written and announced, refusals, a suppressed request)
plus its DTCs and functional addressing (tests/diag_doip_functional.lua); discovery and listening
against projects/doip-announce-demo.blobnet, tests/doip_announce.lua's; and what only a fake entity
produces: a routing activation denied, a connection lost and opened again, a close from another
thread ending a call."""
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
from blobly import _lib  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
SIM_DEMO = os.path.join(REPO, "projects", "sim-demo.blobnet")
ANNOUNCE_DEMO = os.path.join(REPO, "projects", "doip-announce-demo.blobnet")
VIN = 0xF190


def setUpModule():
    try:
        _lib.lib()
    except blobly.BloblyError as e:
        if os.environ.get("BLOBLY_LIB") or os.environ.get("BLOBLY_TEST_INSTALLED"):
            raise
        raise unittest.SkipTest(str(e))


class TestSimDemo(unittest.TestCase):
    """diag_doip.lua, from Python, on sim-demo's DoIP1."""

    @classmethod
    def setUpClass(cls):
        cls.net = blobly.Project(SIM_DEMO).start()
        cls.doip = cls.net.channels.DoIP1

    @classmethod
    def tearDownClass(cls):
        cls.net.stop()

    def setUp(self):
        self.diag = self.doip.uds()
        self.addCleanup(self.diag.close)

    def test_session_and_dids(self):
        self.assertEqual(self.diag.session(0x01)[:1], b"\x01")
        self.assertEqual(self.diag.read_did(VIN), b"BLOBLYNETV0SUT001")
        self.assertEqual(self.diag.read_did(0xF18C), b"SN-0001")
        self.assertEqual(self.diag.read_did(0xF195), b"\x01\x00")
        self.diag.tester_present()
        time.sleep(0.02)
        self.diag.tester_present()

    def test_the_addressing_is_the_channels(self):
        self.assertEqual((self.diag.tester, self.diag.ecu), (0x0E80, 0x1000))
        self.assertIsNone(self.diag.tx)
        self.assertIn("DoIP 0x0E80 -> 0x1000", repr(self.diag))

    def test_a_negative_response_is_typed(self):
        with self.assertRaises(blobly.NegativeResponse) as e:
            self.diag.read_did(0xABCD)
        self.assertEqual((e.exception.nrc, e.exception.nrc_name), (0x31, "requestOutOfRange"))

    def test_can_ids_are_refused_on_a_doip_channel(self):
        for ids in ({"tx": 0x7E0}, {"rx": 0x7E8}):
            with self.subTest(ids), self.assertRaises(blobly.Refused) as e:
                self.doip.uds(**ids)
            self.assertIn("DoIP addressing comes from the channel", str(e.exception))

    def test_one_client_holds_the_connection(self):
        with self.assertRaises(blobly.Refused) as e:
            self.doip.uds()
        self.assertIn("one tester address holds one connection", str(e.exception))
        self.diag.close()
        with self.doip.uds() as again:  # once it is let go, the next opens
            self.assertEqual(again.read_did(VIN), b"BLOBLYNETV0SUT001")

    def test_writing_the_vin_moves_the_announcement_with_it(self):
        before = self.diag.read_did(VIN)
        self.assertEqual(self.doip.discover().vin, before.decode())
        try:
            self.diag.write_did(VIN, b"REWRITTENVIN00001")
            self.assertEqual(self.diag.read_did(VIN), b"REWRITTENVIN00001")
            self.assertEqual(self.doip.discover().vin, "REWRITTENVIN00001")
        finally:
            self.diag.write_did(VIN, before)

    def test_a_vin_the_announcement_cannot_carry_is_refused(self):
        before = self.diag.read_did(VIN)
        with self.assertRaises(blobly.NegativeResponse) as e:
            self.diag.write_did(VIN, b"TOOSHORT")
        self.assertEqual(e.exception.nrc, 0x31)
        with self.assertRaises(blobly.NegativeResponse):
            self.diag.raw(b"\x2e\xf1\x90")  # zero-length: refused, not applied
        self.assertEqual(self.diag.read_did(VIN), before)
        self.assertEqual(self.doip.discover().vin, before.decode())

    def test_a_suppressed_positive_response_is_silence(self):
        self.assertFalse(self.diag.raw_suppressed(b"\x3e\x00"))

    def test_the_dtcs_over_doip(self):
        self.assertEqual([d.name for d in self.diag.supported_dtcs()], ["P1234-56", "B2BCD-EF"])
        self.assertEqual([d.name for d in self.diag.dtcs(0x01)], ["P1234-56"])

    def test_functional_addressing_reaches_the_entity(self):
        reply, = self.doip.uds_functional(None, [self.diag], b"\x22\xf1\x90")  # 0xE400
        self.assertEqual(reply.outcome, "positive")
        self.assertEqual(reply.answer, b"\x62\xf1\x90BLOBLYNETV0SUT001")
        self.assertIsNone(self.diag.last, "a functional request's reply is its own")
        quiet, = self.doip.uds_functional(0xE400, [self.diag], b"\x3e\x80")
        self.assertEqual(quiet.outcome, "silent")
        # an address the entity does not answer is negatively acknowledged: the reply says so
        nacked, = self.doip.uds_functional(0xE401, [self.diag], b"\x3e\x00", window_ms=300)
        self.assertEqual(nacked.outcome, "failed")
        self.assertIn("negative ack", nacked.error)

    def test_functional_refusals(self):
        self.diag.tester_present()
        before = self.diag.last
        with self.assertRaises(blobly.Refused):
            self.doip.uds_functional(None, [self.diag], b"")
        self.assertEqual(self.diag.last, before, "a refused request let go of the last exchange")
        with self.assertRaises(ValueError):
            self.doip.uds_functional(None, [], b"\x3e\x00")
        with self.assertRaises(blobly.Refused):
            self.doip.uds_functional(0x10000, [self.diag], b"\x3e\x00")
        with self.assertRaises(TypeError):  # None is the DoIP default, not a CAN id
            self.net.channels.CAN1.uds_functional(None, [], b"\x3e\x00")

    def test_discover(self):
        a = self.doip.discover()
        self.assertEqual((a.vin, a.logical_address), ("BLOBLYNETV0SUT001", 0x1000))
        self.assertEqual(a.eid, bytes([0x02, 0, 0, 0, 0, 0x01]))
        self.assertEqual(len(a.gid), 6)
        self.assertEqual("doip:" + a.source, self.doip.iface, "asked where the run moved the entity")

    def test_discover_and_listen_refuse_what_is_not_doip(self):
        with self.assertRaises(blobly.Refused) as e:
            self.net.channels.CAN1.discover()
        self.assertIn("not a DoIP channel", str(e.exception))
        with self.assertRaises(blobly.Refused):
            blobly.doip_listen(10, channel=self.net.channels.CAN1)
        with self.assertRaises(TypeError):
            blobly.doip_listen(float("inf"))
        with self.assertRaises(ValueError):
            blobly.doip_listen(-1)


class TestAnnouncements(unittest.TestCase):
    """doip_announce.lua, from Python: each test starts the project, so it hears an announcement
    sequence from its beginning (Talker and AltPort announce 20 times, 200 ms apart)."""

    def setUp(self):
        self.net = blobly.Project(ANNOUNCE_DEMO).start()
        self.addCleanup(self.net.stop)

    def test_a_listening_tester_hears_an_entity_announce_itself(self):
        talker = self.net.channels.Talker
        seen = blobly.doip_listen(1200, channel=talker)
        mine = [a for a in seen if a.vin == "ANNOUNCERVIN00001"]
        self.assertTrue(mine, f"heard {seen}")
        self.assertEqual(mine[0].logical_address, 0x1000)
        self.assertTrue(mine[0].source.startswith("127.0.0.1:"), mine[0].source)

    def test_announcements_arrive_on_the_entitys_own_port(self):
        seen = blobly.doip_listen(1200, channel=self.net.channels.AltPort)
        self.assertIn(("ALTPORTVIN0000001", 0x4000), {(a.vin, a.logical_address) for a in seen})

    def test_a_port_that_contradicts_the_channel_is_refused(self):
        with self.assertRaises(blobly.Refused) as e:
            blobly.doip_listen(100, channel=self.net.channels.AltPort, port=13400)
        self.assertIn("contradicts", str(e.exception))

    def test_a_silent_ecu_never_announces_but_answers_when_asked(self):
        silent = self.net.channels.Silent
        seen = blobly.doip_listen(800, channel=silent)
        self.assertNotIn("SILENTECUVIN00001", [a.vin for a in seen])
        self.assertEqual(silent.discover().vin, "SILENTECUVIN00001")
        with silent.uds() as diag:
            self.assertEqual(diag.read_did(VIN), b"SILENTECUVIN00001")


def _msg(ptype, payload):
    return struct.pack(">BBHI", 0x02, 0xFD, ptype, len(payload)) + payload


def _read(conn):
    head = b""
    while len(head) < 8:
        part = conn.recv(8 - len(head))
        if not part:
            return None, b""
        head += part
    _, _, ptype, n = struct.unpack(">BBHI", head)
    body = b""
    while len(body) < n:
        part = conn.recv(n - len(body))
        if not part:
            return None, b""
        body += part
    return ptype, body


class FakeEntity:
    """A DoIP entity on a loopback port: `deny` answers a routing activation with that code;
    otherwise it activates and serves connection after connection, answering 0x22 with b"FAKE"
    and 0x27 01 / 02 with a seed and an acceptance. The first `drop` connections are closed at
    their first diagnostic message whose service is in `drop_sids` (any, when None); from
    connection `hold` on none is activated (the request unanswered); `mute` acknowledges a
    request and never answers it; `idle_close` closes the first connection 100 ms after it
    answered its first request. With `alive`, it asks an activated connection an alive check at
    once, and `alive_answered` says whether it came back."""

    def __init__(self, deny=None, drop=0, drop_sids=None, mute=False, hold=None, alive=False, idle_close=False):
        self.deny, self.drop, self.drop_sids, self.mute = deny, drop, drop_sids, mute
        self.hold, self.alive, self.idle_close = hold, alive, idle_close
        self.alive_answered = threading.Event()
        self.connections = 0
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(4)
        self.sock.settimeout(0.2)
        self.port = self.sock.getsockname()[1]
        self.done = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while not self.done.is_set():
            try:
                conn, _ = self.sock.accept()
            except OSError:
                continue
            self.connections += 1
            with conn:
                conn.settimeout(5)
                try:
                    self._connection(conn, self.connections)
                except OSError:
                    pass

    def _connection(self, conn, n):
        while True:
            ptype, body = _read(conn)
            if ptype is None:
                return
            if ptype == 0x0005:  # routing activation request
                if self.hold is not None and n >= self.hold:
                    continue
                tester = body[:2]
                code = 0x10 if self.deny is None else self.deny
                conn.sendall(_msg(0x0006, tester + b"\x10\x00" + bytes([code]) + b"\0\0\0\0"))
                if self.deny is not None:
                    return
                if self.alive:
                    conn.sendall(_msg(0x0007, b""))
            elif ptype == 0x0008:  # alive check response
                self.alive_answered.set()
            elif ptype == 0x8001:  # diagnostic message
                source, target, data = body[:2], body[2:4], body[4:]
                if n <= self.drop and (self.drop_sids is None or data[0] in self.drop_sids):
                    return
                conn.sendall(_msg(0x8002, target + source + b"\x00"))
                if self.mute:
                    continue
                if data[:1] == b"\x22":
                    answer = b"\x62" + data[1:3] + b"FAKE"
                elif data[:2] == b"\x27\x01":
                    answer = b"\x67\x01\x12\x34"
                elif data[:1] == b"\x27":
                    answer = b"\x67" + data[1:2]
                else:
                    continue
                conn.sendall(_msg(0x8001, target + source + answer))
                if self.idle_close and n == 1:
                    time.sleep(0.1)
                    return

    def close(self):
        self.done.set()
        self.thread.join(5)
        self.sock.close()


class TestFakeEntity(unittest.TestCase):
    """What sim-demo's entity never does, from a fake one a tester-only DoIP row dials."""

    def start(self, **fake):
        entity = FakeEntity(**fake)
        self.addCleanup(entity.close)
        return entity, self.dial(entity.port).channels.Fake

    def dial(self, port, start=True):
        """A project of one tester-only DoIP row, Fake, dialling 127.0.0.1:port; started unless
        `start` is False."""
        d = tempfile.TemporaryDirectory()
        self.addCleanup(d.cleanup)
        path = os.path.join(d.name, "fake.blobnet")
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"""project:
  name: fake DoIP entity
  version: 8
channels:
  - name: Fake
    type: doip
    interface: doip:127.0.0.1:{port}
    tester_address: "0x0E80"
    ecu_address: "0x1000"
""")
        net = blobly.Project(path).load()
        if start:
            net.start()
            self.addCleanup(net.stop)
        return net

    def test_a_denied_routing_activation_says_why(self):
        _, fake = self.start(deny=0x00)
        with self.assertRaises(blobly.RoutingDenied) as e:
            fake.uds()
        x = e.exception
        self.assertEqual((x.routing_code, x.tester, x.code), (0x00, 0x0E80, _lib.BB_ERR_ROUTING))
        self.assertEqual(x.routing_name, "unknown source address")
        self.assertIn("does not accept tester 0x0E80", x.hint)
        self.assertIn("routing activation denied", str(x))

    def test_a_lost_connection_is_typed_and_the_next_call_opens_another(self):
        entity, fake = self.start(drop=1)
        with fake.uds() as diag:
            with self.assertRaises(blobly.ConnectionLost) as e:
                diag.read_did(VIN)
            self.assertIsInstance(e.exception, blobly.CarrierFailed)
            self.assertEqual(e.exception.code, _lib.BB_ERR_LOST)
            self.assertTrue(e.exception.exchange.sent, "the request went out before the entity closed")
            self.assertEqual(e.exception.exchange.request, b"\x22\xf1\x90")
            self.assertEqual(diag.read_did(VIN), b"FAKE")
            self.assertEqual(entity.connections, 2)

    def test_an_idle_connection_answers_alive_checks(self):
        entity, fake = self.start(alive=True)
        with fake.uds() as diag:
            self.assertTrue(entity.alive_answered.wait(0.5), "the alive check went unanswered while idle")
            self.assertEqual(diag.read_did(VIN), b"FAKE")

    def test_a_close_ends_the_reopen_after_a_lost_connection(self):
        _, fake = self.start(drop=1, hold=2)  # the second connection is never activated
        diag = fake.uds()
        with self.assertRaises(blobly.ConnectionLost):
            diag.read_did(VIN)
        threading.Timer(0.2, diag.close).start()
        t = time.monotonic()
        with self.assertRaises(blobly.BloblyError) as e:
            diag.read_did(VIN)  # reopens, and waits for the activation
        self.assertLess(time.monotonic() - t, 1.0, "the close waited out the reopen")
        self.assertEqual(e.exception.code, _lib.BB_ERR_HANDLE)

    def test_a_connection_gone_while_idle_is_the_next_calls_and_unsent(self):
        _, fake = self.start(idle_close=True)
        with fake.uds() as diag:
            self.assertEqual(diag.read_did(VIN), b"FAKE")
            time.sleep(0.4)  # the entity closes; the idle service sees it
            with self.assertRaises(blobly.ConnectionLost) as e:
                diag.read_did(0xF18C)
            self.assertIsNone(e.exception.exchange, "the request of an earlier call was reported as this one's")
            self.assertEqual(diag.read_did(VIN), b"FAKE")

    def test_an_argument_is_refused_before_a_reopen(self):
        _, fake = self.start(drop=1, hold=2)
        with fake.uds() as diag:
            with self.assertRaises(blobly.ConnectionLost):
                diag.read_did(VIN)
            t = time.monotonic()
            for bad in (lambda: diag.read_did(0x10000), lambda: diag.raw(b""),
                        lambda: diag.raw_suppressed(b"\x22\xf1")):
                with self.assertRaises(blobly.Refused):
                    bad()
            self.assertLess(time.monotonic() - t, 0.5, "a bad request waited for a reopen")
            with self.assertRaises(blobly.CarrierFailed) as e:  # the reopen is never activated
                diag.read_did(VIN)
            self.assertIsNone(diag.last, "the lost call's exchange was kept as the failed reopen's")

    def test_a_key_goes_only_on_the_seeds_connection(self):
        _, fake = self.start(drop=1, drop_sids={0x22})
        with fake.uds() as diag:
            def key_fn(seed):
                with self.assertRaises(blobly.ConnectionLost):
                    diag.read_did(VIN)  # the connection that gave the seed goes
                return bytes(b ^ 0xFF for b in seed)
            with self.assertRaises(blobly.Refused) as e:
                diag.security_access(0x01, key_fn)
            self.assertIn("the connection that gave the seed is gone", str(e.exception))
            self.assertEqual(diag.security_access(0x01), b"\x12\x34")  # a new seed, on the new one
            for nested in (lambda seed: diag.security_access(0x01), lambda seed: diag.raw(b"\x27\x01")):
                with self.assertRaises(blobly.BloblyError) as e:  # nor a nested seed under it
                    diag.security_access(0x01, nested)
                self.assertEqual(e.exception.code, _lib.BB_ERR_STATE)

    def test_a_raw_key_goes_only_on_the_seeds_connection(self):
        _, fake = self.start(drop=1, drop_sids={0x22})
        with fake.uds() as diag:
            seed = diag.raw(b"\x27\x01")[2:]
            with self.assertRaises(blobly.ConnectionLost):
                diag.read_did(VIN)
            key = b"\x27\x02" + bytes(b ^ 0xFF for b in seed)
            with self.assertRaises(blobly.Refused) as e:
                diag.raw(key)
            self.assertIn("the connection that gave the seed is gone", str(e.exception))
            with self.assertRaises(blobly.Refused):  # nor to the functional address
                fake.uds_functional(None, [diag], key)
            diag.raw(b"\x27\x01")  # a seed on the new connection, and its key goes
            self.assertEqual(diag.raw(b"\x27\x02\xed\xcb"), b"\x67\x02")

    def test_a_close_from_another_thread_ends_a_call(self):
        _, fake = self.start(mute=True)
        diag = fake.uds()
        threading.Timer(0.1, diag.close).start()
        t = time.monotonic()
        with self.assertRaises(blobly.BloblyError) as e:
            diag.read_did(VIN)
        self.assertLess(time.monotonic() - t, 0.6, "the close waited out the answer's 1000 ms")
        self.assertEqual(e.exception.code, _lib.BB_ERR_HANDLE)

    def test_discovery_on_a_row_needs_the_run(self):
        fake = self.dial(13400, start=False).channels.Fake
        for call in (fake.discover, lambda: blobly.doip_listen(10, channel=fake)):
            with self.assertRaises(blobly.BloblyError) as e:
                call()
            self.assertEqual(e.exception.code, _lib.BB_ERR_STATE)

    def test_a_refused_connection_is_the_carriers(self):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        free = listener.getsockname()[1]
        listener.close()  # nothing listens on `free` now
        nobody = self.dial(free).channels.Fake
        with self.assertRaises(blobly.CarrierFailed) as e:
            nobody.uds()
        self.assertNotIsInstance(e.exception, blobly.ConnectionLost)
        t = time.monotonic()
        with self.assertRaises(blobly.BloblyError):  # silence, or the port's refusal
            nobody.discover(timeout_ms=200)
        self.assertLess(time.monotonic() - t, 2)

if __name__ == "__main__":
    unittest.main()
