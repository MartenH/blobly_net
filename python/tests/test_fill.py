"""The fill of the bits no signal covers (#671): a row's `fill:` and a generator's own, in every
frame built from the row's database — a generator's, Message.encode/send and send_cyclic."""
import pytest

import blobly
from conftest import write

pytestmark = pytest.mark.usefixtures("engine")

DBC = """VERSION ""

NS_ :

BS_:

BU_: Tester Receiver

BO_ 291 Status: 8 Tester
 SG_ Mode : 0|4@1+ (1,0) [0|15] "" Receiver
"""

PROJECT = """project:
  name: fill demo
  version: 14

buses:
  - name: CAN1
    adapter: virtual
    address: pyfill1
    protocol: can
    bitrate: 500000
    fill: 0xFF
    databases: [demo.dbc]
    senders:
      - name: Status
        message: Status
        trigger: cyclic
        cycle_ms: 20
        signals:
          - { name: Mode, value: 5 }
  - name: CAN2
    adapter: virtual
    address: pyfill2
    protocol: can
    bitrate: 500000
    databases: [demo.dbc]
    senders:
      - name: Own
        message: Status
        trigger: cyclic
        cycle_ms: 20
        fill: 0x0F
        signals:
          - { name: Mode, value: 5 }
  - name: CAN3
    adapter: virtual
    address: pyfill3
    protocol: can
    bitrate: 500000
    fill: 0xAA
    databases: [demo.dbc]
"""

FILLED = bytes([0xF5]) + b"\xff" * 7


def test_every_frame_built_from_the_row_takes_its_fill(tmp_path):
    write(tmp_path, "demo.dbc", DBC)
    path = write(tmp_path, "fill.blobnet", PROJECT)
    with blobly.Project(path) as net:
        can1, can2 = net.channels.CAN1, net.channels.CAN2
        assert can1.expect(0x123, 1000).data == FILLED, "the generator takes the row's fill"
        assert can2.expect(0x123, 1000).data == bytes([0x05]) + b"\x0f" * 7, "a generator's own fill wins"
        assert can1.messages.Status.encode(Mode=5).data == FILLED
        assert can2.messages.Status.encode(Mode=5).data == bytes([5]) + bytes(7), "no fill: as before"
        can3 = net.channels.CAN3
        # on a row no generator sends on, so every frame is the background sender's
        with can3.messages.Status.send_cyclic(20, Mode=5):
            assert all(can3.expect(0x123, 1000).data == bytes([0xA5]) + b"\xaa" * 7 for _ in range(3))
