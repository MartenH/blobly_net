"""DoIP from Python: UDS over projects/sim-demo.blobnet's DoIP1 entity, the coverage of the Lua suite
tests/diag_doip.lua (sessions, DIDs, the VIN written and announced, refusals, a suppressed request)
plus its DTCs and functional addressing (tests/diag_doip_functional.lua); discovery and listening
against projects/doip-announce-demo.blobnet, tests/doip_announce.lua's; and what only a fake entity
produces: a routing activation denied, a connection lost and opened again, a close from another
thread ending a call."""
import contextlib
import os
import socket
import struct
import threading
import time

import pytest

import blobly
from blobly import _lib
from conftest import REPO

ANNOUNCE_DEMO = os.path.join(REPO, "projects", "doip-announce-demo.blobnet")
VIN = 0xF190

pytestmark = pytest.mark.usefixtures("engine")


@pytest.fixture(scope="class")
def doip(sim_demo):
    return sim_demo.channels.DoIP1


@pytest.fixture
def diag(doip):
    with doip.uds() as client:
        yield client


class TestSimDemo:
    """diag_doip.lua, from Python, on sim-demo's DoIP1."""

    def test_session_and_dids(self, diag):
        assert diag.session(0x01)[:1] == b"\x01"
        assert diag.read_did(VIN) == b"BLOBLYNETV0SUT001"
        assert diag.read_did(0xF18C) == b"SN-0001"
        assert diag.read_did(0xF195) == b"\x01\x00"
        diag.tester_present()
        time.sleep(0.02)
        diag.tester_present()

    def test_the_addressing_is_the_channels(self, diag):
        assert (diag.tester, diag.ecu) == (0x0E80, 0x1000)
        assert diag.tx is None
        assert "DoIP 0x0E80 -> 0x1000" in repr(diag)

    def test_a_negative_response_is_typed(self, diag):
        with pytest.raises(blobly.NegativeResponse) as e:
            diag.read_did(0xABCD)
        assert (e.value.nrc, e.value.nrc_name) == (0x31, "requestOutOfRange")

    def test_can_ids_are_refused_on_a_doip_channel(self, doip, diag):
        for ids in ({"tx": 0x7E0}, {"rx": 0x7E8}):
            with pytest.raises(blobly.Refused, match="DoIP addressing comes from the channel"):
                doip.uds(**ids)

    def test_one_client_holds_the_connection(self, doip, diag):
        with pytest.raises(blobly.Refused, match="one tester address holds one connection"):
            doip.uds()
        diag.close()
        with doip.uds() as again:  # once it is let go, the next opens
            assert again.read_did(VIN) == b"BLOBLYNETV0SUT001"

    def test_writing_the_vin_moves_the_announcement_with_it(self, doip, diag):
        before = diag.read_did(VIN)
        assert doip.discover().vin == before.decode()
        try:
            diag.write_did(VIN, b"REWRITTENVIN00001")
            assert diag.read_did(VIN) == b"REWRITTENVIN00001"
            assert doip.discover().vin == "REWRITTENVIN00001"
        finally:
            diag.write_did(VIN, before)

    def test_a_vin_the_announcement_cannot_carry_is_refused(self, doip, diag):
        before = diag.read_did(VIN)
        with pytest.raises(blobly.NegativeResponse) as e:
            diag.write_did(VIN, b"TOOSHORT")
        assert e.value.nrc == 0x31
        with pytest.raises(blobly.NegativeResponse):
            diag.raw(b"\x2e\xf1\x90")  # zero-length: refused, not applied
        assert diag.read_did(VIN) == before
        assert doip.discover().vin == before.decode()

    def test_a_suppressed_positive_response_is_silence(self, diag):
        assert not diag.raw_suppressed(b"\x3e\x00")

    def test_the_dtcs_over_doip(self, diag):
        assert [d.name for d in diag.supported_dtcs()] == ["P1234-56", "B2BCD-EF"]
        assert [d.name for d in diag.dtcs(0x01)] == ["P1234-56"]

    def test_functional_addressing_reaches_the_entity(self, doip, diag):
        reply, = doip.uds_functional(None, [diag], b"\x22\xf1\x90")  # 0xE400
        assert reply.outcome == "positive"
        assert reply.answer == b"\x62\xf1\x90BLOBLYNETV0SUT001"
        assert diag.last is None, "a functional request's reply is its own"
        quiet, = doip.uds_functional(0xE400, [diag], b"\x3e\x80")
        assert quiet.outcome == "silent"
        # an address the entity does not answer is negatively acknowledged: the reply says so
        nacked, = doip.uds_functional(0xE401, [diag], b"\x3e\x00", window_ms=300)
        assert nacked.outcome == "failed"
        assert "negative ack" in nacked.error

    def test_functional_refusals(self, sim_demo, doip, diag):
        diag.tester_present()
        before = diag.last
        with pytest.raises(blobly.Refused):
            doip.uds_functional(None, [diag], b"")
        assert diag.last == before, "a refused request let go of the last exchange"
        with pytest.raises(ValueError):
            doip.uds_functional(None, [], b"\x3e\x00")
        with pytest.raises(blobly.Refused):
            doip.uds_functional(0x10000, [diag], b"\x3e\x00")
        with pytest.raises(TypeError):  # None is the DoIP default, not a CAN id
            sim_demo.channels.CAN1.uds_functional(None, [], b"\x3e\x00")

    def test_retarget_moves_the_connection_and_back(self, sim_demo, doip, diag):
        diag.retarget(0x2000)  # no node behind this entity: it refuses the target
        assert diag.ecu == 0x2000
        assert "DoIP 0x0E80 -> 0x2000" in repr(diag)
        with pytest.raises(blobly.CarrierFailed, match="negative ack"):
            diag.read_did(VIN)
        diag.retarget()
        assert diag.ecu == 0x1000
        assert diag.read_did(VIN) == b"BLOBLYNETV0SUT001"
        for bad, kind in ((0x10000, blobly.Refused), (-1, blobly.Refused), ("0x2000", TypeError)):
            with pytest.raises(kind):
                diag.retarget(bad)
        assert diag.ecu == 0x1000, "a refused retarget moved it"
        # another target is another ECU: what a session answer adopted goes, what was set stays
        diag.margin_ms = 2000
        diag.session(0x01)  # P2 50 ms: the first wait is P2 plus the margin
        assert diag.timeout_ms == 2050
        diag.retarget(0x2000)
        assert (diag.timeout_ms, diag.margin_ms) == (1000, 2000)
        diag.retarget(0x2000)  # the same target: nothing to forget
        diag.timeout_ms = 300
        diag.retarget(0x2000)
        assert diag.timeout_ms == 300
        diag.retarget()
        assert diag.timeout_ms == 300, "a wait set was dropped"
        with sim_demo.channels.CAN1.uds() as can, pytest.raises(blobly.Refused, match="DoIP connection"):
            can.retarget(0x2000)

    def test_discover(self, doip, diag):
        a = doip.discover()
        assert (a.vin, a.logical_address) == ("BLOBLYNETV0SUT001", 0x1000)
        assert a.eid == bytes([0x02, 0, 0, 0, 0, 0x01])
        assert len(a.gid) == 6
        assert "doip:" + a.source == doip.iface, "asked where the run moved the entity"

    def test_discover_and_listen_refuse_what_is_not_doip(self, sim_demo, diag):
        with pytest.raises(blobly.Refused, match="not a DoIP channel"):
            sim_demo.channels.CAN1.discover()
        with pytest.raises(blobly.Refused):
            blobly.doip_listen(10, channel=sim_demo.channels.CAN1)
        with pytest.raises(TypeError):
            blobly.doip_listen(float("inf"))
        with pytest.raises(ValueError):
            blobly.doip_listen(-1)


