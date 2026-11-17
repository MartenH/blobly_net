"""0x29 Authentication from Python (UdsClient.authenticate) against projects/auth-demo's simulated
node, which unlocks that way instead of 0x27 (blobly_emb `[uds] access = "authentication"`), over
its CAN row and its DoIP row: the key forms, a wrong key refused 0x58 and counted to the lockout,
the refusals made before anything is sent, Node.authenticates, and a raw proof after a reconnect
refused 0x24 by the entity (its challenge ended with the connection, as on the board)."""
import os
import time

import pytest

import blobly
from conftest import REPO, write

AUTH_DEMO = os.path.join(REPO, "projects", "auth-demo", "auth-demo.blobnet")
WRONG = b"\x11" * 32

pytestmark = pytest.mark.usefixtures("engine")


@pytest.fixture(scope="class")
def auth_demo(engine):
    net = blobly.Project(AUTH_DEMO).start()
    yield net
    net.stop()


@pytest.mark.parametrize("row", ["AUTH", "AUTH_IP"])
class TestAuthenticate:
    def test_the_key_forms_and_the_gate(self, auth_demo, row, tmp_path):
        with auth_demo.channels[row].uds() as d:
            d.session(0x03)
            with pytest.raises(blobly.NegativeResponse) as e:
                d.raw(b"\x27\x01")
            assert e.value.nrc == 0x11, "0x27 is not served on an authenticating node"
            with pytest.raises(blobly.NegativeResponse) as e:
                d.read_did(0xF1B0)
            assert e.value.nrc == 0x33
            d.authenticate(1)
            assert d.read_did(0xF1B0) == b"SECRET-LEVEL-1"
            d.session(0x03)
            d.authenticate(1, key="reference")
            d.session(0x03)
            d.authenticate(1, key=bytes(range(0x20, 0x40)))
            d.session(0x03)
            d.authenticate(1, key="20212223" "2425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
            seed = write(str(tmp_path), "tester.seed", bytes(range(0x20, 0x40)).hex() + "\n")
            d.session(0x03)
            d.authenticate(1, key=seed)
            assert d.read_did(0xF1B0) == b"SECRET-LEVEL-1"
            assert d.raw(b"\x29\x00") == b"\x69\x00\x10"

    def test_refusals_before_anything_is_sent(self, auth_demo, row):
        with auth_demo.channels[row].uds() as d:
            d.session(0x03)
            for bad in (b"\x00" * 31, "1" * 63):
                with pytest.raises((ValueError, blobly.Refused)):
                    d.authenticate(1, key=bad)
            with pytest.raises(blobly.Refused):
                d.authenticate(9)
            with pytest.raises(TypeError):
                d.authenticate(1, key=42)

    def test_wrong_keys_count_to_the_lockout(self, auth_demo, row):
        with auth_demo.channels[row].uds() as d:
            d.session(0x03)
            for want in (0x58, 0x58, 0x36):
                with pytest.raises(blobly.NegativeResponse) as e:
                    d.authenticate(1, key=WRONG)
                assert e.value.nrc == want
            with pytest.raises(blobly.NegativeResponse) as e:
                d.authenticate(1)
            assert e.value.nrc == 0x37
            time.sleep(1.1)
            d.authenticate(1)


class TestNodeAndReconnect:
    def test_the_node_says_it_authenticates(self, auth_demo):
        assert auth_demo.nodes.auth.authenticates and not auth_demo.nodes.auth.reference_key

    def test_a_raw_proof_after_a_reconnect_is_refused(self, auth_demo):
        ip = auth_demo.channels.AUTH_IP
        with ip.uds() as d:
            d.session(0x03)
            challenge = d.raw(b"\x29\x05\x01" + bytes([0x06, 0x03, 0x2B, 0x65, 0x70]) + bytes(11))
            assert len(challenge) == 55
        # a new connection: the entity ended the old one's challenge when it closed
        with ip.uds() as d:
            d.session(0x03)
            proof = b"\x29\x06" + bytes([0x06, 0x03, 0x2B, 0x65, 0x70]) + bytes(11) + b"\x00\x40" + bytes(64) + bytes(4)
            with pytest.raises(blobly.NegativeResponse) as e:
                d.raw(proof)
            assert e.value.nrc == 0x24