@pytest.fixture
def announcing():
    """doip-announce-demo started for one test, so it hears an announcement sequence from its
    beginning (Talker and AltPort announce 20 times, 200 ms apart)."""
    net = blobly.Project(ANNOUNCE_DEMO).start()
    yield net
    net.stop()


class TestAnnouncements:
    """doip_announce.lua, from Python."""

    def test_a_listening_tester_hears_an_entity_announce_itself(self, announcing):
        talker = announcing.channels.Talker
        seen = blobly.doip_listen(1200, channel=talker)
        mine = [a for a in seen if a.vin == "ANNOUNCERVIN00001"]
        assert mine, f"heard {seen}"
        assert mine[0].logical_address == 0x1000
        assert mine[0].source.startswith("127.0.0.1:"), mine[0].source

    def test_announcements_arrive_on_the_entitys_own_port(self, announcing):
        seen = blobly.doip_listen(1200, channel=announcing.channels.AltPort)
        assert ("ALTPORTVIN0000001", 0x4000) in {(a.vin, a.logical_address) for a in seen}

    def test_a_port_that_contradicts_the_channel_is_refused(self, announcing):
        with pytest.raises(blobly.Refused, match="contradicts"):
            blobly.doip_listen(100, channel=announcing.channels.AltPort, port=13400)

    def test_a_silent_ecu_never_announces_but_answers_when_asked(self, announcing):
        silent = announcing.channels.Silent
        seen = blobly.doip_listen(800, channel=silent)
        assert "SILENTECUVIN00001" not in [a.vin for a in seen]
        assert silent.discover().vin == "SILENTECUVIN00001"
        with silent.uds() as diag:
            assert diag.read_did(VIN) == b"SILENTECUVIN00001"


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
    once, and `alive_answered` says whether it came back. With `node`, it is a gateway to a node at
    that logical address, which answers 0x22 with b"NODE" and 0x27 as the gateway does, routed only
    once 0x27 02 was answered by the gateway itself on the connection; before that a request to the
    node is negatively acknowledged (0x06, target unreachable)."""

    def __init__(self, deny=None, drop=0, drop_sids=None, mute=False, hold=None, alive=False, idle_close=False,
                 node=None):
        self.deny, self.drop, self.drop_sids, self.mute = deny, drop, drop_sids, mute
        self.hold, self.alive, self.idle_close, self.node = hold, alive, idle_close, node
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
        unlocked = False  # the gateway's 0x27 02 answered on this connection
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
                to_node = self.node is not None and target == struct.pack(">H", self.node)
                if to_node and not unlocked:
                    conn.sendall(_msg(0x8003, target + source + b"\x06"))
                    continue
                conn.sendall(_msg(0x8002, target + source + b"\x00"))
                if self.mute:
                    continue
                if data[:1] == b"\x22":
                    answer = b"\x62" + data[1:3] + (b"NODE" if to_node else b"FAKE")
                elif data[:2] == b"\x27\x01":
                    answer = b"\x67\x01\x12\x34"
                elif data[:1] == b"\x27":
                    answer = b"\x67" + data[1:2]
                    unlocked = unlocked or (data[1:2] == b"\x02" and not to_node)
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


class Fakes:
    """Fake entities and the projects that dial them, let go in the reverse order at the end of
    the test."""

    def __init__(self, tmp_path):
        self.tmp_path = tmp_path
        self.cleanups = contextlib.ExitStack()
        self.dials = 0

    def start(self, **fake):
        entity = FakeEntity(**fake)
        self.cleanups.callback(entity.close)
        return entity, self.dial(entity.port).channels.Fake

    def dial(self, port, start=True):
        """A project of one tester-only DoIP row, Fake, dialling 127.0.0.1:port; started unless
        `start` is False."""
        self.dials += 1
        path = os.path.join(self.tmp_path, f"fake{self.dials}.blobnet")
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
            self.cleanups.callback(net.stop)
        return net


@pytest.fixture
def fakes(tmp_path):
    f = Fakes(tmp_path)
    with f.cleanups:
        yield f


class TestFakeEntity:
    """What sim-demo's entity never does, from a fake one a tester-only DoIP row dials."""

    def test_a_denied_routing_activation_says_why(self, fakes):
        _, fake = fakes.start(deny=0x00)
        with pytest.raises(blobly.RoutingDenied) as e:
            fake.uds()
        x = e.value
        assert (x.routing_code, x.tester, x.code) == (0x00, 0x0E80, _lib.BB_ERR_ROUTING)
        assert x.routing_name == "unknown source address"
        assert "does not accept tester 0x0E80" in x.hint
        assert "routing activation denied" in str(x)

    def test_a_wait_out_of_range_is_refused_before_anything_opens(self, fakes):
        entity, fake = fakes.start(deny=0x00)
        with pytest.raises(blobly.Refused, match="timeout_ms 0"):
            fake.uds(timeout_ms=0)
        assert entity.connections == 0, "a refused wait dialled the entity"

    def test_a_lost_connection_is_typed_and_the_next_call_opens_another(self, fakes):
        entity, fake = fakes.start(drop=1)
        with fake.uds() as diag:
            with pytest.raises(blobly.ConnectionLost) as e:
                diag.read_did(VIN)
            assert isinstance(e.value, blobly.CarrierFailed)
            assert e.value.code == _lib.BB_ERR_LOST
            assert e.value.exchange.sent, "the request went out before the entity closed"
            assert e.value.exchange.request == b"\x22\xf1\x90"
            assert diag.read_did(VIN) == b"FAKE"
            assert entity.connections == 2

    def test_an_idle_connection_answers_alive_checks(self, fakes):
        entity, fake = fakes.start(alive=True)
        with fake.uds() as diag:
            assert entity.alive_answered.wait(0.5), "the alive check went unanswered while idle"
            assert diag.read_did(VIN) == b"FAKE"

    def test_a_close_ends_the_reopen_after_a_lost_connection(self, fakes):
        _, fake = fakes.start(drop=1, hold=2)  # the second connection is never activated
        diag = fake.uds()
        with pytest.raises(blobly.ConnectionLost):
            diag.read_did(VIN)
        threading.Timer(0.2, diag.close).start()
        t = time.monotonic()
        with pytest.raises(blobly.BloblyError) as e:
            diag.read_did(VIN)  # reopens, and waits for the activation
        assert time.monotonic() - t < 1.0, "the close waited out the reopen"
        assert e.value.code == _lib.BB_ERR_HANDLE

    def test_a_connection_gone_while_idle_is_the_next_calls_and_unsent(self, fakes):
        _, fake = fakes.start(idle_close=True)
        with fake.uds() as diag:
            assert diag.read_did(VIN) == b"FAKE"
            time.sleep(0.4)  # the entity closes; the idle service sees it
            with pytest.raises(blobly.ConnectionLost) as e:
                diag.read_did(0xF18C)
            assert e.value.exchange is None, "the request of an earlier call was reported as this one's"
            assert diag.read_did(VIN) == b"FAKE"

    def test_an_argument_is_refused_before_a_reopen(self, fakes):
        _, fake = fakes.start(drop=1, hold=2)
        with fake.uds() as diag:
            with pytest.raises(blobly.ConnectionLost):
                diag.read_did(VIN)
            t = time.monotonic()
            for bad in (lambda: diag.read_did(0x10000), lambda: diag.raw(b""),
                        lambda: diag.raw_suppressed(b"\x22\xf1")):
                with pytest.raises(blobly.Refused):
                    bad()
            assert time.monotonic() - t < 0.5, "a bad request waited for a reopen"
            with pytest.raises(blobly.CarrierFailed):  # the reopen is never activated
                diag.read_did(VIN)
            assert diag.last is None, "the lost call's exchange was kept as the failed reopen's"

    def test_a_key_goes_only_on_the_seeds_connection(self, fakes):
        _, fake = fakes.start(drop=1, drop_sids={0x22})
        with fake.uds() as diag:
            def key_fn(seed):
                with pytest.raises(blobly.ConnectionLost):
                    diag.read_did(VIN)  # the connection that gave the seed goes
                return bytes(b ^ 0xFF for b in seed)
            with pytest.raises(blobly.Refused, match="the level 1 seed was not answered on this connection"):
                diag.security_access(0x01, key_fn)
            assert diag.security_access(0x01) == b"\x12\x34"  # a new seed, on the new one
            for nested in (lambda seed: diag.security_access(0x01), lambda seed: diag.raw(b"\x27\x01"),
                           lambda seed: diag.raw_suppressed(b"\x27\x01"),
                           lambda seed: fake.uds_functional(None, [diag], b"\x27\x01")):
                with pytest.raises(blobly.BloblyError) as e:  # nor a nested seed under it
                    diag.security_access(0x01, nested)
                assert e.value.code == _lib.BB_ERR_STATE

    def test_a_raw_key_goes_only_on_the_seeds_connection(self, fakes):
        _, fake = fakes.start(drop=1, drop_sids={0x22})
        with fake.uds() as diag:
            seed = diag.raw(b"\x27\x01")[2:]
            with pytest.raises(blobly.ConnectionLost):
                diag.read_did(VIN)
            key = b"\x27\x02" + bytes(b ^ 0xFF for b in seed)
            with pytest.raises(blobly.Refused, match="the level 1 seed was not answered on this connection"):
                diag.raw(key)
            with pytest.raises(blobly.Refused):  # nor to the functional address
                fake.uds_functional(None, [diag], key)
            diag.raw(b"\x27\x03")  # another level's seed on the new connection is not level 1's
            with pytest.raises(blobly.Refused):
                diag.raw(key)
            diag.raw(b"\x27\x01")  # a seed on the new connection, and its key goes
            assert diag.raw(b"\x27\x02\xed\xcb") == b"\x67\x02"

    def test_a_seed_before_a_stop_answers_no_key_after_it(self, fakes):
        _, fake = fakes.start()
        net = fake._project
        with fake.uds() as diag:
            seed = diag.raw(b"\x27\x01")[2:]
            net.stop()
            net.start()
            with pytest.raises(blobly.Refused):
                diag.raw(b"\x27\x02" + bytes(b ^ 0xFF for b in seed))
            diag.raw(b"\x27\x01")
            assert diag.raw(b"\x27\x02\xed\xcb") == b"\x67\x02"

    def test_a_node_behind_the_gateway_is_reached_once_it_is_unlocked(self, fakes):
        _, fake = fakes.start(node=0x2000)
        with fake.uds() as diag:
            diag.retarget(0x2000)
            with pytest.raises(blobly.CarrierFailed, match="negative ack .0x06"):
                diag.read_did(VIN)  # the gateway routes only an unlocked tester
            diag.retarget()
            diag.security_access(0x01)  # on the gateway, on this connection
            diag.retarget(0x2000)
            assert diag.read_did(VIN) == b"NODE"
            diag.retarget()
            assert diag.read_did(VIN) == b"FAKE"

            def moves(seed):
                diag.retarget()  # the key would go to the gateway, answering the node's seed
                return seed
            diag.retarget(0x2000)
            with pytest.raises(blobly.BloblyError, match="inside a security_access key_fn") as e:
                diag.security_access(0x01, moves)
            assert e.value.code == _lib.BB_ERR_STATE
            assert diag.ecu == 0x2000, "the refused retarget moved it"

    def test_a_new_connection_keeps_the_target_but_not_the_unlock(self, fakes):
        entity, fake = fakes.start(node=0x2000, drop=1, drop_sids={0x3E})
        net = fake._project
        with fake.uds() as diag:
            diag.security_access(0x01)
            diag.retarget(0x2000)
            assert diag.read_did(VIN) == b"NODE"
            with pytest.raises(blobly.ConnectionLost):
                diag.tester_present()  # the entity closes the connection
            with pytest.raises(blobly.CarrierFailed, match="negative ack"):
                diag.read_did(VIN)  # the reopen went to the node, which the gateway no longer routes
            assert (entity.connections, diag.ecu) == (2, 0x2000)
            diag.retarget()
            diag.security_access(0x01)  # the gateway's seed and key, on the new connection
            diag.retarget(0x2000)
            assert diag.read_did(VIN) == b"NODE"
            with pytest.raises(blobly.Refused, match="seed was not answered on this connection"):
                diag.raw(b"\x27\x02\xed\xcb")  # the gateway's seed is not the node's
            diag.raw(b"\x27\x01")  # the node's own, on this connection
            assert diag.raw(b"\x27\x02\xed\xcb") == b"\x67\x02"
            net.stop()
            net.start()
            assert diag.ecu == 0x2000, "a stop and start forgot the target"
            with pytest.raises(blobly.CarrierFailed, match="negative ack"):
                diag.read_did(VIN)
            diag.retarget()
            diag.security_access(0x01)
            diag.retarget(0x2000)
            assert diag.read_did(VIN) == b"NODE"

    def test_a_close_from_another_thread_ends_a_call(self, fakes):
        _, fake = fakes.start(mute=True)
        diag = fake.uds()
        threading.Timer(0.1, diag.close).start()
        t = time.monotonic()
        with pytest.raises(blobly.BloblyError) as e:
            diag.read_did(VIN)
        assert time.monotonic() - t < 0.6, "the close waited out the answer's 1000 ms"
        assert e.value.code == _lib.BB_ERR_HANDLE

    def test_discovery_on_a_row_needs_the_run(self, fakes):
        fake = fakes.dial(13400, start=False).channels.Fake
        for call in (fake.discover, lambda: blobly.doip_listen(10, channel=fake)):
            with pytest.raises(blobly.BloblyError) as e:
                call()
            assert e.value.code == _lib.BB_ERR_STATE

    def test_a_refused_connection_is_the_carriers(self, fakes):
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        free = listener.getsockname()[1]
        listener.close()  # nothing listens on `free` now
        nobody = fakes.dial(free).channels.Fake
        with pytest.raises(blobly.CarrierFailed) as e:
            nobody.uds()
        assert not isinstance(e.value, blobly.ConnectionLost)
        t = time.monotonic()
        with pytest.raises(blobly.BloblyError):  # silence, or the port's refusal
            nobody.discover(timeout_ms=200)
        assert time.monotonic() - t < 2
